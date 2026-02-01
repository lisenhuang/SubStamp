import SwiftUI

struct AssetStatusCard: View {
    let title: String
    let state: AssetState
    var description: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            HStack {
                Text(title)
                    .font(AppTypography.bodyEmphasis)
                Spacer()
                Text(statusText)
                    .font(AppTypography.caption)
                    .foregroundStyle(statusColor)
            }
            if let description {
                Text(description)
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.secondaryText)
            }
            if case let .downloading(progress) = state {
                ProgressView(value: progress)
                    .tint(AppColors.accent)
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

    private var statusText: String {
        switch state {
        case .notInstalled:
            return "Required"
        case .downloading:
            return "Downloading"
        case .ready:
            return "Ready"
        case .failed:
            return "Failed"
        }
    }

    private var statusColor: Color {
        switch state {
        case .notInstalled:
            return AppColors.warning
        case .downloading:
            return AppColors.accent
        case .ready:
            return AppColors.success
        case .failed:
            return AppColors.error
        }
    }
}
