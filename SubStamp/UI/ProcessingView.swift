import Combine
import SwiftUI
import Translation
import UIKit

struct ProcessingView: View {
    @ObservedObject var orchestrator: PipelineOrchestrator
    let job: JobModel
    var resumeTranscribed: [SubtitleCue]? = nil
    var resumeTranslated: [SubtitleCue]? = nil
    var onBack: () -> Void
    var onChangeSettings: () -> Void
    var onCompleted: (URL) -> Void
    var onReview: (() -> Void)? = nil

    @State private var translationConfig1: TranslationSession.Configuration?
    @State private var translationConfig2: TranslationSession.Configuration?
    @State private var translationSession1: TranslationSession?
    @State private var translationSession2: TranslationSession?
    @State private var showCancelDialog = false
    @State private var backgroundTaskIdentifier: String?
    @State private var didResume = false
    @State private var keepScreenAwake = false
    @State private var showBackDialog = false

    var body: some View {
        ScrollView {
            VStack(spacing: AppSpacing.l) {
                HStack {
                    Button {
                        showBackDialog = true
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                            .font(AppTypography.bodyEmphasis)
                            .foregroundStyle(AppColors.secondaryText)
                    }
                    Spacer()
                }
                WizardHeaderView(
                    step: 3,
                    total: 4,
                    title: "Processing",
                    subtitle: "We'll continue even if the screen locks."
                )

                stageList
                tipsCard
                actionSection
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
        .confirmationDialog("Go back to previous step?", isPresented: $showBackDialog) {
            Button("Stop processing and go back", role: .destructive) {
                orchestrator.cancel()
                BackgroundTaskManager.shared.end(success: false)
                onBack()
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
        .translationTask(translationConfig1) { session in
            translationSession1 = session
            startPipelineIfNeeded()
        }
        .translationTask(translationConfig2) { session in
            translationSession2 = session
            startPipelineIfNeeded()
        }
        .onReceive(orchestrator.$error) { error in
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

    private var stageList: some View {
        VStack(spacing: AppSpacing.l) {
            stageRow(
                title: "Speech assets",
                stage: .assets,
                detail: "Ensuring required models are ready."
            )
            stageRow(
                title: "Transcribing",
                stage: .transcribing,
                detail: "Generating time-coded subtitles."
            )
            stageRow(
                title: "Translating",
                stage: .translating,
                detail: job.subtitleMode == .bilingual ? "Translating each cue." : "Skipped for transcript-only mode."
            )
            stageRow(
                title: "Rendering",
                stage: .rendering,
                detail: "Burning subtitles into the video.",
                showReviewButton: orchestrator.readyForReview
            )
            stageRow(
                title: "Exporting",
                stage: .exporting,
                detail: "Writing the new file."
            )
        }
    }

    private func stageRow(title: String, stage: ProcessingStage, detail: String, showReviewButton: Bool = false) -> some View {
        HStack {
            PipelineStageRow(
                title: title,
                state: orchestrator.stageStates[stage] ?? .pending,
                progress: orchestrator.stageProgress[stage] ?? 0,
                detail: detail
            )
            if showReviewButton, let onReview {
                Button {
                    onReview()
                } label: {
                    Text("Review")
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.accent)
                        .padding(.horizontal, AppSpacing.s)
                        .padding(.vertical, 4)
                        .background(AppColors.accent.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    private var tipsCard: some View {
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
    }

    @ViewBuilder
    private var actionSection: some View {
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

    private func startPipelineIfNeeded() {
        guard orchestrator.isRunning == false else { return }
        
        // Determine what translations are needed
        let baseLocale = job.transcriptionLocale
        let lang1NeedsTranslation = job.language1Locale != baseLocale
        let lang2NeedsTranslation = job.subtitleMode == .bilingual && (job.translationTargetLocale != nil && job.translationTargetLocale != baseLocale)
        
        if let resumeTranscribed, didResume == false {
            // Resume case - configure sessions if needed
            if job.subtitleMode == .bilingual {
                // For bilingual resume, we may need up to 2 sessions
                var needsSession1 = false
                var needsSession2 = false
                
                if lang1NeedsTranslation && translationSession1 == nil {
                    translationConfig1 = TranslationSession.Configuration(
                        source: Locale.Language(identifier: baseLocale),
                        target: Locale.Language(identifier: job.language1Locale)
                    )
                    needsSession1 = true
                }
                if lang2NeedsTranslation && translationSession2 == nil {
                    translationConfig2 = TranslationSession.Configuration(
                        source: Locale.Language(identifier: baseLocale),
                        target: Locale.Language(identifier: job.translationTargetLocale!)
                    )
                    needsSession2 = true
                }
                
                // Wait for sessions to be ready
                if needsSession1 && translationSession1 == nil { return }
                if needsSession2 && translationSession2 == nil { return }
                
                orchestrator.resume(
                    job: job,
                    translationSession1: translationSession1,
                    translationSession2: translationSession2,
                    transcribed: resumeTranscribed,
                    translated: resumeTranslated
                )
            } else if lang1NeedsTranslation && translationSession1 == nil {
                translationConfig1 = TranslationSession.Configuration(
                    source: Locale.Language(identifier: baseLocale),
                    target: Locale.Language(identifier: job.language1Locale)
                )
                return
            } else {
                orchestrator.resume(
                    job: job,
                    translationSession1: translationSession1,
                    translationSession2: nil,
                    transcribed: resumeTranscribed,
                    translated: resumeTranslated
                )
            }
            didResume = true
            return
        }
        
        // Fresh start case
        if job.subtitleMode == .bilingual {
            // Bilingual mode - may need up to 2 sessions
            var needsSession1 = false
            var needsSession2 = false
            
            if lang1NeedsTranslation {
                if translationConfig1 == nil {
                    translationConfig1 = TranslationSession.Configuration(
                        source: Locale.Language(identifier: baseLocale),
                        target: Locale.Language(identifier: job.language1Locale)
                    )
                }
                if translationSession1 == nil {
                    needsSession1 = true
                }
            }
            
            if lang2NeedsTranslation {
                if translationConfig2 == nil {
                    translationConfig2 = TranslationSession.Configuration(
                        source: Locale.Language(identifier: baseLocale),
                        target: Locale.Language(identifier: job.translationTargetLocale!)
                    )
                }
                if translationSession2 == nil {
                    needsSession2 = true
                }
            }
            
            // Wait for sessions to be ready
            if lang1NeedsTranslation && translationSession1 == nil { return }
            if lang2NeedsTranslation && translationSession2 == nil { return }
            
            orchestrator.start(
                job: job,
                translationSession1: translationSession1,
                translationSession2: translationSession2
            )
        } else if lang1NeedsTranslation {
            // Single mode with translation needed
            if translationConfig1 == nil {
                translationConfig1 = TranslationSession.Configuration(
                    source: Locale.Language(identifier: baseLocale),
                    target: Locale.Language(identifier: job.language1Locale)
                )
            }
            if let session = translationSession1 {
                orchestrator.start(
                    job: job,
                    translationSession1: session,
                    translationSession2: nil
                )
            }
        } else {
            // No translation needed
            orchestrator.start(
                job: job,
                translationSession1: nil,
                translationSession2: nil
            )
        }
    }

    private func restartPipeline() {
        orchestrator.start(
            job: job,
            translationSession1: translationSession1,
            translationSession2: translationSession2
        )
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
