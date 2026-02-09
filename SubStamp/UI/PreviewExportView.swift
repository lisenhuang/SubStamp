import AVFoundation
import AVKit
import Combine
import SwiftUI
import Translation
import UIKit

/// Step 3: Edit cues, translate, style subtitles, and export.
struct PreviewExportView: View {
    @ObservedObject var orchestrator: PipelineOrchestrator
    @Binding var activeJob: JobModel?
    let videoURL: URL
    var onBack: () -> Void
    var onExportComplete: (URL) -> Void

    // Translation session state
    @State private var config1: TranslationSession.Configuration?
    @State private var config2: TranslationSession.Configuration?
    @State private var config3: TranslationSession.Configuration?
    @State private var session1: TranslationSession?
    @State private var session2: TranslationSession?
    @State private var session3: TranslationSession?

    @State private var player: AVPlayer?
    @State private var isPlayingPreview = false
    @FocusState private var isTextFieldFocused: Bool
    @State private var showCopyConfirmation = false
    @State private var showBackDialog = false
    @State private var keepScreenAwake = false

    // Stale translation detection
    @State private var translationSnapshot: [UUID: String] = [:]
    @State private var translationsAreStale = false

    @Environment(\.locale) private var locale

    private let jobStore = JobStore()

    private var job: JobModel? { activeJob }

    // MARK: - Computed flags for cue row display

    private var sub1IsTranscript: Bool {
        guard let job else { return true }
        return job.language1Locale == job.transcriptionLocale
    }

    private var sub2IsTranscript: Bool {
        guard let job else { return false }
        if job.subtitleMode == .single { return false }
        return job.translationTargetLocale == job.transcriptionLocale
    }

    private var needsTranslation: Bool {
        guard let job else { return false }
        let lang1NeedsTranslation = job.language1Locale != job.transcriptionLocale
        let lang2NeedsTranslation = job.subtitleMode == .bilingual
            && job.translationTargetLocale != nil
            && job.translationTargetLocale != job.transcriptionLocale
        return lang1NeedsTranslation || lang2NeedsTranslation
    }

    private var showSubtitle1Translation: Bool {
        !sub1IsTranscript && orchestrator.translationComplete
    }

    private var showSubtitle2Translation: Bool {
        guard let job else { return false }
        if job.subtitleMode == .single { return false }
        return !sub2IsTranscript && orchestrator.translationComplete
    }

    private var showWillNotBurnNote: Bool {
        !sub1IsTranscript && !sub2IsTranscript
    }

    private var subtitle1Label: String {
        guard let job else { return "Subtitle 1" }
        let name = Locale.current.localizedString(forIdentifier: job.language1Locale) ?? job.language1Locale
        return "Subtitle 1 (\(name))"
    }

    private var subtitle2Label: String {
        guard let job else { return "Subtitle 2" }
        let id = job.translationTargetLocale ?? ""
        let name = Locale.current.localizedString(forIdentifier: id) ?? id
        return "Subtitle 2 (\(name))"
    }

    /// Whether the Export button should be visible
    private var canExport: Bool {
        guard !orchestrator.isRunning else { return false }
        if needsTranslation {
            return orchestrator.translationComplete && !translationsAreStale
        }
        return true
    }

