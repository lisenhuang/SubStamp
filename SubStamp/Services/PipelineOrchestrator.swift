import AVFoundation
import Combine
import Foundation
import Translation

@MainActor
final class PipelineOrchestrator: ObservableObject {
    private let transcriptionService = TranscriptionService()
    private let translationService = TranslationService()
    private let appleIntelligenceTranslationService = AppleIntelligenceTranslationService()
    private let subtitleRenderer = SubtitleRenderer()
    private let exportService = ExportService()
    private let jobStore = JobStore()

    @Published var stageStates: [ProcessingStage: PipelineStageState] = [:]
    @Published var stageProgress: [ProcessingStage: Double] = [:]
    @Published var currentStage: ProcessingStage = .idle
    @Published var cues: [SubtitleCue] = []
    @Published var outputURL: URL?
    @Published var error: SubStampError?
    @Published var job: JobModel?
    @Published var isRunning = false
    @Published var readyForReview = false

    private var task: Task<Void, Never>?

    init() {
        resetStages()
    }

    func resetStages() {
        stageStates = [
            .assets: .pending,
            .transcribing: .pending,
            .translating: .pending,
            .rendering: .pending,
            .exporting: .pending
        ]
        stageProgress = [
            .assets: 0,
            .transcribing: 0,
            .translating: 0,
            .rendering: 0,
            .exporting: 0
        ]
        currentStage = .idle
        cues = []
        outputURL = nil
        error = nil
        isRunning = false
        readyForReview = false
    }

    func start(job: JobModel, translationSession1: TranslationSession?, translationSession2: TranslationSession?, translationSession3: TranslationSession?) {
        cancel()
        resetStages()
        self.job = job
        isRunning = true
        readyForReview = false
        print("[SUBSTAMP] start() mode=\(job.subtitleMode) lang1=\(job.language1Locale) lang2=\(job.translationTargetLocale ?? "nil") s1=\(translationSession1 != nil) s2=\(translationSession2 != nil) s3=\(translationSession3 != nil)")
        task = Task { [weak self] in
            guard let self else { return }
            await self.runPipeline(job: job, s1: translationSession1, s2: translationSession2, s3: translationSession3)
        }
    }

