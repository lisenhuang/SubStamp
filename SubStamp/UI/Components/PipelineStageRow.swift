import SwiftUI

struct PipelineStageRow: View {
    let title: LocalizedStringKey
    let state: PipelineStageState
    let progress: Double
    var detail: LocalizedStringKey?

    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            HStack(spacing: AppSpacing.s) {
                Image(systemName: stateIcon)
                    .foregroundStyle(stateColor)
                Text(title)
                    .font(AppTypography.bodyEmphasis)
                Spacer()
                Text(stateLabel)
                    .font(AppTypography.caption)
                    .foregroundStyle(stateColor)
            }
            if let detail {
                Text(detail)
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.secondaryText)
            }
            ProgressView(value: progress)
                .tint(AppColors.accent)
        }
        .padding()
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius)
                .stroke(AppColors.cardBorder, lineWidth: 1)
        )
    }

    private var stateIcon: String {
        switch state {
        case .pending:
            return "circle.dashed"
        case .active:
            return "bolt.fill"
        case .done:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.octagon.fill"
        }
    }

    private var stateLabel: String {
        switch state {
        case .pending:
            return String(localized: "Pending", locale: locale)
        case .active:
            return String(localized: "Running", locale: locale)
        case .done:
            return String(localized: "Done", locale: locale)
        case .failed:
            return String(localized: "Failed", locale: locale)
        }
    }

    private var stateColor: Color {
        switch state {
        case .pending:
            return AppColors.secondaryText
        case .active:
            return AppColors.accent
        case .done:
            return AppColors.success
        case .failed:
            return AppColors.error
        }
    }
}
