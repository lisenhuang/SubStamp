import SwiftUI
import UIKit

struct PrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    var isEnabled: Bool = true
    var action: () -> Void

    var body: some View {
        Button {
            if isEnabled {
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.impactOccurred()
                action()
            }
        } label: {
            HStack(spacing: AppSpacing.s) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
                    .font(AppTypography.bodyEmphasis)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppSpacing.m)
            .foregroundStyle(Color.white)
            .background(isEnabled ? AppColors.accent : AppColors.cardBorder)
            .clipShape(RoundedRectangle(cornerRadius: AppSpacing.controlCornerRadius))
        }
        .disabled(!isEnabled)
        .accessibilityLabel(title)
    }
}
