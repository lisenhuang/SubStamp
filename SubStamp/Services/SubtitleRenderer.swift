import AVFoundation
import UIKit

final class SubtitleRenderer {
    struct RenderResult {
        let composition: AVMutableComposition
        let videoComposition: AVMutableVideoComposition
        let renderSize: CGSize
    }

    func createComposition(
        asset: AVAsset,
        cues: [SubtitleCue],
        mode: SubtitleMode,
        style: SubtitleStyle,
        layout: SubtitleLayout,
        timeRange: CMTimeRange? = nil
    ) async throws -> RenderResult {
        let composition = AVMutableComposition()
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw SubStampError.exportFailed(underlying: NSError(domain: "SubStamp", code: -4))
        }

        let videoCompositionTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )
        let sourceRange = timeRange ?? CMTimeRange(start: .zero, duration: asset.duration)
        let timelineRange = CMTimeRange(start: .zero, duration: sourceRange.duration)
        try videoCompositionTrack?.insertTimeRange(sourceRange, of: videoTrack, at: .zero)

        if let audioTrack = asset.tracks(withMediaType: .audio).first {
            let audioCompositionTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
            try audioCompositionTrack?.insertTimeRange(sourceRange, of: audioTrack, at: .zero)
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

        let preferredTransform = videoTrack.preferredTransform
        let naturalSize = videoTrack.naturalSize
        let transformedSize = naturalSize.applying(preferredTransform)
        let transformedWidth = abs(transformedSize.width)
        let transformedHeight = abs(transformedSize.height)
        let fallbackWidth = abs(naturalSize.width)
        let fallbackHeight = abs(naturalSize.height)
        let safeWidth = max(1, round(transformedWidth > 0 ? transformedWidth : fallbackWidth))
        let safeHeight = max(1, round(transformedHeight > 0 ? transformedHeight : fallbackHeight))
        let renderSize = CGSize(width: safeWidth, height: safeHeight)
        videoComposition.renderSize = renderSize

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = timelineRange
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoCompositionTrack!)
        let fixedTransform = normalizeTransform(preferredTransform, renderSize: renderSize)
        layerInstruction.setTransform(fixedTransform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        let parentLayer = CALayer()
        let videoLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: renderSize)
        videoLayer.frame = CGRect(origin: .zero, size: renderSize)
        parentLayer.addSublayer(videoLayer)

        let overlayLayers = createSubtitleLayers(
            cues: cues,
            mode: mode,
            style: style,
            layout: layout,
            renderSize: renderSize,
            duration: timelineRange.duration
        )
        overlayLayers.forEach { parentLayer.addSublayer($0) }

        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parentLayer
        )

        return RenderResult(composition: composition, videoComposition: videoComposition, renderSize: renderSize)
    }

    private func normalizeTransform(_ transform: CGAffineTransform, renderSize: CGSize) -> CGAffineTransform {
        var transform = transform
        if transform.tx == 0, transform.ty == 0 {
            if transform.a == 0 && transform.b == 1.0 && transform.c == -1.0 && transform.d == 0 {
                transform = transform.translatedBy(x: renderSize.width, y: 0)
            } else if transform.a == 0 && transform.b == -1.0 && transform.c == 1.0 && transform.d == 0 {
                transform = transform.translatedBy(x: 0, y: renderSize.height)
            } else if transform.a == -1.0 && transform.d == -1.0 {
                transform = transform.translatedBy(x: renderSize.width, y: renderSize.height)
            }
        }
        return transform
    }

    private func createSubtitleLayers(
        cues: [SubtitleCue],
        mode: SubtitleMode,
        style: SubtitleStyle,
        layout: SubtitleLayout,
        renderSize: CGSize,
        duration: CMTime
    ) -> [CALayer] {
        var layers: [CALayer] = []

        for cue in cues {
            let cueLayout = SubtitleLayoutCalculator.makeCueLayout(
                primaryText: cue.primaryText,
                secondaryText: mode == .bilingual ? cue.secondaryText : nil,
                style: style,
                renderSize: renderSize
            )

            let primaryLayer = buildTextLayer(
                line: cueLayout.primary,
                renderSize: renderSize,
                lineSpacing: cueLayout.lineSpacing,
                background: cueLayout.background,
                usesShadow: cueLayout.usesShadow
            )

            let secondaryLayer = cueLayout.secondary.map {
                buildTextLayer(
                    line: $0,
                    renderSize: renderSize,
                    lineSpacing: cueLayout.lineSpacing,
                    background: cueLayout.background,
                    usesShadow: cueLayout.usesShadow
                )
            }

            let cueLayers = [primaryLayer, secondaryLayer].compactMap { $0 }
            cueLayers.forEach { applyTimingAnimation($0, cue: cue, duration: duration) }
            layers.append(contentsOf: cueLayers)
        }

        if layout == .single {
            return layers
        }
        return layers
    }

    private func buildTextLayer(
        line: SubtitleLineLayout,
        renderSize: CGSize,
        lineSpacing: Double,
        background: SubtitleBackground,
        usesShadow: Bool
    ) -> CALayer {
        let attributed = attributedText(
            text: line.text,
            font: line.font,
            lineSpacing: lineSpacing,
            opacity: line.opacity
        )

        let textLayer = CATextLayer()
        textLayer.string = attributed
        textLayer.alignmentMode = .center
        textLayer.isWrapped = true
        textLayer.contentsScale = UIScreen.main.scale
        textLayer.frame = CGRect(
            x: line.padding,
            y: line.padding,
            width: line.innerSize.width,
            height: line.innerSize.height
        )

        if usesShadow {
            textLayer.shadowColor = UIColor.black.cgColor
            textLayer.shadowOpacity = 0.6
            textLayer.shadowRadius = 3
            textLayer.shadowOffset = CGSize(width: 0, height: 1)
        }

        let layerFrame = layerFrame(fromTopFrame: line.outerFrame, renderSize: renderSize)

        switch background {
        case .none:
            textLayer.frame = layerFrame
            return textLayer
        case .translucent, .solid:
            let bgLayer = CALayer()
            bgLayer.frame = CGRect(origin: .zero, size: layerFrame.size)
            bgLayer.backgroundColor = (background == .solid ? UIColor.black : UIColor.black.withAlphaComponent(0.5)).cgColor
            bgLayer.cornerRadius = 10

            let container = CALayer()
            container.frame = layerFrame
            container.addSublayer(bgLayer)
            container.addSublayer(textLayer)
            return container
        }
    }

    private func attributedText(text: String, font: UIFont, lineSpacing: Double, opacity: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = lineSpacing
        paragraph.lineBreakMode = .byWordWrapping

        return NSAttributedString(
            string: SubtitleTextCleaner.clean(text),
            attributes: [
                .font: font,
                .foregroundColor: UIColor.white.withAlphaComponent(opacity),
                .paragraphStyle: paragraph
            ]
        )
    }

    private func applyTimingAnimation(_ layer: CALayer, cue: SubtitleCue, duration: CMTime) {
        layer.opacity = 0

        let animation = CAKeyframeAnimation(keyPath: "opacity")
        let start = cue.start.seconds
        let end = cue.end.seconds
        let total = max(0.01, duration.seconds)
        let epsilon = 0.0001
        let startNorm = max(0, min(1 - epsilon, start / total))
        let endNorm = max(startNorm + epsilon, min(1, end / total))
        let fadeInStart = max(0, startNorm - epsilon)
        let fadeOutEnd = min(1, endNorm + epsilon)

        animation.values = [0, 0, 1, 1, 0, 0] as [NSNumber]
        animation.keyTimes = [
            0,
            NSNumber(value: fadeInStart),
            NSNumber(value: startNorm),
            NSNumber(value: endNorm),
            NSNumber(value: fadeOutEnd),
            1
        ]
        animation.duration = total
        animation.beginTime = AVCoreAnimationBeginTimeAtZero
        animation.isRemovedOnCompletion = false
        animation.fillMode = .both
        layer.add(animation, forKey: "subtitleOpacity")
    }

    private func layerFrame(fromTopFrame topFrame: CGRect, renderSize: CGSize) -> CGRect {
        CGRect(
            x: topFrame.minX,
            y: renderSize.height - topFrame.maxY,
            width: topFrame.width,
            height: topFrame.height
        )
    }
}
