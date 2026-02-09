import SwiftUI

struct SubtitleCueRow: View {
    let index: Int
    @Binding var cue: SubtitleCue
    var showSecondary: Bool = true
    var onSplit: (() -> Void)?
    var onMergeNext: (() -> Void)?
    var onShiftBack: (() -> Void)?
    var onShiftForward: (() -> Void)?
    var onPreview: (() -> Void)?

    // New properties for 1/2/3 input layout (backward-compatible defaults)
    var showOriginalTranscription: Bool = false
    var showSubtitle1Translation: Bool = false
    var showSubtitle2Translation: Bool = false
    var showWillNotBurnNote: Bool = false
    var subtitle1Label: String = "Subtitle 1"
    var subtitle2Label: String = "Subtitle 2"
    var onOriginalEdited: (() -> Void)?
    var onSubtitleEdited: (() -> Void)?
    var showRetranslateButton: Bool = false
    var isRetranslating: Bool = false
    var onRetranslate: (() -> Void)?

    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            headerRow

            if showOriginalTranscription {
                enhancedInputs
            } else {
                legacyInputs
            }

            actionButtons
        }
        .padding()
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius)
                .stroke(AppColors.cardBorder, lineWidth: 1)
        )
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: AppSpacing.s) {
            Text("\(index + 1)")
                .font(AppTypography.monospace)
                .foregroundStyle(AppColors.secondaryText)
                .frame(minWidth: 24, alignment: .leading)
            Text("\(TimeFormatting.timestamp(cue.start)) - \(TimeFormatting.timestamp(cue.end))")
                .font(AppTypography.monospace)
                .foregroundStyle(AppColors.secondaryText)
            Spacer()
            if cue.hasTranslationError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppColors.warning)
                    .accessibilityLabel("Translation error")
            }
        }
    }

    // MARK: - Legacy inputs (old behavior)

    private var legacyInputs: some View {
        Group {
            TextField(String(localized: "Primary subtitle", bundle: .forLocale(locale)), text: $cue.primaryText, axis: .vertical)
                .font(AppTypography.body)
                .textFieldStyle(.roundedBorder)
            if showSecondary && cue.secondaryText != nil {
                TextField(String(localized: "Secondary subtitle", bundle: .forLocale(locale)), text: Binding(
                    get: { cue.secondaryText ?? "" },
                    set: { cue.secondaryText = $0 }
                ), axis: .vertical)
                .font(AppTypography.body)
                .textFieldStyle(.roundedBorder)
            }
        }
    }

    // MARK: - Enhanced inputs (1/2/3 fields)

    private var enhancedInputs: some View {
        VStack(alignment: .leading, spacing: AppSpacing.m) {
            // Original transcription (always shown in enhanced mode)
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                HStack(spacing: AppSpacing.xs) {
                    Text(String(localized: "Original Transcription", bundle: .forLocale(locale)))
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.secondaryText)
                    if showWillNotBurnNote {
                        Text(String(localized: "(will not burn into video)", bundle: .forLocale(locale)))
                            .font(AppTypography.caption)
                            .foregroundStyle(AppColors.secondaryText.opacity(0.6))
                    }
                }
                TextField(String(localized: "Original transcription", bundle: .forLocale(locale)), text: Binding(
                    get: { cue.originalTranscription ?? cue.primaryText },
                    set: { newValue in
                        cue.originalTranscription = newValue
                        // If sub1 is transcript (no translation shown), sync to primaryText
                        if !showSubtitle1Translation {
                            cue.primaryText = newValue
                        }
                        onOriginalEdited?()
                    }
                ), axis: .vertical)
                .font(AppTypography.body)
                .textFieldStyle(.roundedBorder)

                // Retranslate button (shown when original was edited after translation)
                if showRetranslateButton {
                    Button {
                        onRetranslate?()
                    } label: {
                        HStack(spacing: AppSpacing.xs) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text(isRetranslating ? String(localized: "Translating...", bundle: .forLocale(locale)) : String(localized: "Retranslate", bundle: .forLocale(locale)))
                        }
                        .font(AppTypography.caption)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRetranslating)
                }
            }

            // Subtitle 1 translation (only if sub1 is a translated language)
            if showSubtitle1Translation {
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text(subtitle1Label)
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.secondaryText)
                    TextField(subtitle1Label, text: Binding(
                        get: { cue.primaryText },
                        set: { newValue in
                            cue.primaryText = newValue
                            onSubtitleEdited?()
                        }
                    ), axis: .vertical)
                    .font(AppTypography.body)
                    .textFieldStyle(.roundedBorder)
                }
            }

            // Subtitle 2 translation (only if sub2 is a translated language)
            if showSubtitle2Translation {
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text(subtitle2Label)
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.secondaryText)
                    TextField(subtitle2Label, text: Binding(
                        get: { cue.secondaryText ?? "" },
                        set: { newValue in
                            cue.secondaryText = newValue
                            onSubtitleEdited?()
                        }
                    ), axis: .vertical)
                    .font(AppTypography.body)
                    .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    // MARK: - Action buttons

    private var actionButtons: some View {
        HStack(spacing: AppSpacing.s) {
            Button(String(localized: "Preview", bundle: .forLocale(locale))) { onPreview?() }
            Spacer()
            Button("-0.1s") { onShiftBack?() }
            Button("+0.1s") { onShiftForward?() }
            Button(String(localized: "Split", bundle: .forLocale(locale))) { onSplit?() }
            Button(String(localized: "Merge", bundle: .forLocale(locale))) { onMergeNext?() }
        }
        .font(AppTypography.caption)
    }
}
