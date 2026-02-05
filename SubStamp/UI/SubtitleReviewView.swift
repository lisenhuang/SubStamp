import AVFoundation
import AVKit
import SwiftUI
import Translation

struct SubtitleReviewView: View {
    @Binding var cues: [SubtitleCue]
    @Binding var style: SubtitleStyle
    let videoURL: URL
    let job: JobModel
    var mode: SubtitleMode
    var onContinue: () -> Void
    var onBack: () -> Void
    var onAbandon: () -> Void

    @State private var player: AVPlayer?
    @State private var isPlayingPreview = false
    @State private var config1: TranslationSession.Configuration?
    @State private var config2: TranslationSession.Configuration?
    @State private var config3: TranslationSession.Configuration?

    @State private var session1: TranslationSession?
    @State private var session2: TranslationSession?
    @State private var session3: TranslationSession?

    @State private var transcribedTextByID: [UUID: String] = [:]
    @FocusState private var isTextFieldFocused: Bool
    @State private var showAbandonConfirmation = false

    private let jobStore = JobStore()
    private let aiTranslationService = AppleIntelligenceTranslationService()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Fixed/Sticky Video Player
                VideoPlayer(player: player)
                    .frame(height: 220)
                    .background(Color.black)
                
                ScrollView {
                    VStack(spacing: AppSpacing.l) {
                        VStack(alignment: .leading, spacing: AppSpacing.s) {
                            Text("Subtitle style")
                                .font(AppTypography.bodyEmphasis)
                            Picker("Font size", selection: $style.fontSize) {
                                ForEach(SubtitleFontSize.allCases) { size in
                                    Text(size.rawValue.capitalized).tag(size)
                                }
                            }
                            .pickerStyle(.segmented)
                            Picker("Background", selection: $style.background) {
                                ForEach(SubtitleBackground.allCases) { background in
                                    Text(background.rawValue.capitalized).tag(background)
                                }
                            }
                            .pickerStyle(.menu)
                            Picker("Secondary style", selection: $style.secondaryStyle) {
                                ForEach(SubtitleSecondaryStyle.allCases) { style in
                                    Text(style.rawValue.capitalized).tag(style)
                                }
                            }
                            .pickerStyle(.menu)
                            Toggle("Text shadow", isOn: $style.usesShadow)
                            Picker("Position", selection: $style.position) {
                                ForEach(SubtitlePosition.allCases) { pos in
                                    Text(pos.rawValue.capitalized).tag(pos)
                                }
                            }
                            .pickerStyle(.segmented)
                            HStack {
                                Text("Padding")
                                Slider(value: $style.padding, in: 4...18, step: 1)
                                Text("\(Int(style.padding))")
                                    .frame(width: 32)
                                    .font(AppTypography.caption)
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

                        // Subtitle cues list (using ForEach instead of List for better scrolling)
                        VStack(spacing: AppSpacing.s) {
                            ForEach(Array(cues.indices), id: \.self) { index in
                                SubtitleCueRow(
                                    cue: $cues[index],
                                    showSecondary: mode == .bilingual,
                                    onSplit: { splitCue(at: index) },
                                    onMergeNext: { mergeCue(at: index) },
                                    onShiftBack: { shiftCue(at: index, by: -0.1) },
                                    onShiftForward: { shiftCue(at: index, by: 0.1) },
                                    onPreview: { previewCue(cues[index]) },
                                    onRetryTranslation: { retryTranslation(at: index) }
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

                        PrimaryButton(title: "Continue to export", systemImage: "arrow.right.circle") {
                            onContinue()
                        }

                        Button(role: .destructive) {
                            showAbandonConfirmation = true
                        } label: {
                            Text("Abandon and restart")
                                .font(AppTypography.bodyEmphasis)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, AppSpacing.m)
                                .overlay(
                                    RoundedRectangle(cornerRadius: AppSpacing.controlCornerRadius)
                                        .stroke(AppColors.error, lineWidth: 1)
                                )
                        }
                        .padding(.top, AppSpacing.m)
                    }
                    .padding(AppSpacing.l)
                }
            }
            .ignoresSafeArea(.all, edges: .top)
            .toolbar(.hidden, for: .navigationBar)
            .scrollDismissesKeyboard(.interactively)
            .onTapGesture {
                isTextFieldFocused = false
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        isTextFieldFocused = false
                    }
                }
            }
            .onAppear {
                player = AVPlayer(url: videoURL)
                let transcribed = jobStore.loadCues(id: job.id, type: .transcribed) ?? []
                transcribedTextByID = Dictionary(uniqueKeysWithValues: transcribed.map { ($0.id, $0.primaryText) })
                configureTranslationFrameworkSessions()
            }
            .onDisappear {
                player?.pause()
                player = nil
            }
            .translationTask(config1) { session1 = $0 }
            .translationTask(config2) { session2 = $0 }
            .translationTask(config3) { session3 = $0 }
            .confirmationDialog(
                "Abandon this job?",
                isPresented: $showAbandonConfirmation,
                titleVisibility: .visible
            ) {
                Button("Abandon and restart", role: .destructive) {
                    onAbandon()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("All progress on this video will be lost.")
            }
        }
    }

