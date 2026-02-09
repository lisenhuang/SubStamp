import AVFoundation
import Combine
import Foundation
import Translation

@MainActor
final class PipelineOrchestrator: ObservableObject {
    private let transcriptionService = TranscriptionService()
    private let translationService = TranslationService()
    private let appleIntelligenceTranslationService = AppleIntelligenceTranslationService()
    private let appleIntelligenceTranscriptionRepairService = AppleIntelligenceTranscriptionRepairService()
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
    @Published var transcriptionComplete = false
    @Published var translationComplete = false

    private var task: Task<Void, Never>?
    private var frameworkSession1: TranslationSession?
    private var frameworkSession2: TranslationSession?
    private var frameworkSession3: TranslationSession?

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
        transcriptionComplete = false
        translationComplete = false
    }

    func updateTranslationSessions(s1: TranslationSession?, s2: TranslationSession?, s3: TranslationSession?) {
        frameworkSession1 = s1
        frameworkSession2 = s2
        frameworkSession3 = s3
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
        // Nil out framework sessions so cancelled work can't use stale sessions
        frameworkSession1 = nil
        frameworkSession2 = nil
        frameworkSession3 = nil
        BackgroundTaskManager.shared.end(success: false)
    }

    // MARK: - New Phase Methods (Step 2/3/4 wizard)

    func startTranscription(job: JobModel) {
        cancel()
        resetStages()
        self.job = job
        isRunning = true
        transcriptionComplete = false
        task = Task { [weak self] in
            guard let self else { return }
            await self.runTranscriptionPhase(job: job)
        }
    }

    func startTranslation(job: JobModel, translationSession1: TranslationSession?, translationSession2: TranslationSession?, translationSession3: TranslationSession?) {
        self.job = job
        isRunning = true
        translationComplete = false
        error = nil
        updateTranslationSessions(s1: translationSession1, s2: translationSession2, s3: translationSession3)
        stageStates[.translating] = .pending
        stageProgress[.translating] = 0
        task = Task { [weak self] in
            guard let self else { return }
            await self.runTranslationPhase(job: job)
        }
    }

    func startRenderExport(job: JobModel) {
        self.job = job
        isRunning = true
        error = nil
        stageStates[.rendering] = .pending
        stageProgress[.rendering] = 0
        stageStates[.exporting] = .pending
        stageProgress[.exporting] = 0
        outputURL = nil
        task = Task { [weak self] in
            guard let self else { return }
            await self.runRenderExport(job: job)
        }
    }

    private func runTranscriptionPhase(job: JobModel) async {
        do {
            try Task.checkCancellation()

            stageStates[.assets] = .done
            stageProgress[.assets] = 1

            try Task.checkCancellation()

            var updatedJob = job
            updatedJob.stage = .transcribing
            updatedJob.updatedAt = Date()
            try jobStore.save(job: updatedJob)
            currentStage = .transcribing
            stageStates[.transcribing] = .active

            let asset = AVAsset(url: job.videoURL)
            let range = timeRange(for: job, asset: asset)
            let shouldFixTranscription = job.translationProvider == .appleIntelligence && job.fixTranscriptionWithAppleIntelligence
            let transcriptionWeight = shouldFixTranscription ? 0.8 : 1.0
            let transcriptionResult = try await transcriptionService.transcribe(
                asset: asset,
                locale: Locale(identifier: job.transcriptionLocale),
                timeRange: range
            ) { [weak self] progress, count in
                self?.stageProgress[.transcribing] = progress * transcriptionWeight
            }

            try Task.checkCancellation()

            cues = transcriptionResult.cues
            try jobStore.saveCues(cues, id: job.id, type: .transcribed)

            if shouldFixTranscription {
#if DEBUG
                AppLog.append("[AI-TRANSCRIPT] repair(start) cues=\(cues.count) locale=\(job.transcriptionLocale)")
#endif
                do {
                    try Task.checkCancellation()
                    cues = try await appleIntelligenceTranscriptionRepairService.repair(
                        cues: cues,
                        locale: Locale(identifier: job.transcriptionLocale)
                    ) { [weak self] completed, total in
                        let frac = total == 0 ? 0 : (Double(completed) / Double(total))
                        self?.stageProgress[.transcribing] = transcriptionWeight + frac * (1.0 - transcriptionWeight)
                    }
                    try jobStore.saveCues(cues, id: job.id, type: .transcribed)
#if DEBUG
                    AppLog.append("[AI-TRANSCRIPT] repair(done)")
#endif
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
#if DEBUG
                    AppLog.append("[AI-TRANSCRIPT] repair(failed): \(error.localizedDescription)")
#endif
                }
            }

            try Task.checkCancellation()

            // Preserve raw transcription in originalTranscription before any translation
            cues = cues.map { cue in
                var updated = cue
                updated.originalTranscription = cue.primaryText
                return updated
            }
            try jobStore.saveCues(cues, id: job.id, type: .transcribed)

            stageStates[.transcribing] = .done
            stageProgress[.transcribing] = 1
            transcriptionComplete = true
            isRunning = false
        } catch is CancellationError {
            isRunning = false
            return
        } catch {
            guard !Task.isCancelled else { isRunning = false; return }
            self.error = (error as? SubStampError) ?? .speechAnalyzerError(underlying: error)
            markFailed()
        }
    }

    private func runTranslationPhase(job: JobModel) async {
        do {
            try Task.checkCancellation()

            currentStage = .translating
            stageStates[.translating] = .active
            var updatedJob = job
            updatedJob.stage = .translating
            updatedJob.updatedAt = Date()
            try jobStore.save(job: updatedJob)

            // Build source cues from originalTranscription so retranslation uses the original text
            let sourceCues = cues.map { cue -> SubtitleCue in
                var source = cue
                if let original = cue.originalTranscription {
                    source.primaryText = original
                }
                source.secondaryText = nil
                source.hasTranslationError = false
                return source
            }

            // Capture original transcription before translation overwrites cues
            let originalByID = Dictionary(uniqueKeysWithValues: cues.map { ($0.id, $0.originalTranscription ?? $0.primaryText) })

            let translatedCues = try await performTranslations(job: job, sourceCues: sourceCues)

            // Restore originalTranscription on translated cues (performTranslations doesn't carry it)
            cues = translatedCues.map { cue in
                var updated = cue
                updated.originalTranscription = originalByID[cue.id] ?? cue.primaryText
                return updated
            }

            try Task.checkCancellation()

            try jobStore.saveCues(cues, id: job.id, type: .translated)
            stageStates[.translating] = .done
            stageProgress[.translating] = 1
            translationComplete = true
            isRunning = false
        } catch is CancellationError {
            isRunning = false
            return
        } catch {
            guard !Task.isCancelled else { isRunning = false; return }
            self.error = (error as? SubStampError) ?? .translationError(underlying: error)
            markFailed()
        }
    }

    private func performTranslations(job: JobModel, sourceCues: [SubtitleCue]) async throws -> [SubtitleCue] {
        switch job.translationProvider {
        case .translationFramework:
            return try await performFrameworkTranslations(job: job, sourceCues: sourceCues)
        case .appleIntelligence:
            return try await performAppleIntelligenceTranslations(job: job, sourceCues: sourceCues)
        }
    }

    private func performFrameworkTranslations(job: JobModel, sourceCues: [SubtitleCue]) async throws -> [SubtitleCue] {
        let baseLocale = job.transcriptionLocale
        let lang1NeedsTranslation = job.language1Locale != baseLocale
        let lang2NeedsTranslation = job.subtitleMode == .bilingual && (job.translationTargetLocale != nil && job.translationTargetLocale != baseLocale)

        var primaryCues = sourceCues
        var secondaryCues = sourceCues

        // Session Mapping:
        // s1: Audio -> English (pivot common)
        // s2: Sub 1 Final Leg (A->T1 or E->T1)
        // s3: Sub 2 Final Leg (A->T2 or E->T2)

        try Task.checkCancellation()

        if lang1NeedsTranslation {
            if job.subtitle1Mode == .pivot {
                guard let sessionA = frameworkSession1, let sessionB = frameworkSession2 else { throw SubStampError.translationError(underlying: NSError(domain: "SubStamp", code: -40)) }
                let mid = try await translationService.translate(cues: sourceCues, session: sessionA) { [weak self] c, t in
                    self?.stageProgress[.translating] = t == 0 ? 0 : (Double(c)/Double(t)) * 0.25
                }
                let english = mapTranslationOutputToPrimary(mid, fallbackToSourceTextOnFailure: true)
                let finalRes = try await translationService.translate(cues: english, session: sessionB) { [weak self] c, t in
                    self?.stageProgress[.translating] = t == 0 ? 0.25 : 0.25 + (Double(c)/Double(t)) * 0.25
                }
                primaryCues = mapTranslationOutputToPrimary(finalRes, fallbackToSourceTextOnFailure: true)
            } else {
                guard let session = frameworkSession2 else { throw SubStampError.translationError(underlying: NSError(domain: "SubStamp", code: -41)) }
                let res = try await translationService.translate(cues: sourceCues, session: session) { [weak self] c, t in
                    self?.stageProgress[.translating] = t == 0 ? 0 : (Double(c)/Double(t)) * 0.5
                }
                primaryCues = mapTranslationOutputToPrimary(res, fallbackToSourceTextOnFailure: true)
            }
        }

        try Task.checkCancellation()

        if lang2NeedsTranslation {
            if job.subtitle2Mode == .pivot {
                guard let sessionA = frameworkSession1, let sessionC = frameworkSession3 else { throw SubStampError.translationError(underlying: NSError(domain: "SubStamp", code: -42)) }
                let mid = try await translationService.translate(cues: sourceCues, session: sessionA) { [weak self] c, t in
                    self?.stageProgress[.translating] = t == 0 ? 0.5 : 0.5 + (Double(c)/Double(t)) * 0.25
                }
                let english = mapTranslationOutputToPrimary(mid, fallbackToSourceTextOnFailure: true)
                let finalRes = try await translationService.translate(cues: english, session: sessionC) { [weak self] c, t in
                    self?.stageProgress[.translating] = t == 0 ? 0.75 : 0.75 + (Double(c)/Double(t)) * 0.25
                }
                secondaryCues = mapTranslationOutputToPrimary(finalRes, fallbackToSourceTextOnFailure: false)
            } else {
                guard let session = frameworkSession3 else { throw SubStampError.translationError(underlying: NSError(domain: "SubStamp", code: -43)) }
                let res = try await translationService.translate(cues: sourceCues, session: session) { [weak self] c, t in
                    self?.stageProgress[.translating] = t == 0 ? 0.5 : 0.5 + (Double(c)/Double(t)) * 0.5
                }
                secondaryCues = mapTranslationOutputToPrimary(res, fallbackToSourceTextOnFailure: false)
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

    private func mapTranslationOutputToPrimary(
        _ cues: [SubtitleCue],
        fallbackToSourceTextOnFailure: Bool,
        showFailureText: Bool = false
    ) -> [SubtitleCue] {
        cues.map { cue in
            let originalTrimmed = cue.primaryText.trimmingCharacters(in: .whitespacesAndNewlines)
            if originalTrimmed.isEmpty {
                var next = cue
                next.primaryText = ""
                next.secondaryText = nil
                next.hasTranslationError = false
                return next
            }

            let translated = cue.secondaryText?.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasValidTranslation = (translated != nil && !(translated?.isEmpty ?? true) && cue.hasTranslationError == false)

            var next = cue
            if hasValidTranslation, let translated {
                next.primaryText = SubtitleTextCleaner.clean(translated)
                next.hasTranslationError = false
            } else if showFailureText, let translated, !(translated.isEmpty) {
                // In testing/debug scenarios we want to surface the model's failure text in-line.
                next.primaryText = translated
                next.hasTranslationError = true
            } else {
                next.primaryText = fallbackToSourceTextOnFailure ? cue.primaryText : ""
                next.hasTranslationError = true
            }
            next.secondaryText = nil
            return next
        }
    }

    private func applyFrameworkFallbackIfNeeded(
        job: JobModel,
        aiOutput: [SubtitleCue],
        sourceCues: [SubtitleCue],
        sourceLanguage: Locale.Language,
        pivotLanguage: Locale.Language?,
        targetLanguage: Locale.Language,
        firstLegSession: TranslationSession?,
        secondLegSession: TranslationSession?,
        label: String
    ) async -> [SubtitleCue] {
        let failedIDs = cuesNeedingFrameworkFallback(aiOutput)
        guard !failedIDs.isEmpty else { return aiOutput }

        guard let secondLegSession else {
#if DEBUG
            AppLog.append("[AI-FALLBACK] skip label=\(label) reason=noFrameworkSession failed=\(failedIDs.count)")
#endif
            return aiOutput
        }

        if let pivotLanguage, firstLegSession == nil {
#if DEBUG
            AppLog.append("[AI-FALLBACK] skip label=\(label) reason=missingPivotSession failed=\(failedIDs.count)")
#endif
            return aiOutput
        }

        let canTranslate = await canUseFrameworkFallback(
            source: sourceLanguage,
            pivot: pivotLanguage,
            target: targetLanguage
        )
        guard canTranslate else {
#if DEBUG
            let pivotID = pivotLanguage?.minimalIdentifier ?? "nil"
            AppLog.append("[AI-FALLBACK] skip label=\(label) reason=frameworkUnsupported source=\(sourceLanguage.minimalIdentifier) pivot=\(pivotID) target=\(targetLanguage.minimalIdentifier) failed=\(failedIDs.count)")
#endif
            return aiOutput
        }

        let sourceByID = Dictionary(uniqueKeysWithValues: sourceCues.map { ($0.id, $0) })
        let subset = failedIDs.compactMap { sourceByID[$0] }
        guard !subset.isEmpty else { return aiOutput }

#if DEBUG
        AppLog.append("[AI-FALLBACK] start label=\(label) failed=\(subset.count) mode=\(pivotLanguage == nil ? "direct" : "pivot")")
#endif

        let translatedSubset: [SubtitleCue]
        do {
            if let pivotLanguage, let firstLegSession {
                let mid = try await translationService.translate(cues: subset, session: firstLegSession) { _, _ in }
                let pivoted = mapTranslationOutputToPrimary(mid, fallbackToSourceTextOnFailure: true)
                translatedSubset = try await translationService.translate(cues: pivoted, session: secondLegSession) { _, _ in }
            } else {
                translatedSubset = try await translationService.translate(cues: subset, session: secondLegSession) { _, _ in }
            }
        } catch {
#if DEBUG
            AppLog.append("[AI-FALLBACK] failed label=\(label) error=\(error.localizedDescription)")
#endif
            return aiOutput
        }

        let fallbackByID: [UUID: String] = Dictionary(uniqueKeysWithValues: translatedSubset.compactMap { cue in
            guard cue.hasTranslationError == false,
                  let text = cue.secondaryText?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            return (cue.id, text)
        })

        if fallbackByID.isEmpty {
#if DEBUG
            AppLog.append("[AI-FALLBACK] done label=\(label) fixed=0")
#endif
            return aiOutput
        }

        var output = aiOutput
        var fixed = 0
        for index in output.indices {
            let cueID = output[index].id
            guard failedIDs.contains(cueID), let text = fallbackByID[cueID] else { continue }
            output[index].secondaryText = SubtitleTextCleaner.clean(text)
            output[index].hasTranslationError = false
            fixed += 1
        }

#if DEBUG
        AppLog.append("[AI-FALLBACK] done label=\(label) fixed=\(fixed)/\(failedIDs.count)")
#endif

        return output
    }

    private func cuesNeedingFrameworkFallback(_ cues: [SubtitleCue]) -> Set<UUID> {
        Set(cues.compactMap { cue in
            let original = cue.primaryText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !original.isEmpty else { return nil }
            if cue.hasTranslationError { return cue.id }
            let translated = cue.secondaryText?.trimmingCharacters(in: .whitespacesAndNewlines)
            if translated == nil || translated?.isEmpty == true { return cue.id }
            return nil
        })
    }

    private func canUseFrameworkFallback(
        source: Locale.Language,
        pivot: Locale.Language?,
        target: Locale.Language
    ) async -> Bool {
        let availability = LanguageAvailability()

        if let pivot {
            let status1 = await availability.status(from: source, to: pivot)
            let status2 = await availability.status(from: pivot, to: target)
            let ok1 = (status1 == .installed || status1 == .supported)
            let ok2 = (status2 == .installed || status2 == .supported)
            return ok1 && ok2
        }

        let status = await availability.status(from: source, to: target)
        return status == .installed || status == .supported
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

        var translatedByTarget: [String: [SubtitleCue]]
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
                primaryCues = mapTranslationOutputToPrimary(res, fallbackToSourceTextOnFailure: true, showFailureText: true)
            }
        }

        if lang2NeedsTranslation, let lang2Target {
            let key = lang2Target.minimalIdentifier
            if let res = translatedByTarget[key] {
                secondaryCues = mapTranslationOutputToPrimary(res, fallbackToSourceTextOnFailure: false, showFailureText: true)
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

    private func runRenderExport(job: JobModel) async {
        do {
            try Task.checkCancellation()

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

            try Task.checkCancellation()

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

            try Task.checkCancellation()

            stageStates[.exporting] = .done
            stageProgress[.exporting] = 1
            outputURL = exportedURL

            updatedJob.stage = .completed
            updatedJob.updatedAt = Date()
            updatedJob.outputURL = exportedURL
            try jobStore.save(job: updatedJob)
            currentStage = .completed
            isRunning = false
        } catch is CancellationError {
            isRunning = false
            return
        } catch {
            guard !Task.isCancelled else { isRunning = false; return }
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
