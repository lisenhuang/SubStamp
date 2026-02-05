import AVFoundation
import AVKit
import SwiftUI
import UIKit

struct SubtitleReviewView: View {
    @Binding var cues: [SubtitleCue]
    @Binding var style: SubtitleStyle
    let videoURL: URL
    var mode: SubtitleMode
    var onContinue: () -> Void
    var onBack: () -> Void
    var onAbandon: () -> Void

    @State private var player: AVPlayer?
    @State private var isPlayingPreview = false
    @FocusState private var isTextFieldFocused: Bool
    @State private var showAbandonConfirmation = false
    @State private var showCopyConfirmation = false

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
                                Label("Small", systemImage: "textformat.size.smaller").tag(SubtitleFontSize.small)
                                Label("Medium", systemImage: "textformat.size").tag(SubtitleFontSize.medium)
                                Label("Large", systemImage: "textformat.size.larger").tag(SubtitleFontSize.large)
                            }
                            .pickerStyle(.segmented)
                            Toggle("Text shadow", isOn: $style.usesShadow)
                            Picker("Position", selection: $style.position) {
                                Label("Top", systemImage: "arrow.up").tag(SubtitlePosition.top)
                                Label("Middle", systemImage: "arrow.up.and.down").tag(SubtitlePosition.middle)
                                Label("Bottom", systemImage: "arrow.down").tag(SubtitlePosition.bottom)
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
                                    onPreview: { previewCue(cues[index]) }
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
            }
            .onDisappear {
                player?.pause()
                player = nil
            }
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
            .alert("Copied", isPresented: $showCopyConfirmation) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Copied as SRT to your clipboard.")
            }
        }
    }

    private func copyCuesToClipboard() {
        let srt = cues.enumerated().map { index, cue in
            let start = TimeFormatting.srtTimestamp(cue.start)
            let end = TimeFormatting.srtTimestamp(cue.end)

            var lines: [String] = [
                "\(index + 1)",
                "\(start) --> \(end)",
                cue.primaryText
            ]
            if let secondary = cue.secondaryText, !secondary.isEmpty {
                lines.append(secondary)
            }
            return lines.joined(separator: "\n")
        }
        .joined(separator: "\n\n")

        UIPasteboard.general.string = srt
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
}
