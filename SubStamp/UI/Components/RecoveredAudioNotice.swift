import SwiftUI

struct RecoveredAudioNotice: View {
    let endSeconds: Double
    @Environment(\.locale) private var locale

    var body: some View {
        Label {
            Text(String(format: String(localized: "The video has an unreadable ending. Audio was recovered up to %@; subtitles cover only the recovered audio.", bundle: .forLocale(locale)), TimeFormatting.duration(endSeconds)))
        } icon: {
            Image(systemName: "exclamationmark.triangle")
        }
        .font(AppTypography.caption)
        .foregroundStyle(AppColors.secondaryText)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius))
    }
}
