import AVKit
import SwiftUI

struct VideoPreviewView: View {
    let url: URL?
    @State private var player: AVPlayer?
    @State private var isFullScreen = false

    var body: some View {
        Group {
            if let player {
                ZStack(alignment: .bottomTrailing) {
                    VideoPlayer(player: player)
                        .clipShape(RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius))
                    
                    Button {
                        isFullScreen = true
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white)
                            .padding(AppSpacing.s)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Circle())
                    }
                    .padding(AppSpacing.m)
                }
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
        .fullScreenCover(isPresented: $isFullScreen) {
            ZStack(alignment: .topLeading) {
                if let player {
                    VideoPlayer(player: player)
                        .ignoresSafeArea()
                }
                
                Button {
                    isFullScreen = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.white)
                        .padding()
                        .shadow(radius: 4)
                }
            }
            .background(Color.black)
        }
        .onAppear {
            guard let url else { return }
            player = AVPlayer(url: url)
        }
        .onChange(of: url) { _, newURL in
            if let u = newURL {
                player = AVPlayer(url: u)
            } else {
                player?.pause()
                player = nil
            }
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}
