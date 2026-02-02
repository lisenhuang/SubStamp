import AVFoundation
import AVKit
import SwiftUI
import Translation

struct SubtitleReviewView: View {
    @Binding var cues: [SubtitleCue]
    @Binding var style: SubtitleStyle
    let videoURL: URL
    var mode: SubtitleMode
    var translationTarget: Locale.Language?
    var sourceLocaleIdentifier: String?
    var onContinue: () -> Void
    var onBack: () -> Void

    @State private var player: AVPlayer?
    @State private var isPlayingPreview = false
    @State private var translationConfig: TranslationSession.Configuration?
    @State private var translationSession: TranslationSession?
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Fixed/Sticky Video Player
                VideoPlayer(player: player)
                    .frame(height: 220)
                    .background(Color.black)
                
                ScrollView {
                    VStack(spacing: AppSpacing.l) {
                        HStack {
                            Button {
                                onBack()
                            } label: {
                                Label("Back", systemImage: "chevron.left")
                                    .font(AppTypography.bodyEmphasis)
                                    .foregroundStyle(AppColors.secondaryText)
                            }
                            Spacer()
                        }

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
                }
                .padding(AppSpacing.l)
            }
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
            .navigationTitle("Review subtitles")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                player = AVPlayer(url: videoURL)
                if let target = translationTarget {
                    let source = sourceLocaleIdentifier.map { Locale.Language(identifier: $0) }
                    translationConfig = TranslationSession.Configuration(source: source, target: target)
                }
            }
            .onDisappear {
                player?.pause()
                player = nil
            }
        }
        .translationTask(translationConfig) { session in
            translationSession = session
        }
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
        guard cues.indices.contains(index), let session = translationSession else { return }
        Task {
            do {
                let response = try await session.translate(cues[index].primaryText)
                cues[index].secondaryText = response.targetText
                cues[index].hasTranslationError = false
            } catch {
                cues[index].hasTranslationError = true
            }
        }
    }
}
