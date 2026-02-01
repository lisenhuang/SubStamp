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
        let range = timeRange ?? CMTimeRange(start: .zero, duration: asset.duration)
        try videoCompositionTrack?.insertTimeRange(
            range,
            of: videoTrack,
            at: .zero
        )

        if let audioTrack = asset.tracks(withMediaType: .audio).first {
            let audioCompositionTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
            try audioCompositionTrack?.insertTimeRange(
                range,
                of: audioTrack,
                at: .zero
            )
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

        let preferredTransform = videoTrack.preferredTransform
        let naturalSize = videoTrack.naturalSize
        let transformedSize = naturalSize.applying(preferredTransform)
        let renderSize = CGSize(width: abs(transformedSize.width), height: abs(transformedSize.height))
        videoComposition.renderSize = renderSize

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = range
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
            duration: range.duration
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
        let margin = max(24, renderSize.height * 0.06)
        let maxWidth = renderSize.width * 0.86
        let baseFontSize = fontSize(for: style.fontSize, renderSize: renderSize)
        let secondaryScale: CGFloat = style.secondaryStyle == .subdued ? 0.84 : 1.0

        var layers: [CALayer] = []
        for cue in cues {
            let primaryFont = UIFont.systemFont(ofSize: baseFontSize, weight: .semibold)
            let secondaryFont = UIFont.systemFont(ofSize: baseFontSize * secondaryScale, weight: .regular)

            let primaryLayer = buildTextLayer(
                text: cue.primaryText,
                font: primaryFont,
                maxWidth: maxWidth,
                renderSize: renderSize,
                margin: margin,
                position: style.position,
                lineSpacing: style.lineSpacing,
                background: style.background,
                usesShadow: style.usesShadow,
                padding: CGFloat(style.padding)
            )

            let secondaryLayer: CALayer?
            if mode == .bilingual, let secondaryText = cue.secondaryText, !secondaryText.isEmpty {
                let extraOffset = primaryLayer.frame.height + (margin * 0.1)
                secondaryLayer = buildTextLayer(
                    text: secondaryText,
                    font: secondaryFont,
                    maxWidth: maxWidth,
                    renderSize: renderSize,
                    margin: margin,
                    position: style.position,
                    lineSpacing: style.lineSpacing,
                    background: style.background == .none ? .none : .translucent,
                    usesShadow: style.usesShadow,
                    padding: CGFloat(style.padding),
                    extraOffset: extraOffset
                )
            } else {
                secondaryLayer = nil
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
        text: String,
        font: UIFont,
        maxWidth: CGFloat,
        renderSize: CGSize,
        margin: CGFloat,
        position: SubtitlePosition,
        lineSpacing: Double,
        background: SubtitleBackground,
        usesShadow: Bool,
        padding: CGFloat,
        extraOffset: CGFloat = 0
    ) -> CALayer {
        let attributed = attributedText(text: text, font: font, lineSpacing: lineSpacing)
        let boundingRect = attributed.boundingRect(
            with: CGSize(width: maxWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )

        let textLayer = CATextLayer()
        textLayer.string = attributed
        textLayer.alignmentMode = .center
        textLayer.isWrapped = true
        textLayer.contentsScale = UIScreen.main.scale

        let height = ceil(boundingRect.height)
        let width = ceil(min(maxWidth, boundingRect.width))
        let x = (renderSize.width - width) / 2
        let y = calculateYPosition(
            for: position,
            height: height,
            renderSize: renderSize,
            margin: margin,
            extraOffset: extraOffset
        )
        textLayer.frame = CGRect(x: x, y: y, width: width, height: height)

        if usesShadow {
            textLayer.shadowColor = UIColor.black.cgColor
            textLayer.shadowOpacity = 0.6
            textLayer.shadowRadius = 3
            textLayer.shadowOffset = CGSize(width: 0, height: 1)
        }

        switch background {
        case .none:
            return textLayer
        case .translucent, .solid:
            let bgLayer = CALayer()
            bgLayer.frame = textLayer.frame.insetBy(dx: -padding, dy: -padding)
            bgLayer.backgroundColor = (background == .solid ? UIColor.black : UIColor.black.withAlphaComponent(0.5)).cgColor
            bgLayer.cornerRadius = 10
            let container = CALayer()
            container.frame = CGRect(origin: .zero, size: renderSize)
            container.addSublayer(bgLayer)
            container.addSublayer(textLayer)
            return container
        }
    }

    private func attributedText(text: String, font: UIFont, lineSpacing: Double) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = lineSpacing
        paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph
            ]
        )
    }

    private func applyTimingAnimation(_ layer: CALayer, cue: SubtitleCue, duration: CMTime) {
        // Start hidden - animation will control visibility
        layer.opacity = 0
        
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        let start = cue.start.seconds
        let end = cue.end.seconds
        let total = max(0.01, duration.seconds)
        
        // Calculate normalized key times
        // Add small epsilon to prevent rounding issues
        let epsilon = 0.0001
        let startNorm = max(0, min(1 - epsilon, start / total))
        let endNorm = max(startNorm + epsilon, min(1, end / total))
        
        // Fade in just before start, fade out just after end
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
        // Use .both to respect both initial and final states of the animation
        animation.fillMode = .both
        layer.add(animation, forKey: "subtitleOpacity")
    }
    
    private func calculateYPosition(
        for position: SubtitlePosition,
        height: CGFloat,
        renderSize: CGSize,
        margin: CGFloat,
        extraOffset: CGFloat
    ) -> CGFloat {
        switch position {
        case .bottom:
            return margin + extraOffset  // From bottom (Y increases downward in video coords)
        case .middle:
            return (renderSize.height - height) / 2 + extraOffset
        case .top:
            return renderSize.height - margin - height - extraOffset  // From top
        }
    }

    private func fontSize(for size: SubtitleFontSize, renderSize: CGSize) -> CGFloat {
        let base = renderSize.height * 0.055
        switch size {
        case .small:
            return base * 0.85
        case .medium:
            return base
        case .large:
            return base * 1.2
        }
    }
}
