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

    @State private var config1: TranslationSession.Configuration?
    @State private var config2: TranslationSession.Configuration?
    @State private var config3: TranslationSession.Configuration?
    
    @State private var session1: TranslationSession?
    @State private var session2: TranslationSession?
    @State private var session3: TranslationSession?
    
    @State private var showCancelDialog = false
    @State private var didResume = false
    @State private var keepScreenAwake = false
    @State private var showBackDialog = false

    var body: some View {
        ScrollView {
            VStack(spacing: AppSpacing.l) {
                HStack {
                    Button { showBackDialog = true } label: {
                        Label("Back", systemImage: "chevron.left")
                            .font(AppTypography.bodyEmphasis)
                            .foregroundStyle(AppColors.secondaryText)
                    }
                    Spacer()
                }
                WizardHeaderView(step: 3, total: 4, title: "Processing", subtitle: "We'll continue even if the screen locks.")
                stageList
                tipsCard
                actionSection
            }
            .padding(AppSpacing.l)
        }
        .background(AppColors.background)
        .confirmationDialog("Cancel processing?", isPresented: $showCancelDialog) {
            Button("Stop", role: .destructive) { orchestrator.cancel(); onChangeSettings() }
        }
        .confirmationDialog("Go back?", isPresented: $showBackDialog) {
            Button("Stop and go back", role: .destructive) { orchestrator.cancel(); onBack() }
        }
        .onAppear { startPipelineIfNeeded() }
        .onChange(of: orchestrator.outputURL) { _, newValue in
            if let url = newValue { BackgroundTaskManager.shared.end(success: true); onCompleted(url) }
        }
        .translationTask(config1) { session1 = $0; orchestrator.updateTranslationSessions(s1: session1, s2: session2, s3: session3); startPipelineIfNeeded() }
        .translationTask(config2) { session2 = $0; orchestrator.updateTranslationSessions(s1: session1, s2: session2, s3: session3); startPipelineIfNeeded() }
        .translationTask(config3) { session3 = $0; orchestrator.updateTranslationSessions(s1: session1, s2: session2, s3: session3); startPipelineIfNeeded() }
        .onReceive(orchestrator.$error) { if $0 != nil { BackgroundTaskManager.shared.end(success: false) } }
        .onChange(of: orchestrator.stageProgress) { _, _ in updateBackgroundProgress() }
        .onChange(of: keepScreenAwake) { _, newValue in UIApplication.shared.isIdleTimerDisabled = newValue }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private var stageList: some View {
        VStack(spacing: AppSpacing.l) {
            stageRow(title: "Speech assets", stage: .assets, detail: "Ensuring models are ready.")
            stageRow(title: "Transcribing", stage: .transcribing, detail: "Generating time-coded subtitles.")
            stageRow(title: "Translating", stage: .translating, detail: job.subtitleMode == .bilingual ? "Bilingual translation." : "Single track translation.")
            stageRow(title: "Rendering", stage: .rendering, detail: "Burning subtitles into video.", showReviewButton: orchestrator.readyForReview)
            stageRow(title: "Exporting", stage: .exporting, detail: "Writing output file.")
        }
    }

    private func stageRow(title: String, stage: ProcessingStage, detail: String, showReviewButton: Bool = false) -> some View {
        HStack {
            PipelineStageRow(title: title, state: orchestrator.stageStates[stage] ?? .pending, progress: orchestrator.stageProgress[stage] ?? 0, detail: detail)
            if showReviewButton, let onReview {
                Button { onReview() } label: {
                    Text("Review").font(AppTypography.caption).foregroundStyle(AppColors.accent).padding(.horizontal, 8).padding(.vertical, 4).background(AppColors.accent.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    private var tipsCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            Text("Tips").font(AppTypography.bodyEmphasis)
            Text("iOS may stop work in the background. Keep the screen awake for fastest processing.").font(AppTypography.caption).foregroundStyle(AppColors.secondaryText)
            Toggle("Keep screen awake", isOn: $keepScreenAwake).font(AppTypography.caption)
        }
        .padding().background(AppColors.cardBackground).clipShape(RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius)).overlay(RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius).stroke(AppColors.cardBorder, lineWidth: 1))
    }

    @ViewBuilder
    private var actionSection: some View {
        if let error = orchestrator.error {
            VStack(alignment: .leading) {
                Text(error.errorDescription ?? "Failed").font(AppTypography.bodyEmphasis).foregroundStyle(AppColors.error)
                HStack {
                    PrimaryButton(title: "Retry", systemImage: "arrow.clockwise") { restartPipeline() }
                    PrimaryButton(title: "Change settings", systemImage: "slider.horizontal.3") { onChangeSettings() }
                }
            }
        } else {
            HStack {
                PrimaryButton(title: "Cancel", systemImage: "xmark.circle") { showCancelDialog = true }
                PrimaryButton(title: "Background", systemImage: "moon.stars") { submitBackgroundTask() }
            }
        }
    }

    private func startPipelineIfNeeded() {
        guard !orchestrator.isRunning else { return }

        let base = Locale.Language(identifier: job.transcriptionLocale)
        let english = Locale.Language(identifier: "en-US")
        let t1 = Locale.Language(identifier: job.language1Locale)
        let t2 = job.translationTargetLocale != nil ? Locale.Language(identifier: job.translationTargetLocale!) : nil

        var needsS1 = false
        var needsS2 = false
        var needsS3 = false

        // Config 1: Common Pivot (A->E)
        if job.subtitle1Mode == .pivot || job.subtitle2Mode == .pivot {
            if config1 == nil { config1 = .init(source: base, target: english) }
            if session1 == nil { needsS1 = true }
        }

        // Config 2: Sub 1 Final Leg
        if job.language1Locale != job.transcriptionLocale {
            if job.subtitle1Mode == .pivot {
                if config2 == nil { config2 = .init(source: english, target: t1) }
            } else {
                if config2 == nil { config2 = .init(source: base, target: t1) }
            }
            if session2 == nil { needsS2 = true }
        }

        // Config 3: Sub 2 Final Leg
        if let target2 = t2, job.translationTargetLocale != job.transcriptionLocale {
            if job.subtitle2Mode == .pivot {
                if config3 == nil { config3 = .init(source: english, target: target2) }
            } else {
                if config3 == nil { config3 = .init(source: base, target: target2) }
            }
            if session3 == nil { needsS3 = true }
        }

        if job.translationProvider == .appleIntelligence {
            // Still prepare TranslationSession configs so we can fall back to the Translation framework if Apple Intelligence refuses.
            orchestrator.updateTranslationSessions(s1: session1, s2: session2, s3: session3)
            if let transcribed = resumeTranscribed, !didResume {
                orchestrator.resume(job: job, s1: session1, s2: session2, s3: session3, transcribed: transcribed, translated: resumeTranslated)
                didResume = true
            } else {
                orchestrator.start(job: job, translationSession1: session1, translationSession2: session2, translationSession3: session3)
            }
            return
        }

        if (needsS1 && session1 == nil) || (needsS2 && session2 == nil) || (needsS3 && session3 == nil) { return }

        if let transcribed = resumeTranscribed, !didResume {
            orchestrator.resume(job: job, s1: session1, s2: session2, s3: session3, transcribed: transcribed, translated: resumeTranslated)
            didResume = true
        } else {
            orchestrator.start(job: job, translationSession1: session1, translationSession2: session2, translationSession3: session3)
        }
    }

    private func restartPipeline() {
        orchestrator.start(job: job, translationSession1: session1, translationSession2: session2, translationSession3: session3)
    }

    private func submitBackgroundTask() {
        let id = "com.huanglisen.SubStamp.processing.\(job.id.uuidString)"
        BackgroundTaskManager.shared.register(identifier: id) { _ in }
        try? BackgroundTaskManager.shared.submit(identifier: id, title: "SubStamp processing", subtitle: "Working…")
        updateBackgroundProgress()
    }

    private func updateBackgroundProgress() {
        let stages: [ProcessingStage] = [.assets, .transcribing, .translating, .rendering, .exporting]
        let total = stages.reduce(0.0) { $0 + (orchestrator.stageProgress[$1] ?? 0) }
        let overall = total / Double(stages.count)
        BackgroundTaskManager.shared.updateProgress(fraction: overall, subtitle: "\(Int(overall * 100))%")
    }
}