    private func configureTranslationFrameworkSessions() {
        let base = Locale.Language(identifier: Locale(identifier: job.transcriptionLocale).identifier(.bcp47))
        let english = Locale.Language(identifier: "en-US")
        let t1 = Locale.Language(identifier: Locale(identifier: job.language1Locale).identifier(.bcp47))
        let t2 = job.translationTargetLocale.map { Locale.Language(identifier: Locale(identifier: $0).identifier(.bcp47)) }

        if job.subtitle1Mode == .pivot || job.subtitle2Mode == .pivot {
            config1 = .init(source: base, target: english)
        } else {
            config1 = nil
        }

        if job.language1Locale != job.transcriptionLocale {
            if job.subtitle1Mode == .pivot {
                config2 = .init(source: english, target: t1)
            } else {
                config2 = .init(source: base, target: t1)
            }
        } else {
            config2 = nil
        }

        if job.subtitleMode == .bilingual, let t2, job.translationTargetLocale != job.transcriptionLocale {
            if job.subtitle2Mode == .pivot {
                config3 = .init(source: english, target: t2)
            } else {
                config3 = .init(source: base, target: t2)
            }
        } else {
            config3 = nil
        }
    }

    private func splitCue(at index: Int) {
        guard cues.indices.contains(index) else { return }
        let cue = cues[index]
        let words = cue.primaryText.split(separator: " ")
        guard words.count > 1 else { return }
        let midpoint = words.count / 2
        let firstText = words.prefix(midpoint).joined(separator: " ")
        let secondText = words.suffix(from: midpoint).joined(separator: " ")
        let midTime = CMTime(seconds: (cue.start.seconds + cue.end.seconds) / 2, preferredTimescale: 600)
        cues[index] = SubtitleCue(
            id: cue.id,
            start: cue.start,
            end: midTime,
            primaryText: String(firstText),
            secondaryText: cue.secondaryText,
            hasTranslationError: cue.hasTranslationError
        )
        let newCue = SubtitleCue(
            start: midTime,
            end: cue.end,
            primaryText: String(secondText),
            secondaryText: cue.secondaryText,
            hasTranslationError: cue.hasTranslationError
        )
        cues.insert(newCue, at: index + 1)
    }

    private func mergeCue(at index: Int) {
        guard cues.indices.contains(index), cues.indices.contains(index + 1) else { return }
        let current = cues[index]
        let next = cues[index + 1]
        let mergedText = [current.primaryText, next.primaryText].joined(separator: " ")
        let merged = SubtitleCue(
            id: current.id,
            start: current.start,
            end: next.end,
            primaryText: mergedText,
            secondaryText: current.secondaryText ?? next.secondaryText,
            hasTranslationError: current.hasTranslationError || next.hasTranslationError
        )
        cues[index] = merged
        cues.remove(at: index + 1)
    }

    private func shiftCue(at index: Int, by seconds: Double) {
        guard cues.indices.contains(index) else { return }
        cues[index].shift(by: seconds)
    }

