import AVFoundation
import SwiftUI
import UIKit

struct PlayerSurfaceView: UIViewRepresentable {
    let player: AVPlayer?
    let onVideoRectChange: (CGRect) -> Void

    func makeUIView(context: Context) -> PlayerSurfaceUIView {
        let view = PlayerSurfaceUIView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.onVideoRectChange = onVideoRectChange
        view.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerSurfaceUIView, context: Context) {
        uiView.onVideoRectChange = onVideoRectChange
        uiView.player = player
        uiView.reportVideoRectIfNeeded()
    }
}

final class PlayerSurfaceUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    var onVideoRectChange: ((CGRect) -> Void)?

    var player: AVPlayer? {
        get { playerLayer.player }
        set {
            if playerLayer.player !== newValue {
                playerLayer.player = newValue
                DispatchQueue.main.async { [weak self] in
                    self?.reportVideoRectIfNeeded()
                }
            }
        }
    }

    private var lastReportedVideoRect: CGRect = .null

    override func layoutSubviews() {
        super.layoutSubviews()
        reportVideoRectIfNeeded()
    }

    func reportVideoRectIfNeeded() {
        let rect = playerLayer.videoRect.integral
        guard rect != lastReportedVideoRect else { return }
        lastReportedVideoRect = rect
        onVideoRectChange?(rect)
    }
}
