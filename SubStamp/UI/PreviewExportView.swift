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
    @State private var isVideoFullScreen = false
    @FocusState private var isTextFieldFocused: Bool
    @State private var clipboardAlert: ClipboardAlert?
    @State private var didCopyManualPrompt = false
    @State private var copyManualPromptFeedbackNonce = 0
    @State private var manualTranslationTrack: ManualTranslationTrack = .subtitle2
    @State private var lastManualPromptContext: ManualPromptContext?
    @State private var isManualToolsExpanded: Bool = false

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

    private struct ClipboardAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    private enum ManualTranslationTrack: String, CaseIterable, Identifiable {
        case subtitle1
        case subtitle2

        var id: String { rawValue }
    }

    private struct ManualPromptContext: Equatable {
        let track: ManualTranslationTrack
        let target: String
        let cueNumbers: Set<Int>  // 1-based cue numbers (index + 1)
    }

    private struct ManualFixTranslateInput: Encodable {
        struct Cue: Encodable {
            let n: Int
            let text: String  // current (possibly edited) transcription
        }

        let source: String
        let target: String
        let cues: [Cue]
    }

    private struct ManualFixTranslateOutput: Decodable {
        struct Cue: Decodable {
            let n: Int
            let fixed: String?
            let text: String?
        }

        let source: String?
        let target: String
        let cues: [Cue]
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

    private var manualTranslationTracks: [ManualTranslationTrack] {
        guard let job else { return [] }
        var tracks: [ManualTranslationTrack] = []
        if job.language1Locale != job.transcriptionLocale {
            tracks.append(.subtitle1)
        }
        if job.subtitleMode == .bilingual,
           let t2 = job.translationTargetLocale,
           t2 != job.transcriptionLocale {
            tracks.append(.subtitle2)
        }
        return tracks
    }

    private var shouldShowManualTranslationTools: Bool {
        !manualTranslationTracks.isEmpty && !orchestrator.isRunning
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
                ZStack(alignment: .bottomTrailing) {
                    VideoPlayer(player: player)

                    if let cue = currentOverlayCue {
                        VideoSubtitleOverlayView(
                            primaryText: cue.primaryText,
                            secondaryText: (job?.subtitleMode == .bilingual) ? cue.secondaryText : nil,
                            style: job?.subtitleStyle ?? SubtitleStyle()
                        )
                    }

                    if player != nil {
                        Button {
                            isVideoFullScreen = true
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right.circle.fill")
                                .font(.title)
                                .foregroundStyle(.white)
                                .padding(AppSpacing.s)
                                .background(Color.black.opacity(0.5))
                                .clipShape(Circle())
                        }
                        .padding(AppSpacing.m)
                        .accessibilityLabel(Text("Full screen"))
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

                            // Hint for editing before translation
                            if needsTranslation && !orchestrator.translationComplete {
                                Text(String(localized: "You can review and edit the transcription below before translating. This is optional.", bundle: .forLocale(locale)))
                                    .font(AppTypography.caption)
                                    .foregroundStyle(AppColors.secondaryText)
                            }

                            cueList

                            // Subtitle style should be adjustable before the user translates.
                            styleCard

                            // Translation progress + translate button
                            translationProgressSection
                            translateButtonSection

                            manualFixTranslateCard

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
        .fullScreenCover(isPresented: $isVideoFullScreen) {
            ZStack(alignment: .topLeading) {
                ZStack {
                    if let player {
                        VideoPlayer(player: player)
                            .ignoresSafeArea()
                    } else {
                        Color.black.ignoresSafeArea()
                    }

                    if let cue = currentOverlayCue {
                        VideoSubtitleOverlayView(
                            primaryText: cue.primaryText,
                            secondaryText: (job?.subtitleMode == .bilingual) ? cue.secondaryText : nil,
                            style: job?.subtitleStyle ?? SubtitleStyle()
                        )
                    }
                }

                Button {
                    isVideoFullScreen = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.white)
                        .padding()
                        .shadow(radius: 4)
                }
                .accessibilityLabel(Text("Close"))
            }
            .background(Color.black)
        }
        .onAppear {
            player = AVPlayer(url: videoURL)
            if let player {
                installTimeObserver(for: player)
            }
            rebuildCueTimingIndex()
            updateActiveCue(at: playbackTimeSeconds)
            prepareTranslationConfigs()
            if let first = manualTranslationTracks.first {
                manualTranslationTrack = first
            }
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
        .alert(item: $clipboardAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text(String(localized: "OK", bundle: .forLocale(locale))))
            )
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

    // MARK: - Manual fix & translate card

    @ViewBuilder
    private var manualFixTranslateCard: some View {
        if shouldShowManualTranslationTools {
            VStack(alignment: .leading, spacing: AppSpacing.s) {
                DisclosureGroup(isExpanded: $isManualToolsExpanded) {
                    VStack(alignment: .leading, spacing: AppSpacing.s) {
                        if manualTranslationTracks.count > 1 {
                            Picker(String(localized: "Target subtitle", bundle: .forLocale(locale)), selection: $manualTranslationTrack) {
                                ForEach(manualTranslationTracks) { track in
                                    Text(manualTrackDisplayName(track))
                                        .tag(track)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

                        HStack(spacing: AppSpacing.s) {
                            Button {
                                copyManualTranslationPromptToClipboard()
                            } label: {
                                Group {
                                    if didCopyManualPrompt {
                                        Text("✅ Copied")
                                    } else {
                                        Label(String(localized: "Copy prompt", bundle: .forLocale(locale)), systemImage: "doc.on.doc")
                                    }
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)

                            Button {
                                pasteManualTranslationFromClipboard()
                            } label: {
                                Label(String(localized: "Paste subtitle", bundle: .forLocale(locale)), systemImage: "clipboard")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }

                        Text(String(localized: "Copy a prompt, fix and translate with any AI, then paste the JSON result back here. The app will validate the format before applying it.", bundle: .forLocale(locale)))
                            .font(AppTypography.caption)
                            .foregroundStyle(AppColors.secondaryText)
                    }
                    .padding(.top, AppSpacing.xs)
                } label: {
                    Text(String(localized: "Manual fix & translate", bundle: .forLocale(locale)))
                        .font(AppTypography.bodyEmphasis)
                }
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

    // MARK: - Manual fix + translate (copy prompt / paste result)

    private func manualTrackDisplayName(_ track: ManualTranslationTrack) -> String {
        switch track {
        case .subtitle1:
            return subtitle1Label
        case .subtitle2:
            return subtitle2Label
        }
    }

    private func copyManualTranslationPromptToClipboard() {
        guard let job else { return }

        guard manualTranslationTracks.contains(manualTranslationTrack) else {
            if let first = manualTranslationTracks.first {
                manualTranslationTrack = first
            }
            clipboardAlert = ClipboardAlert(
                title: String(localized: "Unavailable", bundle: .forLocale(locale)),
                message: String(localized: "This subtitle track doesn't need translation for the current setup.", bundle: .forLocale(locale))
            )
            return
        }

        let targetID = manualTargetLocaleID(for: job, track: manualTranslationTrack)
        guard !targetID.isEmpty else {
            clipboardAlert = ClipboardAlert(
                title: String(localized: "Unavailable", bundle: .forLocale(locale)),
                message: String(localized: "No target language is set for this subtitle track.", bundle: .forLocale(locale))
            )
            return
        }

        let sourceID = job.transcriptionLocale
        guard !sourceID.isEmpty else {
            clipboardAlert = ClipboardAlert(
                title: String(localized: "Unavailable", bundle: .forLocale(locale)),
                message: String(localized: "No source language is set for transcription.", bundle: .forLocale(locale))
            )
            return
        }

        // For manual translation, include the full (possibly edited) transcription so external AIs can use global context.
        // If the AI can't output everything in one response, it can return subsets and the user can paste multiple times.
        let selection = makeManualTranslationSelection(
            track: manualTranslationTrack,
            maxCues: orchestrator.cues.count,
            maxCharacters: 2_000_000,
            includeAlreadyTranslated: true
        )
        guard !selection.inputs.isEmpty else {
            clipboardAlert = ClipboardAlert(
                title: String(localized: "Nothing to translate", bundle: .forLocale(locale)),
                message: String(localized: "No subtitles found to translate.", bundle: .forLocale(locale))
            )
            return
        }

        let payload = ManualFixTranslateInput(
            source: sourceID,
            target: targetID,
            cues: selection.inputs.map { ManualFixTranslateInput.Cue(n: $0.n, text: $0.text) }
        )

        let payloadJSON: String
        do {
            let encoder = JSONEncoder()
            // Keep JSON compact to reduce prompt size for long transcripts.
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(payload)
            payloadJSON = String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            clipboardAlert = ClipboardAlert(
                title: String(localized: "Failed", bundle: .forLocale(locale)),
                message: String(localized: "Could not generate prompt JSON.", bundle: .forLocale(locale))
            )
            return
        }

        let sourceName = Locale.current.localizedString(forIdentifier: sourceID) ?? sourceID
        let targetName = Locale.current.localizedString(forIdentifier: targetID) ?? targetID
        let beforeBlock = formatContextBlock(label: "Context before (reference only)", lines: selection.contextBefore)
        let afterBlock = formatContextBlock(label: "Context after (reference only)", lines: selection.contextAfter)

        let prompt = """
        You are a professional subtitle editor and translator.
        The input is a speech-to-text transcription from a video. It may contain mistakes (wrong words, names, punctuation).
        Read the entire INPUT_JSON first (all cues), then produce the output.
        Your tasks for each cue:
        1) Fix the transcription in \(sourceName) (\(sourceID)) with MINIMAL changes. Do not rewrite whole sentences.
        2) Translate the FIXED transcription into \(targetName) (\(targetID)).
        Use context for natural phrasing, but keep every cue aligned. Do not move content between cues.
        You may use internet search to verify names, places, and terms when helpful.

        Rules:
        - Do NOT add, remove, merge, split, or reorder cues.
        - Keep each cue aligned by its cue number `n`.
        - Output ONLY valid JSON (no markdown, no commentary).
        - Output must start with { and end with } and be valid JSON.
        - Use ASCII double quotes U+0022 (") only. Never use smart quotes (“ ” ‘ ’) or fullwidth quotes (＂).
        - Copy the `source` and `target` values EXACTLY as provided in INPUT_JSON.
        - If the output is too long, translate in parts: return a complete JSON with a subset of cues (e.g. n=1..200), then continue with the next subset in a new JSON.
        - For empty cue text, output an empty string.
        - Preserve line breaks using \\n when needed.
        - In OUTPUT_JSON, `fixed` must be in the SOURCE language and `text` must be in the TARGET language.
        - Only include `fixed` for cues that actually need a correction. If a cue needs no correction, omit `fixed` for that cue.

        Output JSON schema (keys must match exactly):
        {
          "source": "\(sourceID)",
          "target": "\(targetID)",
          "cues": [
            { "n": 1, "text": "...", "fixed": "..." }
          ]
        }

        \(beforeBlock)\(afterBlock)

        INPUT_JSON:
        \(payloadJSON)
        """

        UIPasteboard.general.string = prompt

        lastManualPromptContext = ManualPromptContext(
            track: manualTranslationTrack,
            target: normalizeLocaleIdentifier(targetID),
            cueNumbers: Set(selection.inputs.map(\.n))
        )

        showCopiedManualPromptFeedback()
    }

    private func showCopiedManualPromptFeedback() {
        // Swap the button label for a short time instead of showing an alert.
        copyManualPromptFeedbackNonce += 1
        let nonce = copyManualPromptFeedbackNonce
        didCopyManualPrompt = true

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard copyManualPromptFeedbackNonce == nonce else { return }
            didCopyManualPrompt = false
        }
    }

    private func pasteManualTranslationFromClipboard() {
        guard let job else { return }
        guard let raw = UIPasteboard.general.string, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            clipboardAlert = ClipboardAlert(
                title: String(localized: "Paste failed", bundle: .forLocale(locale)),
                message: String(localized: "Clipboard is empty.", bundle: .forLocale(locale))
            )
            return
        }

        let wasTranslationComplete = orchestrator.translationComplete
        guard manualTranslationTracks.contains(manualTranslationTrack) else {
            clipboardAlert = ClipboardAlert(
                title: String(localized: "Unavailable", bundle: .forLocale(locale)),
                message: String(localized: "This subtitle track doesn't need translation for the current setup.", bundle: .forLocale(locale))
            )
            return
        }

        let expectedSource = normalizeLocaleIdentifier(job.transcriptionLocale)
        let expectedTarget = normalizeLocaleIdentifier(manualTargetLocaleID(for: job, track: manualTranslationTrack))
        if expectedTarget.isEmpty {
            clipboardAlert = ClipboardAlert(
                title: String(localized: "Unavailable", bundle: .forLocale(locale)),
                message: String(localized: "No target language is set for this subtitle track.", bundle: .forLocale(locale))
            )
            return
        }

        let decoded: ManualFixTranslateOutput
        do {
            decoded = try decodeJSON(ManualFixTranslateOutput.self, from: raw)
        } catch {
            let hasSmartQuotes = raw.contains("“")
                || raw.contains("”")
                || raw.contains("‘")
                || raw.contains("’")
                || raw.contains("＂")
            clipboardAlert = ClipboardAlert(
                title: String(localized: "Paste failed", bundle: .forLocale(locale)),
                message: hasSmartQuotes
                    ? String(localized: "The pasted text isn't valid JSON. Tip: use standard quotes (\") instead of smart quotes (“ ”).", bundle: .forLocale(locale))
                    : String(localized: "The pasted text isn't valid JSON. Paste only the JSON result (no markdown or extra text).", bundle: .forLocale(locale))
            )
            return
        }

        if let source = decoded.source, !source.isEmpty {
            let pastedSource = normalizeLocaleIdentifier(source)
            guard pastedSource == expectedSource else {
                clipboardAlert = ClipboardAlert(
                    title: String(localized: "Paste failed", bundle: .forLocale(locale)),
                    message: String(localized: "The pasted JSON has a different source language than your current job.", bundle: .forLocale(locale))
                )
                return
            }
        }

        let pastedTarget = normalizeLocaleIdentifier(decoded.target)
        guard pastedTarget == expectedTarget else {
            clipboardAlert = ClipboardAlert(
                title: String(localized: "Paste failed", bundle: .forLocale(locale)),
                message: String(localized: "The pasted subtitles target a different language than your current selection.", bundle: .forLocale(locale))
            )
            return
        }

        let cueNumbers = decoded.cues.map(\.n)
        let uniqueNumbers = Set(cueNumbers)
        guard uniqueNumbers.count == cueNumbers.count else {
            clipboardAlert = ClipboardAlert(
                title: String(localized: "Paste failed", bundle: .forLocale(locale)),
                message: String(localized: "Duplicate cue numbers were found in the pasted JSON.", bundle: .forLocale(locale))
            )
            return
        }

        if let last = lastManualPromptContext {
            guard last.track == manualTranslationTrack else {
                clipboardAlert = ClipboardAlert(
                    title: String(localized: "Paste failed", bundle: .forLocale(locale)),
                    message: String(localized: "The last copied prompt was for a different subtitle track. Please copy a new prompt for the current track.", bundle: .forLocale(locale))
                )
                return
            }
            guard last.target == expectedTarget else {
                clipboardAlert = ClipboardAlert(
                    title: String(localized: "Paste failed", bundle: .forLocale(locale)),
                    message: String(localized: "The last copied prompt was for a different target language. Please copy a new prompt and translate again.", bundle: .forLocale(locale))
                )
                return
            }

            let pastedSet = Set(decoded.cues.map(\.n))
            guard last.cueNumbers.isSuperset(of: pastedSet) else {
                clipboardAlert = ClipboardAlert(
                    title: String(localized: "Paste failed", bundle: .forLocale(locale)),
                    message: String(localized: "Some cue numbers in the pasted JSON don't match the last copied prompt. Please copy a new prompt and translate again.", bundle: .forLocale(locale))
                )
                return
            }
        }

        let sub1IsTranscript = job.language1Locale == job.transcriptionLocale
        let sub2IsTranscript = job.subtitleMode == .bilingual && job.translationTargetLocale == job.transcriptionLocale

        var appliedFixed = 0
        var appliedTranslation = 0
        for cue in decoded.cues {
            let index = cue.n - 1
            guard orchestrator.cues.indices.contains(index) else { continue }

            if let fixed = cue.fixed {
                let cleanedFixed = SubtitleTextCleaner.clean(fixed)
                orchestrator.cues[index].originalTranscription = cleanedFixed
                if sub1IsTranscript {
                    orchestrator.cues[index].primaryText = cleanedFixed
                }
                if sub2IsTranscript {
                    orchestrator.cues[index].secondaryText = cleanedFixed
                }
                appliedFixed += 1
            }

            if let translated = cue.text {
                let cleaned = SubtitleTextCleaner.clean(translated)
                switch manualTranslationTrack {
                case .subtitle1:
                    orchestrator.cues[index].primaryText = cleaned
                    orchestrator.cues[index].hasTranslationError = false
                case .subtitle2:
                    orchestrator.cues[index].secondaryText = cleaned
                    orchestrator.cues[index].hasTranslationError = false
                }
                appliedTranslation += 1
            }
        }

        guard appliedFixed > 0 || appliedTranslation > 0 else {
            clipboardAlert = ClipboardAlert(
                title: String(localized: "Paste failed", bundle: .forLocale(locale)),
                message: String(localized: "No subtitles were applied. Check that cue numbers are within range.", bundle: .forLocale(locale))
            )
            return
        }

        if appliedTranslation > 0 {
            orchestrator.translationComplete = true
        }
        cuesChangedSinceExport = true
        if appliedTranslation > 0 {
            snapshotTranslations()
        } else if wasTranslationComplete, appliedFixed > 0 {
            // Transcription changed without updated translations; surface stale warning.
            markTranslationsStale()
        }

        if let job = activeJob {
            try? jobStore.saveCues(orchestrator.cues, id: job.id, type: .translated)
        }

        clipboardAlert = ClipboardAlert(
            title: String(localized: "Imported", bundle: .forLocale(locale)),
            message: String(format: String(localized: "Imported %d fixes and %d translations.", bundle: .forLocale(locale)), appliedFixed, appliedTranslation)
        )
    }

    private func manualTargetLocaleID(for job: JobModel, track: ManualTranslationTrack) -> String {
        switch track {
        case .subtitle1:
            return job.language1Locale
        case .subtitle2:
            return job.translationTargetLocale ?? ""
        }
    }

    private func normalizeLocaleIdentifier(_ identifier: String) -> String {
        identifier
            .replacingOccurrences(of: "_", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func decodeJSON<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}") else {
            throw NSError(domain: "SubStamp", code: -1)
        }
        let json = String(trimmed[start...end])

        do {
            return try JSONDecoder().decode(T.self, from: Data(json.utf8))
        } catch {
            // Common failure: AI output uses smart quotes or fullwidth punctuation, which isn't valid JSON.
            let normalized = normalizeLikelyJSON(json)
            guard normalized != json else { throw error }
            return try JSONDecoder().decode(T.self, from: Data(normalized.utf8))
        }
    }

    private func normalizeLikelyJSON(_ text: String) -> String {
        // Fast path.
        if !text.contains("“"),
           !text.contains("”"),
           !text.contains("‘"),
           !text.contains("’"),
           !text.contains("＂"),
           !text.contains("："),
           !text.contains("，"),
           !text.contains("｛"),
           !text.contains("｝"),
           !text.contains("［"),
           !text.contains("］") {
            return text
        }

        let scalars = Array(text.unicodeScalars)
        var out = String()
        out.unicodeScalars.reserveCapacity(scalars.count)

        func isWhitespace(_ scalar: UnicodeScalar) -> Bool {
            CharacterSet.whitespacesAndNewlines.contains(scalar)
        }

        func prevNonWhitespaceScalar(before index: Int) -> UnicodeScalar? {
            var i = index
            while i >= 0 {
                let s = scalars[i]
                if !isWhitespace(s) { return s }
                i -= 1
            }
            return nil
        }

        func nextNonWhitespaceScalar(after index: Int) -> UnicodeScalar? {
            var i = index
            while i < scalars.count {
                let s = scalars[i]
                if !isWhitespace(s) { return s }
                i += 1
            }
            return nil
        }

        func isSmartQuote(_ scalar: UnicodeScalar) -> Bool {
            switch scalar.value {
            case 0x201C, 0x201D, 0x201E, 0x00AB, 0x00BB, 0x2039, 0x203A, 0xFF02:
                return true
            case 0x2018, 0x2019, 0x201A, 0xFF07:
                return true
            default:
                return false
            }
        }

        let openingContext: Set<UInt32> = [
            0x007B, // {
            0x005B, // [
            0x003A, // :
            0x002C, // ,
            0xFF5B, // ｛
            0xFF3B, // ［
            0xFF1A, // ：
            0xFF0C  // ，
        ]
        let closingContext: Set<UInt32> = [
            0x003A, // :
            0x002C, // ,
            0x007D, // }
            0x005D, // ]
            0xFF1A, // ：
            0xFF0C, // ，
            0xFF5D, // ｝
            0xFF3D  // ］
        ]

        var inString = false
        var backslashRun = 0

        for i in 0..<scalars.count {
            let s = scalars[i]
            var r = s

            if isSmartQuote(s) {
                let prev = prevNonWhitespaceScalar(before: i - 1)
                let next = nextNonWhitespaceScalar(after: i + 1)
                let prevIsContext = prev.map { openingContext.contains($0.value) } ?? true
                let nextIsContext = next.map { closingContext.contains($0.value) } ?? true
                if prevIsContext || nextIsContext {
                    r = UnicodeScalar(0x22)! // "
                }
            }

            if !inString {
                // Normalize common fullwidth punctuation used in AI outputs.
                switch r.value {
                case 0xFF5B: // ｛
                    r = UnicodeScalar(0x7B)! // {
                case 0xFF5D: // ｝
                    r = UnicodeScalar(0x7D)! // }
                case 0xFF3B: // ［
                    r = UnicodeScalar(0x5B)! // [
                case 0xFF3D: // ］
                    r = UnicodeScalar(0x5D)! // ]
                case 0xFF1A: // ：
                    r = UnicodeScalar(0x3A)! // :
                case 0xFF0C: // ，
                    r = UnicodeScalar(0x2C)! // ,
                default:
                    break
                }
            }

            let willToggleString = (r.value == 0x22) && (backslashRun % 2 == 0)
            out.unicodeScalars.append(r)

            if willToggleString {
                inString.toggle()
            }

            if r.value == 0x5C { // backslash
                backslashRun += 1
            } else {
                backslashRun = 0
            }
        }

        return out
    }

    private struct ManualSelection {
        struct Input {
            let n: Int
            let text: String
        }

        let inputs: [Input]
        let contextBefore: [String]
        let contextAfter: [String]
    }

    private func makeManualTranslationSelection(
        track: ManualTranslationTrack,
        maxCues: Int,
        maxCharacters: Int,
        includeAlreadyTranslated: Bool
    ) -> ManualSelection {
        let needsTranslation: (SubtitleCue) -> Bool = { cue in
            let source = (cue.originalTranscription ?? cue.primaryText).trimmingCharacters(in: .whitespacesAndNewlines)
            if source.isEmpty { return false }
            if includeAlreadyTranslated { return true }
            switch track {
            case .subtitle1:
                let current = cue.primaryText.trimmingCharacters(in: .whitespacesAndNewlines)
                return normalizeForLooseComparison(current) == normalizeForLooseComparison(source)
            case .subtitle2:
                let current = (cue.secondaryText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return current.isEmpty
            }
        }

        let startIndex: Int
        if includeAlreadyTranslated {
            startIndex = 0
        } else {
            guard let found = orchestrator.cues.firstIndex(where: needsTranslation) else {
                return ManualSelection(inputs: [], contextBefore: [], contextAfter: [])
            }
            startIndex = found
        }

        var inputs: [ManualSelection.Input] = []
        inputs.reserveCapacity(min(maxCues, 24))

        var usedChars = 0
        for idx in startIndex..<orchestrator.cues.count {
            if inputs.count >= maxCues { break }
            let cue = orchestrator.cues[idx]
            guard needsTranslation(cue) else { continue }
            let text = (cue.originalTranscription ?? cue.primaryText).trimmingCharacters(in: .whitespacesAndNewlines)
            let estimated = text.count + 32
            if !inputs.isEmpty, (usedChars + estimated) > maxCharacters { break }
            inputs.append(.init(n: idx + 1, text: text))
            usedChars += estimated
        }

        // Surrounding context for natural phrasing.
        let firstIndex = (inputs.first?.n ?? 1) - 1
        let lastIndex = (inputs.last?.n ?? firstIndex + 1) - 1

        let contextBefore = buildContextLines(
            startIndex: max(0, firstIndex - 3),
            endIndex: firstIndex,
            maxLines: 3
        )
        let contextAfter = buildContextLines(
            startIndex: min(orchestrator.cues.count, lastIndex + 1),
            endIndex: min(orchestrator.cues.count, lastIndex + 1 + 3),
            maxLines: 3
        )

        return ManualSelection(inputs: inputs, contextBefore: contextBefore, contextAfter: contextAfter)
    }

    private func buildContextLines(startIndex: Int, endIndex: Int, maxLines: Int) -> [String] {
        guard startIndex < endIndex else { return [] }
        var lines: [String] = []
        for i in startIndex..<endIndex {
            if lines.count >= maxLines { break }
            let text = (orchestrator.cues[i].originalTranscription ?? orchestrator.cues[i].primaryText)
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { lines.append(text) }
        }
        return lines
    }

    private func formatContextBlock(label: String, lines: [String]) -> String {
        let trimmed = lines
            .map { $0.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !trimmed.isEmpty else { return "" }
        let bullets = trimmed.map { "- \($0)" }.joined(separator: "\n")
        return """

        \(label):
        \(bullets)
        """
    }

    private func normalizeForLooseComparison(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
