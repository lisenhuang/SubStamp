import SwiftUI

struct SubtitleCueRow: View {
    @Binding var cue: SubtitleCue
    var showSecondary: Bool = true
    var onSplit: (() -> Void)?
    var onMergeNext: (() -> Void)?
    var onShiftBack: (() -> Void)?
    var onShiftForward: (() -> Void)?
    var onPreview: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            HStack {
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
            TextField("Primary subtitle", text: $cue.primaryText, axis: .vertical)
                .font(AppTypography.body)
                .textFieldStyle(.roundedBorder)
            if showSecondary && cue.secondaryText != nil {
                TextField("Secondary subtitle", text: Binding(
                    get: { cue.secondaryText ?? "" },
                    set: { cue.secondaryText = $0 }
                ), axis: .vertical)
                .font(AppTypography.body)
                .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: AppSpacing.s) {
                Button("Preview") { onPreview?() }
                Spacer()
                Button("-0.1s") { onShiftBack?() }
                Button("+0.1s") { onShiftForward?() }
                Button("Split") { onSplit?() }
                Button("Merge") { onMergeNext?() }
            }
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
}
