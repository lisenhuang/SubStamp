import SwiftUI
import Translation
import UIKit

struct ProcessingView: View {
    @Bindable var orchestrator: PipelineOrchestrator
    let job: JobModel
    var resumeTranscribed: [SubtitleCue]? = nil
    var resumeTranslated: [SubtitleCue]? = nil
    var onChangeSettings: () -> Void
    var onCompleted: (URL) -> Void

    @State private var translationConfig: TranslationSession.Configuration?
    @State private var translationSession: TranslationSession?
    @State private var showCancelDialog = false
    @State private var backgroundTaskIdentifier: String?
    @State private var didResume = false
    @State private var keepScreenAwake = false

    var body: some View {
        ScrollView {
            VStack(spacing: AppSpacing.l) {
                WizardHeaderView(
                    step: 3,
                    total: 4,
                    title: "Processing",
                    subtitle: "We'll continue even if the screen locks."
                )

                PipelineStageRow(
                    title: "Speech assets",
                    state: orchestrator.stageStates[.assets] ?? .pending,
                    progress: orchestrator.stageProgress[.assets] ?? 0,
                    detail: "Ensuring required models are ready."
                )

                PipelineStageRow(
                    title: "Transcribing",
                    state: orchestrator.stageStates[.transcribing] ?? .pending,
                    progress: orchestrator.stageProgress[.transcribing] ?? 0,
                    detail: "Generating time-coded subtitles."
                )

                PipelineStageRow(
                    title: "Translating",
                    state: orchestrator.stageStates[.translating] ?? .pending,
                    progress: orchestrator.stageProgress[.translating] ?? 0,
                    detail: job.subtitleMode == .bilingual ? "Translating each cue." : "Skipped for transcript-only mode."
                )

                PipelineStageRow(
                    title: "Rendering",
                    state: orchestrator.stageStates[.rendering] ?? .pending,
                    progress: orchestrator.stageProgress[.rendering] ?? 0,
                    detail: "Burning subtitles into the video."
                )

                PipelineStageRow(
                    title: "Exporting",
                    state: orchestrator.stageStates[.exporting] ?? .pending,
                    progress: orchestrator.stageProgress[.exporting] ?? 0,
                    detail: "Writing the new file."
                )

                VStack(alignment: .leading, spacing: AppSpacing.s) {
                    Text("Tips")
                        .font(AppTypography.bodyEmphasis)
                    Text("You can lock the phone; we’ll continue when possible.")
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.secondaryText)
                    Text("If iOS stops background work, you can resume here.")
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.secondaryText)
                    Toggle("Keep screen awake", isOn: $keepScreenAwake)
                        .font(AppTypography.caption)
                }
                .padding()
                .background(AppColors.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius)
                        .stroke(AppColors.cardBorder, lineWidth: 1)
                )

                if let error = orchestrator.error {
                    Text(error.errorDescription ?? "Processing failed.")
                        .font(AppTypography.bodyEmphasis)
                        .foregroundStyle(AppColors.error)
                    if let suggestion = error.recoverySuggestion {
                        Text(suggestion)
                            .font(AppTypography.caption)
                            .foregroundStyle(AppColors.secondaryText)
                    }
                    HStack(spacing: AppSpacing.s) {
                        PrimaryButton(title: "Retry stage", systemImage: "arrow.clockwise") {
                            restartPipeline()
                        }
                        PrimaryButton(title: "Change settings", systemImage: "slider.horizontal.3") {
                            onChangeSettings()
                        }
                    }
                } else {
                    HStack(spacing: AppSpacing.s) {
                        PrimaryButton(title: "Cancel", systemImage: "xmark.circle") {
                            showCancelDialog = true
                        }
                        PrimaryButton(title: "Run in background", systemImage: "moon.stars") {
                            submitBackgroundTask()
                        }
                    }
                }
            }
            .padding(AppSpacing.l)
        }
        .background(AppColors.background)
        .confirmationDialog("Cancel processing?", isPresented: $showCancelDialog) {
            Button("Stop processing", role: .destructive) {
                orchestrator.cancel()
                BackgroundTaskManager.shared.end(success: false)
                onChangeSettings()
            }
        }
        .onAppear {
            startPipelineIfNeeded()
        }
        .onChange(of: orchestrator.outputURL) { _, newValue in
            if let url = newValue {
                BackgroundTaskManager.shared.end(success: true)
                onCompleted(url)
            }
        }
        .translationTask(translationConfig) { session in
            translationSession = session
            startPipelineIfNeeded()
        }
        .onChange(of: orchestrator.error) { _, error in
            if error != nil {
                BackgroundTaskManager.shared.end(success: false)
            }
        }
        .onChange(of: orchestrator.stageProgress) { _, _ in
            updateBackgroundProgress()
        }
        .onChange(of: keepScreenAwake) { _, newValue in
            UIApplication.shared.isIdleTimerDisabled = newValue
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private func startPipelineIfNeeded() {
        guard orchestrator.isRunning == false else { return }
        if let resumeTranscribed, didResume == false {
            if job.subtitleMode == .bilingual, translationSession == nil {
                translationConfig = TranslationSession.Configuration(
                    source: Locale.Language(identifier: job.transcriptionLocale),
                    target: Locale.Language(identifier: job.translationTargetLocale ?? "en")
                )
                return
            }
            orchestrator.resume(
                job: job,
                translationSession: translationSession,
                transcribed: resumeTranscribed,
                translated: resumeTranslated
            )
            didResume = true
            return
        }
        if job.subtitleMode == .bilingual {
            if translationConfig == nil {
                translationConfig = TranslationSession.Configuration(
                    source: Locale.Language(identifier: job.transcriptionLocale),
                    target: Locale.Language(identifier: job.translationTargetLocale ?? "en")
                )
            }
            if let session = translationSession {
                orchestrator.start(job: job, translationSession: session)
            }
        } else {
            orchestrator.start(job: job, translationSession: nil)
        }
    }

    private func restartPipeline() {
        orchestrator.start(job: job, translationSession: translationSession)
    }

    private func submitBackgroundTask() {
        let identifier = "com.huanglisen.SubStamp.processing.\(job.id.uuidString)"
        backgroundTaskIdentifier = identifier
        BackgroundTaskManager.shared.register(identifier: identifier) { _ in }
        try? BackgroundTaskManager.shared.submit(identifier: identifier, title: "SubStamp processing", subtitle: "Starting…")
        updateBackgroundProgress()
    }

    private func updateBackgroundProgress() {
        guard backgroundTaskIdentifier != nil else { return }
        let stages: [ProcessingStage] = [.assets, .transcribing, .translating, .rendering, .exporting]
        let total = stages.reduce(0.0) { $0 + (orchestrator.stageProgress[$1] ?? 0) }
        let overall = total / Double(stages.count)
        BackgroundTaskManager.shared.updateProgress(fraction: overall, subtitle: "Processing \(Int(overall * 100))%")
    }
}