    func resume(
        job: JobModel,
        s1: TranslationSession?,
        s2: TranslationSession?,
        s3: TranslationSession?,
        transcribed: [SubtitleCue],
        translated: [SubtitleCue]?
    ) {
        cancel()
        resetStages()
        self.job = job
        cues = translated ?? transcribed
        stageStates[.transcribing] = .done
        stageProgress[.transcribing] = 1
        if let translated {
            stageStates[.translating] = .done
            stageProgress[.translating] = 1
            readyForReview = true
            isRunning = false
            currentStage = .rendering
        } else if job.subtitleMode == .single && job.language1Locale == job.transcriptionLocale {
            stageStates[.translating] = .done
            stageProgress[.translating] = 1
            readyForReview = true
            isRunning = false
            currentStage = .rendering
        } else {
            isRunning = true
            readyForReview = false
            task = Task { [weak self] in
                guard let self else { return }
                await self.runTranslationOnly(job: job, s1: s1, s2: s2, s3: s3)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    private func runPipeline(job: JobModel, s1: TranslationSession?, s2: TranslationSession?, s3: TranslationSession?) async {
        do {
            stageStates[.assets] = .done
            stageProgress[.assets] = 1

            var updatedJob = job
            updatedJob.stage = .transcribing
            updatedJob.updatedAt = Date()
            try jobStore.save(job: updatedJob)
            currentStage = .transcribing
            stageStates[.transcribing] = .active

            let asset = AVAsset(url: job.videoURL)
            let range = timeRange(for: job, asset: asset)
            let transcriptionResult = try await transcriptionService.transcribe(
                asset: asset,
                locale: Locale(identifier: job.transcriptionLocale),
                timeRange: range
            ) { [weak self] progress, count in
                self?.stageProgress[.transcribing] = progress
            }
            cues = transcriptionResult.cues
            try jobStore.saveCues(cues, id: job.id, type: .transcribed)
            stageStates[.transcribing] = .done
            stageProgress[.transcribing] = 1

            let baseLocale = job.transcriptionLocale
            let lang1NeedsTranslation = job.language1Locale != baseLocale
            let lang2NeedsTranslation = job.subtitleMode == .bilingual && (job.translationTargetLocale != nil && job.translationTargetLocale != baseLocale)
            
            if lang1NeedsTranslation || lang2NeedsTranslation {
                updatedJob.stage = .translating
                updatedJob.updatedAt = Date()
                try jobStore.save(job: updatedJob)
                currentStage = .translating
                stageStates[.translating] = .active
                
                cues = try await performTranslations(job: job, sourceCues: cues, s1: s1, s2: s2, s3: s3)
                try jobStore.saveCues(cues, id: job.id, type: .translated)
                stageStates[.translating] = .done
                stageProgress[.translating] = 1
            } else {
                // For bilingual where Lang2 == base: use same text for both
                if job.subtitleMode == .bilingual && job.translationTargetLocale == baseLocale {
                    cues = cues.map { cue in
                        var newCue = cue
                        newCue.secondaryText = cue.primaryText
                        return newCue
                    }
                    try jobStore.saveCues(cues, id: job.id, type: .translated)
                }
                stageStates[.translating] = .done
                stageProgress[.translating] = 1
            }

            updatedJob.stage = .rendering
            updatedJob.updatedAt = Date()
            try jobStore.save(job: updatedJob)
            readyForReview = true
            isRunning = false
            currentStage = .rendering
        } catch {
            self.error = (error as? SubStampError) ?? .translationError(underlying: error)
            markFailed()
        }
    }

    private func performTranslations(job: JobModel, sourceCues: [SubtitleCue], s1: TranslationSession?, s2: TranslationSession?, s3: TranslationSession?) async throws -> [SubtitleCue] {
        switch job.translationProvider {
        case .translationFramework:
            return try await performFrameworkTranslations(job: job, sourceCues: sourceCues, s1: s1, s2: s2, s3: s3)
        case .appleIntelligence:
            return try await performAppleIntelligenceTranslations(job: job, sourceCues: sourceCues)
        }
    }

    private func performFrameworkTranslations(job: JobModel, sourceCues: [SubtitleCue], s1: TranslationSession?, s2: TranslationSession?, s3: TranslationSession?) async throws -> [SubtitleCue] {
        let baseLocale = job.transcriptionLocale
        let lang1NeedsTranslation = job.language1Locale != baseLocale
        let lang2NeedsTranslation = job.subtitleMode == .bilingual && (job.translationTargetLocale != nil && job.translationTargetLocale != baseLocale)

        var primaryCues = sourceCues
        var secondaryCues = sourceCues

        // Session Mapping:
        // s1: Audio -> English (pivot common)
        // s2: Sub 1 Final Leg (A->T1 or E->T1)
        // s3: Sub 2 Final Leg (A->T2 or E->T2)

        if lang1NeedsTranslation {
            if job.subtitle1Mode == .pivot {
                guard let sessionA = s1, let sessionB = s2 else { throw SubStampError.translationError(underlying: NSError(domain: "SubStamp", code: -40)) }
                let mid = try await translationService.translate(cues: sourceCues, session: sessionA) { [weak self] c, t in
                    self?.stageProgress[.translating] = t == 0 ? 0 : (Double(c)/Double(t)) * 0.25
                }
                let english = mid.map { var n = $0; n.primaryText = $0.secondaryText ?? $0.primaryText; n.secondaryText = nil; return n }
                let finalRes = try await translationService.translate(cues: english, session: sessionB) { [weak self] c, t in
                    self?.stageProgress[.translating] = t == 0 ? 0.25 : 0.25 + (Double(c)/Double(t)) * 0.25
                }
                primaryCues = finalRes.map { var n = $0; n.primaryText = $0.secondaryText ?? $0.primaryText; n.secondaryText = nil; return n }
            } else {
                guard let session = s2 else { throw SubStampError.translationError(underlying: NSError(domain: "SubStamp", code: -41)) }
                let res = try await translationService.translate(cues: sourceCues, session: session) { [weak self] c, t in
                    self?.stageProgress[.translating] = t == 0 ? 0 : (Double(c)/Double(t)) * 0.5
                }
                primaryCues = res.map { var n = $0; n.primaryText = $0.secondaryText ?? $0.primaryText; n.secondaryText = nil; return n }
            }
        }

        if lang2NeedsTranslation {
            if job.subtitle2Mode == .pivot {
                guard let sessionA = s1, let sessionC = s3 else { throw SubStampError.translationError(underlying: NSError(domain: "SubStamp", code: -42)) }
                let mid = try await translationService.translate(cues: sourceCues, session: sessionA) { [weak self] c, t in
                    self?.stageProgress[.translating] = t == 0 ? 0.5 : 0.5 + (Double(c)/Double(t)) * 0.25
                }
                let english = mid.map { var n = $0; n.primaryText = $0.secondaryText ?? $0.primaryText; n.secondaryText = nil; return n }
                let finalRes = try await translationService.translate(cues: english, session: sessionC) { [weak self] c, t in
                    self?.stageProgress[.translating] = t == 0 ? 0.75 : 0.75 + (Double(c)/Double(t)) * 0.25
                }
                secondaryCues = finalRes.map { var n = $0; n.primaryText = $0.secondaryText ?? $0.primaryText; n.secondaryText = nil; return n }
            } else {
                guard let session = s3 else { throw SubStampError.translationError(underlying: NSError(domain: "SubStamp", code: -43)) }
                let res = try await translationService.translate(cues: sourceCues, session: session) { [weak self] c, t in
                    self?.stageProgress[.translating] = t == 0 ? 0.5 : 0.5 + (Double(c)/Double(t)) * 0.5
                }
                secondaryCues = res.map { var n = $0; n.primaryText = $0.secondaryText ?? $0.primaryText; n.secondaryText = nil; return n }
            }
        } else if job.subtitleMode == .bilingual && job.translationTargetLocale == baseLocale {
            secondaryCues = sourceCues
        }

        if job.subtitleMode == .bilingual {
            return zip(primaryCues, secondaryCues).map { p, s in
                SubtitleCue(id: p.id, start: p.start, end: p.end, primaryText: p.primaryText, secondaryText: s.primaryText, hasTranslationError: p.hasTranslationError || s.hasTranslationError)
            }
        } else {
            return primaryCues
        }
    }

    private func performAppleIntelligenceTranslations(job: JobModel, sourceCues: [SubtitleCue]) async throws -> [SubtitleCue] {
        let baseLocaleIdentifier = job.transcriptionLocale
        let sourceLocale = Locale(identifier: baseLocaleIdentifier)

        let sourceMinimal = Locale.Language(identifier: sourceLocale.identifier(.bcp47)).minimalIdentifier

        let lang1BCP47 = Locale(identifier: job.language1Locale).identifier(.bcp47)
        let lang1Target = Locale.Language(identifier: lang1BCP47)
        let lang1NeedsTranslation = lang1Target.minimalIdentifier != sourceMinimal

        var lang2Target: Locale.Language?
        var lang2NeedsTranslation = false
        if job.subtitleMode == .bilingual, let lang2ID = job.translationTargetLocale {
            let lang2BCP47 = Locale(identifier: lang2ID).identifier(.bcp47)
            let target = Locale.Language(identifier: lang2BCP47)
            lang2Target = target
            lang2NeedsTranslation = target.minimalIdentifier != sourceMinimal
        }

        var primaryCues = sourceCues
        var secondaryCues = sourceCues

        var translationTargets: [Locale.Language] = []
        if lang1NeedsTranslation { translationTargets.append(lang1Target) }
        if lang2NeedsTranslation, let lang2Target { translationTargets.append(lang2Target) }

        let translatedByTarget: [String: [SubtitleCue]]
        if translationTargets.isEmpty {
            translatedByTarget = [:]
        } else {
            translatedByTarget = try await appleIntelligenceTranslationService.translate(
                cues: sourceCues,
                source: sourceLocale,
                targets: translationTargets
            ) { [weak self] completed, total in
                let frac = total == 0 ? 0 : (Double(completed) / Double(total))
                self?.stageProgress[.translating] = frac
            }
        }

        if lang1NeedsTranslation {
            let key = lang1Target.minimalIdentifier
            if let res = translatedByTarget[key] {
                primaryCues = res.map { cue in
                    var next = cue
                    next.primaryText = cue.secondaryText ?? cue.primaryText
                    next.secondaryText = nil
                    return next
                }
            }
        }

        if lang2NeedsTranslation, let lang2Target {
            let key = lang2Target.minimalIdentifier
            if let res = translatedByTarget[key] {
                secondaryCues = res.map { cue in
                    var next = cue
                    next.primaryText = cue.secondaryText ?? cue.primaryText
                    next.secondaryText = nil
                    return next
                }
            }
        }

        if job.subtitleMode == .bilingual {
            return zip(primaryCues, secondaryCues).map { p, s in
                SubtitleCue(
                    id: p.id,
                    start: p.start,
                    end: p.end,
                    primaryText: p.primaryText,
                    secondaryText: s.primaryText,
                    hasTranslationError: p.hasTranslationError || s.hasTranslationError
                )
            }
        }

        return primaryCues
    }

    private func runTranslationOnly(job: JobModel, s1: TranslationSession?, s2: TranslationSession?, s3: TranslationSession?) async {
        do {
            currentStage = .translating
            stageStates[.translating] = .active
            var updatedJob = job
            updatedJob.stage = .translating
            updatedJob.updatedAt = Date()
            try jobStore.save(job: updatedJob)
            
            cues = try await performTranslations(job: job, sourceCues: cues, s1: s1, s2: s2, s3: s3)
            try jobStore.saveCues(cues, id: job.id, type: .translated)
            stageStates[.translating] = .done
            stageProgress[.translating] = 1
            updatedJob.stage = .rendering
            updatedJob.updatedAt = Date()
            try jobStore.save(job: updatedJob)
            readyForReview = true
            isRunning = false
            currentStage = .rendering
        } catch {
            self.error = (error as? SubStampError) ?? .translationError(underlying: error)
            markFailed()
        }
    }

    func continueAfterReview() {
        guard let job else { return }
        cancel()
        isRunning = true
        readyForReview = false
        task = Task { [weak self] in
            guard let self else { return }
            await self.runRenderExport(job: job)
        }
    }

    private func runRenderExport(job: JobModel) async {
        do {
            let asset = AVAsset(url: job.videoURL)
            currentStage = .rendering
            stageStates[.rendering] = .active
            var updatedJob = job
            updatedJob.stage = .rendering
            updatedJob.updatedAt = Date()
            try jobStore.save(job: updatedJob)
            let range = timeRange(for: job, asset: asset)
            
            let renderResult = try await subtitleRenderer.createComposition(
                asset: asset,
                cues: cues,
                mode: job.subtitleMode,
                style: job.subtitleStyle,
                layout: job.subtitleLayout,
                timeRange: range
            )
            stageStates[.rendering] = .done
            stageProgress[.rendering] = 1

            currentStage = .exporting
            stageStates[.exporting] = .active
            updatedJob.stage = .exporting
            updatedJob.updatedAt = Date()
            try jobStore.save(job: updatedJob)
            let exportedURL = try await exportService.export(
                composition: renderResult.composition,
                videoComposition: renderResult.videoComposition,
                preset: job.exportPreset
            ) { [weak self] progress in
                Task { @MainActor in
                    self?.stageProgress[.exporting] = progress
                }
            }
            stageStates[.exporting] = .done
            stageProgress[.exporting] = 1
            outputURL = exportedURL

            updatedJob.stage = .completed
            updatedJob.updatedAt = Date()
            updatedJob.outputURL = exportedURL
            try jobStore.save(job: updatedJob)
            currentStage = .completed
            isRunning = false
        } catch {
            self.error = (error as? SubStampError) ?? .exportFailed(underlying: error)
            markFailed()
        }
    }

    private func timeRange(for job: JobModel, asset: AVAsset) -> CMTimeRange? {
        guard job.isTestClip else { return nil }
        let maxDuration = min(job.testClipDuration, asset.duration.seconds)
        return CMTimeRange(start: .zero, duration: CMTime(seconds: maxDuration, preferredTimescale: 600))
    }

    private func markFailed() {
        stageStates[currentStage] = .failed
        isRunning = false
    }
}