    /// Whether the Translate button should be visible
    private var showTranslateButton: Bool {
        guard needsTranslation, !orchestrator.isRunning else { return false }
        return !orchestrator.translationComplete || translationsAreStale
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VideoPlayer(player: player)
                    .frame(height: 220)
                    .background(Color.black)

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

                        WizardHeaderView(
                            step: 3,
                            total: 4,
                            title: "Preview & Export",
                            subtitle: "Edit subtitles, translate, and export."
                        )

                        // Translation progress (shown inline when translating)
                        translationProgressSection

                        styleCard

                        // Hint for editing before translation
                        if needsTranslation && !orchestrator.translationComplete {
                            Text("You can review and edit the transcription below before translating. This is optional.")
                                .font(AppTypography.caption)
                                .foregroundStyle(AppColors.secondaryText)
                        }

                        cueList

                        // Export section (only when translation is done)
                        exportSection

                        // Translate / re-translate button (at bottom)
                        translateButtonSection
                    }
                    .padding(AppSpacing.l)
                }
            }
            .ignoresSafeArea(.all, edges: .top)
            .toolbar(.hidden, for: .navigationBar)
            .scrollDismissesKeyboard(.interactively)
            .onTapGesture { isTextFieldFocused = false }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { isTextFieldFocused = false }
                }
            }
        }
        .onAppear {
            player = AVPlayer(url: videoURL)
            prepareTranslationConfigs()
        }
        .onDisappear {
            player?.pause()
            player = nil
            UIApplication.shared.isIdleTimerDisabled = false
            session1 = nil; session2 = nil; session3 = nil
        }
        .onChange(of: orchestrator.outputURL) { _, newValue in
            if let url = newValue { onExportComplete(url) }
        }
        .onChange(of: keepScreenAwake) { _, newValue in
            UIApplication.shared.isIdleTimerDisabled = newValue
        }
        .translationTask(config1) { session in
            session1 = session
            orchestrator.updateTranslationSessions(s1: session1, s2: session2, s3: session3)
        }
        .translationTask(config2) { session in
            session2 = session
            orchestrator.updateTranslationSessions(s1: session1, s2: session2, s3: session3)
        }
        .translationTask(config3) { session in
            session3 = session
            orchestrator.updateTranslationSessions(s1: session1, s2: session2, s3: session3)
        }
        .confirmationDialog(
            Text(String(localized: "Go back?", bundle: .forLocale(locale))),
            isPresented: $showBackDialog
        ) {
            Button(String(localized: "Go back", bundle: .forLocale(locale)), role: .destructive) {
                onBack()
            }
            Button(String(localized: "Cancel", bundle: .forLocale(locale)), role: .cancel) {}
        }
        .alert(Text(String(localized: "Copied", bundle: .forLocale(locale))), isPresented: $showCopyConfirmation) {
            Button(String(localized: "OK", bundle: .forLocale(locale)), role: .cancel) {}
        } message: {
            Text(String(localized: "Copied as SRT to your clipboard.", bundle: .forLocale(locale)))
        }
    }

    // MARK: - Translation progress (inline, shown when translating)

    @ViewBuilder
    private var translationProgressSection: some View {
        if orchestrator.isRunning && orchestrator.stageStates[.translating] == .active {
            PipelineStageRow(
                title: "Translating",
                state: .active,
                progress: orchestrator.stageProgress[.translating] ?? 0,
                detail: "Translating subtitles."
            )
        }
    }

    // MARK: - Translate button (at bottom)

    @ViewBuilder
    private var translateButtonSection: some View {
        if let error = orchestrator.error, !orchestrator.isRunning {
            VStack(alignment: .leading, spacing: AppSpacing.s) {
                Text(LocalizedStringKey(error.errorDescription ?? "Translation failed"))
                    .font(AppTypography.bodyEmphasis)
                    .foregroundStyle(AppColors.error)
                PrimaryButton(title: "Retry", systemImage: "arrow.clockwise") {
                    startTranslation()
                }
            }
        } else if showTranslateButton {
            VStack(spacing: AppSpacing.s) {
                if translationsAreStale {
                    Text("Original transcription was edited. Re-translate to update.")
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.warning)
                }
                PrimaryButton(
                    title: "Translate",
                    systemImage: "globe"
                ) {
                    startTranslation()
                }
            }
        }
    }

    // MARK: - Style card

    private var styleCard: some View {
        let styleBinding = Binding<SubtitleStyle>(
            get: { activeJob?.subtitleStyle ?? SubtitleStyle() },
            set: { newValue in
                guard var updated = activeJob else { return }
                updated.subtitleStyle = newValue
                activeJob = updated
                orchestrator.job = updated
                try? jobStore.save(job: updated)
                SetupPreferences.saveSubtitleStyle(newValue)
            }
        )

        return VStack(alignment: .leading, spacing: AppSpacing.s) {
            Text("Subtitle style")
                .font(AppTypography.bodyEmphasis)
            Picker("Font size", selection: styleBinding.fontSize) {
                Label("Small", systemImage: "textformat.size.smaller").tag(SubtitleFontSize.small)
                Label("Medium", systemImage: "textformat.size").tag(SubtitleFontSize.medium)
                Label("Large", systemImage: "textformat.size.larger").tag(SubtitleFontSize.large)
            }
            .pickerStyle(.segmented)
            Toggle(isOn: styleBinding.usesShadow) {
                Label("Text shadow", systemImage: "square.3.layers.3d.down.right")
            }
            Picker("Position", selection: styleBinding.position) {
                Label("Top", systemImage: "align.vertical.top").tag(SubtitlePosition.top)
                Label("Middle", systemImage: "align.vertical.center").tag(SubtitlePosition.middle)
                Label("Bottom", systemImage: "align.vertical.bottom").tag(SubtitlePosition.bottom)
            }
            .pickerStyle(.segmented)
            Button {
                copyCuesToClipboard()
                showCopyConfirmation = true
            } label: {
                Label("Copy subtitles", systemImage: "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .font(AppTypography.caption)
        .padding()
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius)
                .stroke(AppColors.cardBorder, lineWidth: 1)
        )
    }

    // MARK: - Cue list

    private var cueList: some View {
        VStack(spacing: AppSpacing.s) {
            ForEach(Array(orchestrator.cues.indices), id: \.self) { index in
                SubtitleCueRow(
                    index: index,
                    cue: $orchestrator.cues[index],
                    onSplit: { splitCue(at: index) },
                    onMergeNext: { mergeCue(at: index) },
                    onShiftBack: { shiftCue(at: index, by: -0.1) },
                    onShiftForward: { shiftCue(at: index, by: 0.1) },
                    onPreview: { previewCue(orchestrator.cues[index]) },
                    showOriginalTranscription: true,
                    showSubtitle1Translation: showSubtitle1Translation,
                    showSubtitle2Translation: showSubtitle2Translation,
                    showWillNotBurnNote: showWillNotBurnNote,
                    subtitle1Label: subtitle1Label,
                    subtitle2Label: subtitle2Label,
                    onOriginalEdited: { markTranslationsStale() }
                )
                .focused($isTextFieldFocused)
            }
        }
        .padding()
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius)
                .stroke(AppColors.cardBorder, lineWidth: 1)
        )
    }

    // MARK: - Export section

    @ViewBuilder
    private var exportSection: some View {
        if orchestrator.isRunning && (orchestrator.stageStates[.rendering] == .active || orchestrator.stageStates[.exporting] == .active) {
            VStack(spacing: AppSpacing.l) {
                PipelineStageRow(
                    title: "Rendering",
                    state: orchestrator.stageStates[.rendering] ?? .pending,
                    progress: orchestrator.stageProgress[.rendering] ?? 0,
                    detail: "Burning subtitles into video."
                )
                PipelineStageRow(
                    title: "Exporting",
                    state: orchestrator.stageStates[.exporting] ?? .pending,
                    progress: orchestrator.stageProgress[.exporting] ?? 0,
                    detail: "Writing output file."
                )

                VStack(alignment: .leading, spacing: AppSpacing.s) {
                    Text("Tips").font(AppTypography.bodyEmphasis)
                    Text("Keep the screen awake for fastest processing.")
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
        } else if canExport {
            PrimaryButton(
                title: "Export Video",
                systemImage: "square.and.arrow.up"
            ) {
                startExport()
            }
        }
    }

    // MARK: - Translation config setup

    private func prepareTranslationConfigs() {
        guard let job else { return }
        let base = Locale.Language(identifier: job.transcriptionLocale)
        let english = Locale.Language(identifier: "en-US")
        let t1 = Locale.Language(identifier: job.language1Locale)
        let t2 = job.translationTargetLocale.map { Locale.Language(identifier: $0) }

        // Config 1: Common Pivot (A->E)
        if job.subtitle1Mode == .pivot || job.subtitle2Mode == .pivot {
            config1 = .init(source: base, target: english)
        }
        // Config 2: Sub 1 Final Leg
        if job.language1Locale != job.transcriptionLocale {
            config2 = job.subtitle1Mode == .pivot
                ? .init(source: english, target: t1)
                : .init(source: base, target: t1)
        }
        // Config 3: Sub 2 Final Leg
        if let target2 = t2, job.translationTargetLocale != job.transcriptionLocale {
            config3 = job.subtitle2Mode == .pivot
                ? .init(source: english, target: target2)
                : .init(source: base, target: target2)
        }
    }

    // MARK: - Actions

    private func startTranslation() {
        guard let job else { return }
        translationsAreStale = false
        orchestrator.startTranslation(
            job: job,
            translationSession1: session1,
            translationSession2: session2,
            translationSession3: session3
        )
        // After translation completes, snapshot for stale detection
        Task { @MainActor in
            // Wait for translation to finish
            for await running in orchestrator.$isRunning.values {
                if !running && orchestrator.translationComplete {
                    snapshotTranslations()
                    break
                }
            }
        }
    }

    private func startExport() {
        guard let job else { return }
        orchestrator.startRenderExport(job: job)
    }

    private func snapshotTranslations() {
        translationSnapshot = Dictionary(uniqueKeysWithValues: orchestrator.cues.map {
            ($0.id, $0.originalTranscription ?? $0.primaryText)
        })
        translationsAreStale = false
    }

    private func markTranslationsStale() {
        guard orchestrator.translationComplete, !translationSnapshot.isEmpty else { return }
        // Check if any original transcription differs from snapshot
        for cue in orchestrator.cues {
            let current = cue.originalTranscription ?? cue.primaryText
            if let snapshotted = translationSnapshot[cue.id], snapshotted != current {
                translationsAreStale = true
                return
            }
        }
        translationsAreStale = false
    }

    // MARK: - Cue editing

    private func splitCue(at index: Int) {
        guard orchestrator.cues.indices.contains(index) else { return }
        let cue = orchestrator.cues[index]
        let words = cue.primaryText.split(separator: " ")
        guard words.count > 1 else { return }
        let midpoint = words.count / 2
        let firstText = words.prefix(midpoint).joined(separator: " ")
        let secondText = words.suffix(from: midpoint).joined(separator: " ")
        let midTime = CMTime(seconds: (cue.start.seconds + cue.end.seconds) / 2, preferredTimescale: 600)
        orchestrator.cues[index] = SubtitleCue(
            id: cue.id,
            start: cue.start,
            end: midTime,
            primaryText: String(firstText),
            secondaryText: cue.secondaryText,
            originalTranscription: cue.originalTranscription,
            hasTranslationError: cue.hasTranslationError
        )
        let newCue = SubtitleCue(
            start: midTime,
            end: cue.end,
            primaryText: String(secondText),
            secondaryText: cue.secondaryText,
            originalTranscription: cue.originalTranscription,
            hasTranslationError: cue.hasTranslationError
        )
        orchestrator.cues.insert(newCue, at: index + 1)
        if orchestrator.translationComplete { translationsAreStale = true }
    }

    private func mergeCue(at index: Int) {
        guard orchestrator.cues.indices.contains(index),
              orchestrator.cues.indices.contains(index + 1) else { return }
        let current = orchestrator.cues[index]
        let next = orchestrator.cues[index + 1]
        let mergedText = [current.primaryText, next.primaryText].joined(separator: " ")
        let mergedOriginal: String? = {
            if let a = current.originalTranscription, let b = next.originalTranscription {
                return [a, b].joined(separator: " ")
            }
            return current.originalTranscription ?? next.originalTranscription
        }()
        let merged = SubtitleCue(
            id: current.id,
            start: current.start,
            end: next.end,
            primaryText: mergedText,
            secondaryText: current.secondaryText ?? next.secondaryText,
            originalTranscription: mergedOriginal,
            hasTranslationError: current.hasTranslationError || next.hasTranslationError
        )
        orchestrator.cues[index] = merged
        orchestrator.cues.remove(at: index + 1)
        if orchestrator.translationComplete { translationsAreStale = true }
    }

    private func shiftCue(at index: Int, by seconds: Double) {
        guard orchestrator.cues.indices.contains(index) else { return }
        orchestrator.cues[index].shift(by: seconds)
    }

    private func previewCue(_ cue: SubtitleCue) {
        guard let player else { return }
        player.seek(to: cue.start, toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        isPlayingPreview = true
        let durationSeconds = max(0.2, cue.end.seconds - cue.start.seconds)
        Task {
            try? await Task.sleep(nanoseconds: UInt64(durationSeconds * 1_000_000_000))
            await MainActor.run {
                player.pause()
                isPlayingPreview = false
            }
        }
    }

    private func copyCuesToClipboard() {
        let srt = orchestrator.cues.enumerated().map { index, cue in
            let start = TimeFormatting.srtTimestamp(cue.start)
            let end = TimeFormatting.srtTimestamp(cue.end)
            var lines: [String] = ["\(index + 1)", "\(start) --> \(end)", cue.primaryText]
            if let secondary = cue.secondaryText, !secondary.isEmpty {
                lines.append(secondary)
            }
            return lines.joined(separator: "\n")
        }
        .joined(separator: "\n\n")
        UIPasteboard.general.string = srt
    }
}
