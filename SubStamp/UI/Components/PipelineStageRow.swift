import SwiftUI

struct PipelineStageRow: View {
    let title: String
    let state: PipelineStageState
    let progress: Double
    var detail: String?

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
            return "Pending"
        case .active:
            return "Running"
        case .done:
            return "Done"
        case .failed:
            return "Failed"
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
