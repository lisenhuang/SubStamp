import SwiftUI

struct WizardHeaderView: View {
    let step: Int
    let total: Int
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            HStack {
                Text("Step \(step) of \(total)", tableName: nil, bundle: .main)
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.secondaryText)
                Spacer()
            }
            Text(title)
                .font(AppTypography.headline)
            if let subtitle {
                Text(subtitle)
                    .font(AppTypography.body)
                    .foregroundStyle(AppColors.secondaryText)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius)
                .stroke(AppColors.cardBorder, lineWidth: 1)
        )
    }
}
