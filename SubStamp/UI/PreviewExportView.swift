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
    @State private var playbackTimeSeconds: Double = 0
    @State private var cueTimingIndex: [CueTiming] = []
    @State private var cueStartSeconds: [Double] = []
    @State private var cueIndexByID: [UUID: Int] = [:]
    @State private var activeCueID: UUID?
    @State private var timeObserverToken: Any?
    @FocusState private var isTextFieldFocused: Bool
    @State private var showCopyConfirmation = false

    // Stale translation detection
    @State private var translationSnapshot: [UUID: String] = [:]
    @State private var translationsAreStale = false
    @State private var staleCueIDs: Set<UUID> = []  // Per-cue stale tracking
    @State private var retranslatingCueIDs: Set<UUID> = []  // Currently retranslating
    // Track whether cues changed since last export (for "Next" vs "Export" button)
    @State private var cuesChangedSinceExport = false
    @State private var scrollTrigger: Int = 0  // Increment to trigger scroll

    @Environment(\.locale) private var locale

    private let jobStore = JobStore()

    private var job: JobModel? { activeJob }

    private struct CueTiming: Sendable {
        let id: UUID
        let startSeconds: Double
        let endSeconds: Double
    }

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
            return orchestrator.translationComplete
        }
        return true
    }

    /// Whether the Translate button should be visible (only before first translation)
    private var showTranslateButton: Bool {
        guard needsTranslation, !orchestrator.isRunning else { return false }
        // After translation completes, only show per-cue retranslate buttons (not the global button)
        return !orchestrator.translationComplete
    }

    /// Whether we have a valid previous export (came back from Step 4 with no changes)
    private var hasValidExport: Bool {
        orchestrator.outputURL != nil && !cuesChangedSinceExport
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    VideoPlayer(player: player)

                    if let cue = currentOverlayCue {
                        VideoSubtitleOverlayView(
                            primaryText: cue.primaryText,
                            secondaryText: (job?.subtitleMode == .bilingual) ? cue.secondaryText : nil,
                            style: job?.subtitleStyle ?? SubtitleStyle()
                        )
                    }
                }
                .frame(height: 220)
                .background(Color.black)

                ScrollViewReader { scrollProxy in
                    ScrollView {
                        VStack(spacing: AppSpacing.l) {
                            HStack {
                                Button { onBack() } label: {
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

                            styleCard

                            // Hint for editing before translation
                            if needsTranslation && !orchestrator.translationComplete {
                                Text(String(localized: "You can review and edit the transcription below before translating. This is optional.", bundle: .forLocale(locale)))
                                    .font(AppTypography.caption)
                                    .foregroundStyle(AppColors.secondaryText)
                            }

                            cueList

                            // Translation progress + translate button
                            translationProgressSection
                            translateButtonSection

                            // Export / render progress / Next button
                            exportSection

                            // Scroll anchor
                            Color.clear.frame(height: 1).id("bottomAnchor")
                        }
                        .padding(AppSpacing.l)
                    }
                    .onChange(of: orchestrator.currentStage) { _, newValue in
                        if newValue == .translating || newValue == .rendering || newValue == .exporting {
                            // Small delay to let SwiftUI render the progress section first
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                withAnimation { scrollProxy.scrollTo("bottomAnchor", anchor: .bottom) }
                            }
                        }
                    }
                    .onChange(of: orchestrator.isRunning) { _, isRunning in
                        // Additional trigger for rendering/exporting since it depends on isRunning + stage
                        if isRunning && (orchestrator.currentStage == .rendering || orchestrator.currentStage == .exporting) {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                withAnimation { scrollProxy.scrollTo("bottomAnchor", anchor: .bottom) }
                            }
                        }
                    }
                    .onChange(of: scrollTrigger) { _, _ in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            withAnimation { scrollProxy.scrollTo("bottomAnchor", anchor: .bottom) }
                        }
                    }
                }
            }
            .ignoresSafeArea(.all, edges: .top)
            .toolbar(.hidden, for: .navigationBar)
            .scrollDismissesKeyboard(.interactively)
            .onTapGesture { isTextFieldFocused = false }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(String(localized: "Done", bundle: .forLocale(locale))) { isTextFieldFocused = false }
                }
            }
        }
        .onAppear {
            player = AVPlayer(url: videoURL)
            if let player {
                installTimeObserver(for: player)
            }
            rebuildCueTimingIndex()
            updateActiveCue(at: playbackTimeSeconds)
            prepareTranslationConfigs()
            // Re-snapshot translations if returning with completed translation (e.g. from Step 4)
            if orchestrator.translationComplete {
                snapshotTranslations()
            }
        }
        .onDisappear {
            removeTimeObserver()
            player?.pause()
            player = nil
            session1 = nil; session2 = nil; session3 = nil
        }
        .onChange(of: orchestrator.cues.count) { _, _ in
            rebuildCueTimingIndex()
            updateActiveCue(at: playbackTimeSeconds)
        }
        .onChange(of: orchestrator.outputURL) { _, newValue in
            if let url = newValue { onExportComplete(url) }
        }
        .onChange(of: orchestrator.translationComplete) { _, complete in
            if complete {
                scrollTrigger += 1
            }
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
        .alert(Text(String(localized: "Copied", bundle: .forLocale(locale))), isPresented: $showCopyConfirmation) {
            Button(String(localized: "OK", bundle: .forLocale(locale)), role: .cancel) {}
        } message: {
            Text(String(localized: "Copied as SRT to your clipboard.", bundle: .forLocale(locale)))
        }
    }

    private var currentOverlayCue: SubtitleCue? {
        guard let activeCueID else { return nil }
        if let index = cueIndexByID[activeCueID], orchestrator.cues.indices.contains(index) {
            let cue = orchestrator.cues[index]
            if cue.id == activeCueID {
                return cue
            }
        }
        return orchestrator.cues.first { $0.id == activeCueID }
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
                    Text(String(localized: "Original transcription was edited. You can re-translate or export directly.", bundle: .forLocale(locale)))
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
                cuesChangedSinceExport = true
            }
        )

        return VStack(alignment: .leading, spacing: AppSpacing.s) {
            Text(String(localized: "Subtitle style", bundle: .forLocale(locale)))
                .font(AppTypography.bodyEmphasis)
            Picker(String(localized: "Font size", bundle: .forLocale(locale)), selection: styleBinding.fontSize) {
                Label(String(localized: "Small", bundle: .forLocale(locale)), systemImage: "textformat.size.smaller").tag(SubtitleFontSize.small)
                Label(String(localized: "Medium", bundle: .forLocale(locale)), systemImage: "textformat.size").tag(SubtitleFontSize.medium)
                Label(String(localized: "Large", bundle: .forLocale(locale)), systemImage: "textformat.size.larger").tag(SubtitleFontSize.large)
            }
            .pickerStyle(.segmented)
            Toggle(isOn: styleBinding.usesShadow) {
                Label(String(localized: "Text shadow", bundle: .forLocale(locale)), systemImage: "square.3.layers.3d.down.right")
            }
            Picker(String(localized: "Position", bundle: .forLocale(locale)), selection: styleBinding.position) {
                Label(String(localized: "Top", bundle: .forLocale(locale)), systemImage: "align.vertical.top").tag(SubtitlePosition.top)
                Label(String(localized: "Middle", bundle: .forLocale(locale)), systemImage: "align.vertical.center").tag(SubtitlePosition.middle)
                Label(String(localized: "Bottom", bundle: .forLocale(locale)), systemImage: "align.vertical.bottom").tag(SubtitlePosition.bottom)
            }
            .pickerStyle(.segmented)
            Button {
                copyCuesToClipboard()
                showCopyConfirmation = true
            } label: {
                Label(String(localized: "Copy subtitles", bundle: .forLocale(locale)), systemImage: "doc.on.doc")
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
        LazyVStack(spacing: AppSpacing.s) {
            ForEach(Array(orchestrator.cues.indices), id: \.self) { index in
                if orchestrator.cues.indices.contains(index) {
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
                        onOriginalEdited: { markCueStale(cueID: orchestrator.cues[index].id) },
                        onSubtitleEdited: { cuesChangedSinceExport = true },
                        showRetranslateButton: staleCueIDs.contains(orchestrator.cues[index].id),
                        isRetranslating: retranslatingCueIDs.contains(orchestrator.cues[index].id),
                        onRetranslate: { retranslateCue(at: index) }
                    )
                    .focused($isTextFieldFocused)
                }
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
                    Text(String(localized: "Tips", bundle: .forLocale(locale))).font(AppTypography.bodyEmphasis)
                    Text(String(localized: "The screen stays awake automatically during translation and export.", bundle: .forLocale(locale)))
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.secondaryText)
                }
                .padding()
                .background(AppColors.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius)
                        .stroke(AppColors.cardBorder, lineWidth: 1)
                )
            }
        } else if hasValidExport {
            // Came back from Step 4 with no changes — just go forward
            PrimaryButton(
                title: "Next",
                systemImage: "arrow.right"
            ) {
                if let url = orchestrator.outputURL {
                    onExportComplete(url)
                }
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
        staleCueIDs.removeAll()
    }

    private func retranslateCue(at index: Int) {
        guard orchestrator.cues.indices.contains(index) else { return }
        guard let job else { return }

        let cue = orchestrator.cues[index]
        let cueID = cue.id
        retranslatingCueIDs.insert(cueID)

        Task { @MainActor in
            do {
                var sourceCue = SubtitleCue(
                    id: cue.id,
                    start: cue.start,
                    end: cue.end,
                    primaryText: cue.originalTranscription ?? cue.primaryText,
                    secondaryText: nil,
                    hasTranslationError: false
                )

                let sourceLocale = Locale(identifier: job.transcriptionLocale)

                // Use Apple Intelligence if selected, otherwise use Translation Framework
                if #available(iOS 26.0, *), job.translationProvider == .appleIntelligence {
                    // Apple Intelligence with built-in fallback to Translation Framework
                    let aiService = AppleIntelligenceTranslationService()

                    // Translate subtitle 1 if needed
                    if job.language1Locale != job.transcriptionLocale {
                        let target1 = Locale.Language(identifier: job.language1Locale)
                        let result = try await aiService.translate(cues: [sourceCue], source: sourceLocale, target: target1) { _, _ in }
                        if let translated = result.first?.secondaryText, !translated.isEmpty {
                            orchestrator.cues[index].primaryText = translated
                        }
                    }

                    // Translate subtitle 2 if needed
                    if job.subtitleMode == .bilingual,
                       let targetLocale = job.translationTargetLocale,
                       targetLocale != job.transcriptionLocale {
                        let target2 = Locale.Language(identifier: targetLocale)
                        let result = try await aiService.translate(cues: [sourceCue], source: sourceLocale, target: target2) { _, _ in }
                        if let translated = result.first?.secondaryText, !translated.isEmpty {
                            orchestrator.cues[index].secondaryText = translated
                        }
                    }
                } else {
                    // Use Translation Framework with pivot support
                    let translationService = TranslationService()

                    // Pivot step: translate to English first if needed
                    if job.subtitle1Mode == .pivot || job.subtitle2Mode == .pivot {
                        if let pivotSession = session1 {
                            let pivotResult = try await translationService.translate(cues: [sourceCue], session: pivotSession) { _, _ in }
                            if let pivotText = pivotResult.first?.secondaryText, !pivotText.isEmpty {
                                sourceCue.primaryText = pivotText
                            }
                        }
                    }

                    // Translate for subtitle 1 if needed
                    if job.language1Locale != job.transcriptionLocale, let session2 = session2 {
                        let result = try await translationService.translate(cues: [sourceCue], session: session2) { _, _ in }
                        if let translated = result.first?.secondaryText, !translated.isEmpty {
                            orchestrator.cues[index].primaryText = translated
                        }
                    }

                    // Translate for subtitle 2 if needed
                    if job.subtitleMode == .bilingual,
                       let targetLocale = job.translationTargetLocale,
                       targetLocale != job.transcriptionLocale,
                       let session3 = session3 {
                        let result = try await translationService.translate(cues: [sourceCue], session: session3) { _, _ in }
                        if let translated = result.first?.secondaryText, !translated.isEmpty {
                            orchestrator.cues[index].secondaryText = translated
                        }
                    }
                }

                // Update snapshot and remove from stale set
                translationSnapshot[cueID] = orchestrator.cues[index].originalTranscription ?? orchestrator.cues[index].primaryText
                staleCueIDs.remove(cueID)
                translationsAreStale = !staleCueIDs.isEmpty
                cuesChangedSinceExport = true
            } catch {
                print("Retranslation failed for cue \(index): \(error)")
                orchestrator.cues[index].hasTranslationError = true
            }

            retranslatingCueIDs.remove(cueID)
        }
    }

    private func markCueStale(cueID: UUID) {
        cuesChangedSinceExport = true
        guard orchestrator.translationComplete, !translationSnapshot.isEmpty else { return }

        // Find the cue and check if it changed
        guard let cue = orchestrator.cues.first(where: { $0.id == cueID }) else { return }
        let current = cue.originalTranscription ?? cue.primaryText
        if let snapshotted = translationSnapshot[cueID], snapshotted != current {
            staleCueIDs.insert(cueID)
            translationsAreStale = true
        }
    }

    private func markTranslationsStale() {
        cuesChangedSinceExport = true
        guard orchestrator.translationComplete, !translationSnapshot.isEmpty else { return }
        // Check all cues and rebuild stale set
        staleCueIDs.removeAll()
        for cue in orchestrator.cues {
            let current = cue.originalTranscription ?? cue.primaryText
            if let snapshotted = translationSnapshot[cue.id], snapshotted != current {
                staleCueIDs.insert(cue.id)
            }
        }
        translationsAreStale = !staleCueIDs.isEmpty
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
        cuesChangedSinceExport = true
        if orchestrator.translationComplete { translationsAreStale = true }
        rebuildCueTimingIndex()
        updateActiveCue(at: playbackTimeSeconds)
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
        cuesChangedSinceExport = true
        if orchestrator.translationComplete { translationsAreStale = true }
        rebuildCueTimingIndex()
        updateActiveCue(at: playbackTimeSeconds)
    }

    private func shiftCue(at index: Int, by seconds: Double) {
        guard orchestrator.cues.indices.contains(index) else { return }
        orchestrator.cues[index].shift(by: seconds)
        cuesChangedSinceExport = true
        rebuildCueTimingIndex()
        updateActiveCue(at: playbackTimeSeconds)
    }

    private func previewCue(_ cue: SubtitleCue) {
        guard let player else { return }
        player.seek(to: cue.start, toleranceBefore: .zero, toleranceAfter: .zero)
        playbackTimeSeconds = cue.start.seconds
        activeCueID = cue.id
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

    private func rebuildCueTimingIndex() {
        cueIndexByID = Dictionary(uniqueKeysWithValues: orchestrator.cues.enumerated().map { ($0.element.id, $0.offset) })
        cueTimingIndex = orchestrator.cues
            .map { CueTiming(id: $0.id, startSeconds: $0.start.seconds, endSeconds: $0.end.seconds) }
            .filter { $0.endSeconds > $0.startSeconds }
            .sorted { $0.startSeconds < $1.startSeconds }
        cueStartSeconds = cueTimingIndex.map(\.startSeconds)
    }

    private func updateActiveCue(at seconds: Double) {
        guard !cueTimingIndex.isEmpty else {
            activeCueID = nil
            return
        }

        let idx = findLastCueIndex(startingBeforeOrAt: seconds)
        guard let idx else {
            activeCueID = nil
            return
        }

        let cue = cueTimingIndex[idx]
        if seconds >= cue.startSeconds, seconds <= cue.endSeconds {
            activeCueID = cue.id
        } else {
            activeCueID = nil
        }
    }

    private func findLastCueIndex(startingBeforeOrAt seconds: Double) -> Int? {
        var low = 0
        var high = cueStartSeconds.count - 1
        var result: Int?

        while low <= high {
            let mid = (low + high) / 2
            if cueStartSeconds[mid] <= seconds {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        return result
    }

    private func installTimeObserver(for player: AVPlayer) {
        removeTimeObserver()
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            playbackTimeSeconds = time.seconds
            updateActiveCue(at: time.seconds)
        }
    }

    private func removeTimeObserver() {
        guard let token = timeObserverToken else { return }
        player?.removeTimeObserver(token)
        timeObserverToken = nil
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
