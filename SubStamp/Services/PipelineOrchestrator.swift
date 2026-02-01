import AVFoundation
import Combine
import Foundation
import Translation

@MainActor
final class PipelineOrchestrator: ObservableObject {
    private let transcriptionService = TranscriptionService()
    private let translationService = TranslationService()
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

    func start(job: JobModel, translationSession1: TranslationSession?, translationSession2: TranslationSession?) {
        cancel()
        resetStages()
        self.job = job
        isRunning = true
        readyForReview = false
        print("[SUBSTAMP] start() mode=\(job.subtitleMode) lang1=\(job.language1Locale) lang2=\(job.translationTargetLocale ?? "nil") session1=\(translationSession1 != nil) session2=\(translationSession2 != nil)")
        task = Task { [weak self] in
            guard let self else { return }
            await self.runPipeline(job: job, translationSession1: translationSession1, translationSession2: translationSession2)
        }
    }

    func resume(
        job: JobModel,
        translationSession1: TranslationSession?,
        translationSession2: TranslationSession?,
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
        } else if job.subtitleMode == .single {
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
                await self.runTranslationOnly(job: job, translationSession1: translationSession1, translationSession2: translationSession2)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    private func runPipeline(job: JobModel, translationSession1: TranslationSession?, translationSession2: TranslationSession?) async {
        do {
            stageStates[.assets] = .done
            stageProgress[.assets] = 1

            var updatedJob = job
            updatedJob.stage = .transcribing
            updatedJob.updatedAt = Date()
            try jobStore.save(job: updatedJob)
            currentStage = .transcribing
            stageStates[.transcribing] = .active
            AppLog.append("Starting transcribing for locale \(job.transcriptionLocale)")

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

            // Determine what translations are needed
            // Base language = transcriptionLocale (the audio language)
            // Language 1: use transcribed text if matches base, else translate from base
            // Language 2 (bilingual): use transcribed text if matches base, else translate from base
            let baseLocale = job.transcriptionLocale
            let lang1NeedsTranslation = job.language1Locale != baseLocale
            let lang2NeedsTranslation = job.subtitleMode == .bilingual && (job.translationTargetLocale != nil && job.translationTargetLocale != baseLocale)
            
            // Check if any translation is needed
            let needsTranslation = lang1NeedsTranslation || lang2NeedsTranslation
            
            if needsTranslation {
                updatedJob.stage = .translating
                updatedJob.updatedAt = Date()
                try jobStore.save(job: updatedJob)
                currentStage = .translating
                stageStates[.translating] = .active
                
                // Initialize with transcribed text
                var finalCues = cues
                
                if job.subtitleMode == .bilingual {
                    // Bilingual mode: need both Language 1 and Language 2
                    var primaryCues = finalCues
                    var secondaryCues = finalCues
                    
                    // Translate to Language 1 if needed
                    if lang1NeedsTranslation {
                        guard let session1 = translationSession1 else {
                            print("[SUBSTAMP] ERROR: translationSession1 is nil for Lang1 translation!")
                            throw SubStampError.translationError(underlying: NSError(domain: "SubStamp", code: -20))
                        }
                        print("[SUBSTAMP] Translating base \(baseLocale) -> Language 1 \(job.language1Locale)")
                        let translatedToLang1 = try await translationService.translate(
                            cues: finalCues,
                            session: session1
                        ) { [weak self] completed, total in
                            self?.stageProgress[.translating] = total == 0 ? 0 : Double(completed) / Double(total)
                        }
                        primaryCues = translatedToLang1.map { cue in
                            var newCue = cue
                            if let translatedText = cue.secondaryText {
                                newCue.primaryText = translatedText
                            }
                            newCue.secondaryText = nil
                            return newCue
                        }
                    }
                    
                    // Translate to Language 2 if needed
                    if lang2NeedsTranslation {
                        guard let session2 = translationSession2 else {
                            print("[SUBSTAMP] ERROR: translationSession2 is nil for Lang2 translation!")
                            throw SubStampError.translationError(underlying: NSError(domain: "SubStamp", code: -21))
                        }
                        print("[SUBSTAMP] Translating base \(baseLocale) -> Language 2 \(job.translationTargetLocale!)")
                        let translatedToLang2 = try await translationService.translate(
                            cues: finalCues,
                            session: session2
                        ) { [weak self] completed, total in
                            self?.stageProgress[.translating] = total == 0 ? 0 : Double(completed) / Double(total)
                        }
                        secondaryCues = translatedToLang2.map { cue in
                            var newCue = cue
                            if let translatedText = cue.secondaryText {
                                newCue.primaryText = translatedText
                            }
                            newCue.secondaryText = nil
                            return newCue
                        }
                    }
                    
                    // Combine primary and secondary texts
                    finalCues = zip(primaryCues, secondaryCues).map { primary, secondary in
                        SubtitleCue(
                            id: primary.id,
                            start: primary.start,
                            end: primary.end,
                            primaryText: primary.primaryText,
                            secondaryText: secondary.primaryText,
                            hasTranslationError: primary.hasTranslationError || secondary.hasTranslationError
                        )
                    }
                    
                    let withSecondary = finalCues.filter { $0.secondaryText != nil }.count
                    print("[SUBSTAMP] Bilingual translation complete: \(finalCues.count) cues, \(withSecondary) with secondary text")
                    
                } else if job.subtitleMode == .single && lang1NeedsTranslation {
                    // Single mode: only need Language 1
                    guard let session1 = translationSession1 else {
                        print("[SUBSTAMP] ERROR: translationSession1 is nil for single mode translation!")
                        throw SubStampError.translationError(underlying: NSError(domain: "SubStamp", code: -22))
                    }
                    print("[SUBSTAMP] Single mode translation: \(baseLocale) -> \(job.language1Locale)")
                    let translated = try await translationService.translate(
                        cues: finalCues,
                        session: session1
                    ) { [weak self] completed, total in
                        self?.stageProgress[.translating] = total == 0 ? 0 : Double(completed) / Double(total)
                    }
                    
                    // Move translation to primary
                    finalCues = translated.map { cue in
                        var newCue = cue
                        if let translatedText = cue.secondaryText {
                            newCue.primaryText = translatedText
                        }
                        newCue.secondaryText = nil
                        return newCue
                    }
                    
                    print("[SUBSTAMP] Primary translation complete.")
                }
                
                cues = finalCues
                try jobStore.saveCues(cues, id: job.id, type: .translated)
                stageStates[.translating] = .done
                stageProgress[.translating] = 1
            } else {
                print("[SUBSTAMP] Skip translation - using transcribed text directly")
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
        } catch let error as SubStampError {
            self.error = error
            AppLog.append("\(currentStage.rawValue) failed: \(error.localizedDescription)")
            if let suggestion = error.recoverySuggestion { AppLog.append("  \(suggestion)") }
            markFailed()
        } catch {
            self.error = .exportFailed(underlying: error)
            AppLog.append("\(currentStage.rawValue) failed: \(error.localizedDescription)")
            AppLog.append(error: error)
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
            
            let withSecondary = cues.filter { $0.secondaryText != nil }.count
            print("[SUBSTAMP] render cues=\(cues.count) withSecondary=\(withSecondary) mode=\(job.subtitleMode)")
            
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
                self?.stageProgress[.exporting] = progress
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
        } catch let error as SubStampError {
            self.error = error
            AppLog.append("Rendering/Export failed: \(error.localizedDescription)")
            markFailed()
        } catch {
            self.error = .exportFailed(underlying: error)
            AppLog.append(error: error)
            markFailed()
        }
    }

    private func runTranslationOnly(job: JobModel, translationSession1: TranslationSession?, translationSession2: TranslationSession?) async {
        do {
            currentStage = .translating
            stageStates[.translating] = .active
            var updatedJob = job
            updatedJob.stage = .translating
            updatedJob.updatedAt = Date()
            try jobStore.save(job: updatedJob)
            
            // Determine what translations are needed
            let baseLocale = job.transcriptionLocale
            let lang1NeedsTranslation = job.language1Locale != baseLocale
            let lang2NeedsTranslation = job.subtitleMode == .bilingual && (job.translationTargetLocale != nil && job.translationTargetLocale != baseLocale)
            
            // Initialize with existing cues
            var finalCues = cues
            
            if job.subtitleMode == .bilingual {
                // Bilingual mode: need both Language 1 and Language 2
                var primaryCues = finalCues
                var secondaryCues = finalCues
                
                // Translate to Language 1 if needed
                if lang1NeedsTranslation {
                    guard let session1 = translationSession1 else {
                        print("[SUBSTAMP] ERROR: translationSession1 is nil for Lang1 translation!")
                        throw SubStampError.translationError(underlying: NSError(domain: "SubStamp", code: -23))
                    }
                    print("[SUBSTAMP] Resume: Translating base \(baseLocale) -> Language 1 \(job.language1Locale)")
                    let translatedToLang1 = try await translationService.translate(
                        cues: finalCues,
                        session: session1
                    ) { [weak self] completed, total in
                        self?.stageProgress[.translating] = total == 0 ? 0 : Double(completed) / Double(total)
                    }
                    primaryCues = translatedToLang1.map { cue in
                        var newCue = cue
                        if let translatedText = cue.secondaryText {
                            newCue.primaryText = translatedText
                        }
                        newCue.secondaryText = nil
                        return newCue
                    }
                }
                
                // Translate to Language 2 if needed
                if lang2NeedsTranslation {
                    guard let session2 = translationSession2 else {
                        print("[SUBSTAMP] ERROR: translationSession2 is nil for Lang2 translation!")
                        throw SubStampError.translationError(underlying: NSError(domain: "SubStamp", code: -24))
                    }
                    print("[SUBSTAMP] Resume: Translating base \(baseLocale) -> Language 2 \(job.translationTargetLocale!)")
                    let translatedToLang2 = try await translationService.translate(
                        cues: finalCues,
                        session: session2
                    ) { [weak self] completed, total in
                        self?.stageProgress[.translating] = total == 0 ? 0 : Double(completed) / Double(total)
                    }
                    secondaryCues = translatedToLang2.map { cue in
                        var newCue = cue
                        if let translatedText = cue.secondaryText {
                            newCue.primaryText = translatedText
                        }
                        newCue.secondaryText = nil
                        return newCue
                    }
                }
                
                // Combine primary and secondary texts
                finalCues = zip(primaryCues, secondaryCues).map { primary, secondary in
                    SubtitleCue(
                        id: primary.id,
                        start: primary.start,
                        end: primary.end,
                        primaryText: primary.primaryText,
                        secondaryText: secondary.primaryText,
                        hasTranslationError: primary.hasTranslationError || secondary.hasTranslationError
                    )
                }
                
            } else if lang1NeedsTranslation {
                // Single mode: only need Language 1
                guard let session1 = translationSession1 else {
                    print("[SUBSTAMP] ERROR: translationSession1 is nil for single mode translation!")
                    throw SubStampError.translationError(underlying: NSError(domain: "SubStamp", code: -25))
                }
                print("[SUBSTAMP] Resume: Single mode translation: \(baseLocale) -> \(job.language1Locale)")
                let translated = try await translationService.translate(
                    cues: finalCues,
                    session: session1
                ) { [weak self] completed, total in
                    self?.stageProgress[.translating] = total == 0 ? 0 : Double(completed) / Double(total)
                }
                
                // Move translation to primary
                finalCues = translated.map { cue in
                    var newCue = cue
                    if let translatedText = cue.secondaryText {
                        newCue.primaryText = translatedText
                    }
                    newCue.secondaryText = nil
                    return newCue
                }
            }
            
            cues = finalCues
            try jobStore.saveCues(cues, id: job.id, type: .translated)
            stageStates[.translating] = .done
            stageProgress[.translating] = 1
            updatedJob.stage = .rendering
            updatedJob.updatedAt = Date()
            try jobStore.save(job: updatedJob)
            readyForReview = true
            isRunning = false
            currentStage = .rendering
        } catch let error as SubStampError {
            self.error = error
            AppLog.append("Translation failed: \(error.localizedDescription)")
            markFailed()
        } catch {
            self.error = .translationError(underlying: error)
            AppLog.append(error: error)
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