    private func previewCue(_ cue: SubtitleCue) {
        guard let player else { return }
        
        // Use zero tolerance for precise seeking to the cue start
        player.seek(to: cue.start, toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        isPlayingPreview = true
        
        let durationSeconds = max(0.2, cue.end.seconds - cue.start.seconds)
        Task {
            // Wait for the exact duration of the cue
            try? await Task.sleep(nanoseconds: UInt64(durationSeconds * 1_000_000_000))
            await MainActor.run {
                player.pause()
                isPlayingPreview = false
            }
        }
    }

    private func retryTranslation(at index: Int) {
        guard cues.indices.contains(index) else { return }

        Task { @MainActor in
            let cueID = cues[index].id

            let transcribedText = transcribedTextByID[cueID]
            let primaryText = cues[index].primaryText
            let secondaryText = cues[index].secondaryText ?? ""

            let needsPrimaryTranslation = job.language1Locale != job.transcriptionLocale
            let needsSecondaryTranslation = job.subtitleMode == .bilingual
                && (job.translationTargetLocale != nil && job.translationTargetLocale != job.transcriptionLocale)

            let shouldRetrySecondary = needsSecondaryTranslation && (
                secondaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || normalizeForRetryComparison(secondaryText) == normalizeForRetryComparison(primaryText)
                    || (transcribedText != nil && normalizeForRetryComparison(secondaryText) == normalizeForRetryComparison(transcribedText ?? ""))
            )

            let shouldRetryPrimary = needsPrimaryTranslation && (
                transcribedText != nil && normalizeForRetryComparison(primaryText) == normalizeForRetryComparison(transcribedText ?? "")
            )

#if DEBUG
            AppLog.append("[REVIEW-RETRY] start provider=\(job.translationProvider.rawValue) cueIndex=\(index) retryPrimary=\(shouldRetryPrimary) retrySecondary=\(shouldRetrySecondary)")
#endif

            switch job.translationProvider {
            case .appleIntelligence:
                await retryWithAppleIntelligence(
                    cueIndex: index,
                    retryPrimary: shouldRetryPrimary,
                    retrySecondary: shouldRetrySecondary
                )
            case .translationFramework:
                await retryWithTranslationFramework(
                    cueIndex: index,
                    retryPrimary: shouldRetryPrimary,
                    retrySecondary: shouldRetrySecondary
                )
            }
        }
    }

    @MainActor
    private func retryWithTranslationFramework(cueIndex index: Int, retryPrimary: Bool, retrySecondary: Bool) async {
        guard cues.indices.contains(index) else { return }
        let cueID = cues[index].id
        let transcribedText = transcribedTextByID[cueID] ?? cues[index].primaryText

        var anyError = false

        if retryPrimary {
            do {
                let translated = try await translateFrameworkText(
                    transcribedText,
                    isSubtitle2: false
                )
                cues[index].primaryText = SubtitleTextCleaner.clean(translated)
            } catch {
                anyError = true
#if DEBUG
                AppLog.append("[REVIEW-RETRY] framework primary failed: \(error.localizedDescription)")
#endif
            }
        }

        if retrySecondary {
            do {
                let translated = try await translateFrameworkText(
                    transcribedText,
                    isSubtitle2: true
                )
                cues[index].secondaryText = SubtitleTextCleaner.clean(translated)
            } catch {
                anyError = true
#if DEBUG
                AppLog.append("[REVIEW-RETRY] framework secondary failed: \(error.localizedDescription)")
#endif
            }
        }

        cues[index].hasTranslationError = anyError
#if DEBUG
        AppLog.append("[REVIEW-RETRY] done provider=translationFramework cueIndex=\(index) ok=\(!anyError)")
#endif
    }

    private func translateFrameworkText(_ text: String, isSubtitle2: Bool) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if isSubtitle2 {
            if job.subtitle2Mode == .pivot {
                guard let sessionA = session1, let sessionB = session3 else { throw SubStampError.translationError(underlying: NSError(domain: "SubStamp", code: -310)) }
                let mid = try await sessionA.translate(trimmed).targetText
                return try await sessionB.translate(mid).targetText
            } else {
                guard let session = session3 else { throw SubStampError.translationError(underlying: NSError(domain: "SubStamp", code: -311)) }
                return try await session.translate(trimmed).targetText
            }
        } else {
            if job.subtitle1Mode == .pivot {
                guard let sessionA = session1, let sessionB = session2 else { throw SubStampError.translationError(underlying: NSError(domain: "SubStamp", code: -312)) }
                let mid = try await sessionA.translate(trimmed).targetText
                return try await sessionB.translate(mid).targetText
            } else {
                guard let session = session2 else { throw SubStampError.translationError(underlying: NSError(domain: "SubStamp", code: -313)) }
                return try await session.translate(trimmed).targetText
            }
        }
    }

