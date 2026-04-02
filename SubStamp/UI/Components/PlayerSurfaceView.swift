import AVFoundation
import SwiftUI
import UIKit

struct PlayerSurfaceView: UIViewRepresentable {
    let player: AVPlayer?
    let onVideoRectChange: (CGRect) -> Void
    var keyboardControlsEnabled: Bool = false
    var onTogglePlayback: (() -> Void)?
    var onSeekBackward: (() -> Void)?
    var onSeekForward: (() -> Void)?

    func makeUIView(context: Context) -> PlayerSurfaceUIView {
        let view = PlayerSurfaceUIView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.onVideoRectChange = onVideoRectChange
        view.keyboardControlsEnabled = keyboardControlsEnabled
        view.onTogglePlayback = onTogglePlayback
        view.onSeekBackward = onSeekBackward
        view.onSeekForward = onSeekForward
        view.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerSurfaceUIView, context: Context) {
        uiView.onVideoRectChange = onVideoRectChange
        uiView.keyboardControlsEnabled = keyboardControlsEnabled
        uiView.onTogglePlayback = onTogglePlayback
        uiView.onSeekBackward = onSeekBackward
        uiView.onSeekForward = onSeekForward
        uiView.player = player
        uiView.reportVideoRectIfNeeded()
        uiView.refreshFirstResponder()
    }
}

final class PlayerSurfaceUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    var onVideoRectChange: ((CGRect) -> Void)?
    var keyboardControlsEnabled = false {
        didSet { refreshFirstResponder() }
    }
    var onTogglePlayback: (() -> Void)?
    var onSeekBackward: (() -> Void)?
    var onSeekForward: (() -> Void)?

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

    override var canBecomeFirstResponder: Bool {
        keyboardControlsEnabled
    }

    override var keyCommands: [UIKeyCommand]? {
        guard keyboardControlsEnabled else { return nil }
        return [
            UIKeyCommand(
                input: " ",
                modifierFlags: [],
                action: #selector(handleTogglePlayback),
                discoverabilityTitle: "Play/Pause"
            ),
            UIKeyCommand(
                input: UIKeyCommand.inputLeftArrow,
                modifierFlags: [],
                action: #selector(handleSeekBackward),
                discoverabilityTitle: "Rewind 10 seconds"
            ),
            UIKeyCommand(
                input: UIKeyCommand.inputRightArrow,
                modifierFlags: [],
                action: #selector(handleSeekForward),
                discoverabilityTitle: "Fast forward 10 seconds"
            )
        ]
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        reportVideoRectIfNeeded()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        refreshFirstResponder()
    }

    func reportVideoRectIfNeeded() {
        let rect = playerLayer.videoRect.integral
        guard rect != lastReportedVideoRect else { return }
        lastReportedVideoRect = rect
        onVideoRectChange?(rect)
    }

    func refreshFirstResponder() {
        guard window != nil else { return }
        if keyboardControlsEnabled {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if !self.isFirstResponder {
                    self.becomeFirstResponder()
                }
            }
        } else if isFirstResponder {
            resignFirstResponder()
        }
    }

    @objc
    private func handleTogglePlayback() {
        onTogglePlayback?()
    }

    @objc
    private func handleSeekBackward() {
        onSeekBackward?()
    }

    @objc
    private func handleSeekForward() {
        onSeekForward?()
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard keyboardControlsEnabled else {
            super.pressesEnded(presses, with: event)
            return
        }

        if presses.contains(where: { $0.type == .playPause }) {
            onTogglePlayback?()
            return
        }

        super.pressesEnded(presses, with: event)
    }
}
