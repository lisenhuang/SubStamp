import AVKit
import SwiftUI

struct VideoPreviewView: View {
    let url: URL?
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .clipShape(RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius)
                        .fill(AppColors.secondaryBackground)
                    VStack(spacing: AppSpacing.s) {
                        Image(systemName: "video")
                            .font(.largeTitle)
                            .foregroundStyle(AppColors.secondaryText)
                        Text("No video selected")
                            .font(AppTypography.caption)
                            .foregroundStyle(AppColors.secondaryText)
                    }
                }
            }
        }
        .onAppear {
            guard let url else { return }
            player = AVPlayer(url: url)
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}