    @MainActor
    private func retryWithAppleIntelligence(cueIndex index: Int, retryPrimary: Bool, retrySecondary: Bool) async {
        guard cues.indices.contains(index) else { return }

        var targets: [Locale.Language] = []
        if retryPrimary {
            let bcp47 = Locale(identifier: job.language1Locale).identifier(.bcp47)
            targets.append(Locale.Language(identifier: bcp47))
        }
        if retrySecondary, let t2 = job.translationTargetLocale {
            let bcp47 = Locale(identifier: t2).identifier(.bcp47)
            targets.append(Locale.Language(identifier: bcp47))
        }

        if targets.isEmpty {
#if DEBUG
            AppLog.append("[REVIEW-RETRY] skip (no targets)")
#endif
            return
        }

        let sourceLocale = Locale(identifier: job.transcriptionLocale)
        let context = buildTranscriptionContext(around: index, radius: 4)

        do {
            let result = try await aiTranslationService.translate(
                cues: context,
                source: sourceLocale,
                targets: targets
            ) { _, _ in }

            let cueID = cues[index].id
            var anyError = false

            if retryPrimary {
                let key = Locale.Language(identifier: Locale(identifier: job.language1Locale).identifier(.bcp47)).minimalIdentifier
                if let translated = result[key]?.first(where: { $0.id == cueID })?.secondaryText,
                   !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    cues[index].primaryText = SubtitleTextCleaner.clean(translated)
                } else {
                    anyError = true
                }
            }

            if retrySecondary, let t2 = job.translationTargetLocale {
                let key = Locale.Language(identifier: Locale(identifier: t2).identifier(.bcp47)).minimalIdentifier
                if let translated = result[key]?.first(where: { $0.id == cueID })?.secondaryText,
                   !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    cues[index].secondaryText = SubtitleTextCleaner.clean(translated)
                } else {
                    anyError = true
                }
            }

            cues[index].hasTranslationError = anyError

#if DEBUG
            AppLog.append("[REVIEW-RETRY] done provider=appleIntelligence cueIndex=\(index) ok=\(!anyError)")
#endif
        } catch {
#if DEBUG
            AppLog.append("[REVIEW-RETRY] appleIntelligence failed cueIndex=\(index): \(error.localizedDescription)")
#endif
            if isSafetyGuardrailsError(error) {
#if DEBUG
                AppLog.append("[REVIEW-RETRY] fallback provider=translationFramework cueIndex=\(index)")
#endif
                await retryWithTranslationFramework(cueIndex: index, retryPrimary: retryPrimary, retrySecondary: retrySecondary)
                return
            }

            cues[index].hasTranslationError = true
        }
    }

    private func isSafetyGuardrailsError(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("unsafe")
            || message.contains("safety guardrails")
            || message.contains("guardrails were triggered")
    }

    private func buildTranscriptionContext(around index: Int, radius: Int) -> [SubtitleCue] {
        guard cues.indices.contains(index) else { return [] }

        let start = max(0, index - radius)
        let end = min(cues.count - 1, index + radius)

        return (start...end).map { i in
            let cue = cues[i]
            let sourceText: String
            if job.language1Locale == job.transcriptionLocale {
                sourceText = cue.primaryText
            } else {
                sourceText = transcribedTextByID[cue.id] ?? cue.primaryText
            }
            return SubtitleCue(id: cue.id, start: cue.start, end: cue.end, primaryText: sourceText)
        }
    }

    private func normalizeForRetryComparison(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
