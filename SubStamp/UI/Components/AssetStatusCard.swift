import SwiftUI

struct AssetStatusCard: View {
    let title: LocalizedStringKey
    let state: AssetState
    var description: String?

    @Environment(\.locale) private var locale

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
                if progress > 0 {
                    ProgressView(value: progress)
                        .tint(AppColors.accent)
                } else {
                    ProgressView()
                        .tint(AppColors.accent)
                        .padding(.top, AppSpacing.xs)
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

    private var statusText: String {
        switch state {
        case .notInstalled:
            return String(localized: "Required", locale: locale)
        case .downloading:
            return String(localized: "Downloading", locale: locale)
        case .ready:
            return String(localized: "Ready", locale: locale)
        case .failed:
            return String(localized: "Failed", locale: locale)
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
