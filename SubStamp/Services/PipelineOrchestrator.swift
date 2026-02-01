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

    func start(job: JobModel, translationSession: TranslationSession?) {
        cancel()
        resetStages()
        self.job = job
        isRunning = true
        readyForReview = false
        print("[SUBSTAMP] start() mode=\(job.subtitleMode) lang1=\(job.language1Locale) lang2=\(job.translationTargetLocale ?? "nil") session=\(translationSession != nil)")
        task = Task { [weak self] in
            guard let self else { return }
            await self.runPipeline(job: job, translationSession: translationSession)
        }
    }

    func resume(
        job: JobModel,
        translationSession: TranslationSession?,
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
                await self.runTranslationOnly(job: job, translationSession: translationSession)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    private func runPipeline(job: JobModel, translationSession: TranslationSession?) async {
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

            if job.subtitleMode == .bilingual {
                updatedJob.stage = .translating
                updatedJob.updatedAt = Date()
                try jobStore.save(job: updatedJob)
                currentStage = .translating
                stageStates[.translating] = .active
                guard let session = translationSession else {
                    print("[SUBSTAMP] ERROR: translationSession is nil!")
                    throw SubStampError.translationError(underlying: NSError(domain: "SubStamp", code: -20))
                }
                let translated = try await translationService.translate(
                    cues: cues,
                    session: session
                ) { [weak self] completed, total in
                    self?.stageProgress[.translating] = total == 0 ? 0 : Double(completed) / Double(total)
                }
                cues = translated
                let withSecondary = cues.filter { $0.secondaryText != nil }.count
                print("[SUBSTAMP] translated \(withSecondary)/\(cues.count) have secondaryText")
                try jobStore.saveCues(translated, id: job.id, type: .translated)
                stageStates[.translating] = .done
                stageProgress[.translating] = 1
            } else if job.language1Locale != job.transcriptionLocale {
                // Single Mode with Language 1 != Audio -> Translate Primary
                print("[SUBSTAMP] Single mode translation: \(job.transcriptionLocale) -> \(job.language1Locale)")
                updatedJob.stage = .translating
                updatedJob.updatedAt = Date()
                try jobStore.save(job: updatedJob)
                currentStage = .translating
                stageStates[.translating] = .active
                
                guard let session = translationSession else {
                    print("[SUBSTAMP] ERROR: translationSession is nil (single mode)!")
                    throw SubStampError.translationError(underlying: NSError(domain: "SubStamp", code: -20))
                }
                
                // Translate, but result will put translation in secondaryText
                let translated = try await translationService.translate(
                    cues: cues,
                    session: session
                ) { [weak self] completed, total in
                    self?.stageProgress[.translating] = total == 0 ? 0 : Double(completed) / Double(total)
                }
                
                // For Single Mode, we want the translation to be the Primary Text
                cues = translated.map { cue in
                    var newCue = cue
                    if let translatedText = cue.secondaryText {
                        newCue.primaryText = translatedText
                        newCue.secondaryText = nil // Clear secondary
                    }
                    return newCue
                }
                
                print("[SUBSTAMP] Primary translation complete.")
                try jobStore.saveCues(cues, id: job.id, type: .translated) // Save as translated cues (acting as primary)
                stageStates[.translating] = .done
                stageProgress[.translating] = 1
            } else {
                print("[SUBSTAMP] skip translation mode=\(job.subtitleMode)")
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

    private func runTranslationOnly(job: JobModel, translationSession: TranslationSession?) async {
        do {
            currentStage = .translating
            stageStates[.translating] = .active
            var updatedJob = job
            updatedJob.stage = .translating
            updatedJob.updatedAt = Date()
            try jobStore.save(job: updatedJob)
            guard let session = translationSession else {
                throw SubStampError.translationError(underlying: NSError(domain: "SubStamp", code: -21))
            }
            let translated = try await translationService.translate(
                cues: cues,
                session: session
            ) { [weak self] completed, total in
                self?.stageProgress[.translating] = total == 0 ? 0 : Double(completed) / Double(total)
            }
            cues = translated
            try jobStore.saveCues(translated, id: job.id, type: .translated)
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
