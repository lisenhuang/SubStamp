import AVFoundation
import UIKit

final class SubtitleRenderer {
    private struct CueStats {
        let primaryChars: Int
        let secondaryChars: Int
        let bilingualCueCount: Int
        let maxCueChars: Int
        let maxCueDuration: Double
    }

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
        timeRange: CMTimeRange? = nil,
        preserveSourceFrameRate: Bool = false
    ) async throws -> RenderResult {
        let composition = AVMutableComposition()
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw SubStampError.exportFailed(underlying: NSError(domain: "SubStamp", code: -4))
        }

        let videoCompositionTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )
        let assetDuration = try await asset.load(.duration)
        let sourceRange = timeRange ?? CMTimeRange(start: .zero, duration: assetDuration)
        let timelineRange = CMTimeRange(start: .zero, duration: sourceRange.duration)
        try videoCompositionTrack?.insertTimeRange(sourceRange, of: videoTrack, at: .zero)

        if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first {
            let audioCompositionTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
            try audioCompositionTrack?.insertTimeRange(sourceRange, of: audioTrack, at: .zero)
        }

        let videoComposition = AVMutableVideoComposition()
        let sourceNominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        let sourceMinFrameDuration = try await videoTrack.load(.minFrameDuration)
        videoComposition.frameDuration = Self.frameDuration(
            nominalFrameRate: preserveSourceFrameRate ? sourceNominalFrameRate : 0,
            minFrameDuration: preserveSourceFrameRate ? sourceMinFrameDuration : .invalid
        )

        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transformedSize = naturalSize.applying(preferredTransform)
        let transformedWidth = abs(transformedSize.width)
        let transformedHeight = abs(transformedSize.height)
        let fallbackWidth = abs(naturalSize.width)
        let fallbackHeight = abs(naturalSize.height)
        let safeWidth = max(1, round(transformedWidth > 0 ? transformedWidth : fallbackWidth))
        let safeHeight = max(1, round(transformedHeight > 0 ? transformedHeight : fallbackHeight))
        let renderSize = CGSize(width: safeWidth, height: safeHeight)
        videoComposition.renderSize = renderSize

        let stats = cueStats(for: cues)
        AppLog.append(
            "[RENDER] start range=\(formatTimeRange(sourceRange)) cues=\(cues.count) mode=\(mode.rawValue) layout=\(layout.rawValue) style=\(describe(style: style)) natural=\(format(size: naturalSize)) transformed=\(format(size: CGSize(width: transformedWidth, height: transformedHeight))) render=\(format(size: renderSize)) sourceFPS=\(String(format: "%.3f", sourceNominalFrameRate)) preserveFPS=\(preserveSourceFrameRate)"
        )
        AppLog.append(
            "[RENDER] cue-stats primaryChars=\(stats.primaryChars) secondaryChars=\(stats.secondaryChars) bilingualCues=\(stats.bilingualCueCount) maxCueChars=\(stats.maxCueChars) maxCueDuration=\(String(format: "%.2f", stats.maxCueDuration))"
        )

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

        AppLog.append("[RENDER] overlay-built layers=\(overlayLayers.count) timelineDuration=\(String(format: "%.2f", timelineRange.duration.seconds))s")

        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parentLayer
        )

        AppLog.append("[RENDER] ready instructions=\(videoComposition.instructions.count) frameDuration=\(String(format: "%.4f", videoComposition.frameDuration.seconds))s")

        return RenderResult(composition: composition, videoComposition: videoComposition, renderSize: renderSize)
    }

    nonisolated static func frameDuration(nominalFrameRate: Float, minFrameDuration: CMTime) -> CMTime {
        if let duration = frameDuration(forFramesPerSecond: Double(nominalFrameRate)) {
            return duration
        }

        if minFrameDuration.isValid,
           minFrameDuration.isNumeric,
           minFrameDuration.seconds.isFinite,
           let duration = frameDuration(forFramesPerSecond: 1 / minFrameDuration.seconds) {
            return duration
        }

        return CMTime(value: 1, timescale: 30)
    }

    nonisolated private static func frameDuration(forFramesPerSecond framesPerSecond: Double) -> CMTime? {
        guard framesPerSecond.isFinite,
              framesPerSecond >= 1,
              framesPerSecond <= 240 else {
            return nil
        }

        let timescale: Int32 = 60_000
        let value = max(1, Int64((Double(timescale) / framesPerSecond).rounded()))
        return CMTime(value: value, timescale: timescale)
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
            color: line.color,
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

    private func attributedText(
        text: String,
        font: UIFont,
        lineSpacing: Double,
        color: UIColor,
        opacity: CGFloat
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = lineSpacing
        paragraph.lineBreakMode = .byWordWrapping

        return NSAttributedString(
            string: SubtitleTextCleaner.clean(text),
            attributes: [
                .font: font,
                .foregroundColor: color.withAlphaComponent(opacity),
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

    private func cueStats(for cues: [SubtitleCue]) -> CueStats {
        var primaryChars = 0
        var secondaryChars = 0
        var bilingualCueCount = 0
        var maxCueChars = 0
        var maxCueDuration = 0.0

        for cue in cues {
            let primary = cue.primaryText.count
            let secondary = cue.secondaryText?.count ?? 0
            primaryChars += primary
            secondaryChars += secondary
            if secondary > 0 {
                bilingualCueCount += 1
            }
            maxCueChars = max(maxCueChars, primary + secondary)
            maxCueDuration = max(maxCueDuration, max(0, cue.end.seconds - cue.start.seconds))
        }

        return CueStats(
            primaryChars: primaryChars,
            secondaryChars: secondaryChars,
            bilingualCueCount: bilingualCueCount,
            maxCueChars: maxCueChars,
            maxCueDuration: maxCueDuration
        )
    }

    private func format(size: CGSize) -> String {
        "\(Int(round(size.width)))x\(Int(round(size.height)))"
    }

    private func formatTimeRange(_ range: CMTimeRange) -> String {
        let start = String(format: "%.2f", range.start.seconds)
        let duration = String(format: "%.2f", range.duration.seconds)
        let end = String(format: "%.2f", range.end.seconds)
        return "\(start)-\(end)s duration=\(duration)s"
    }

    private func describe(style: SubtitleStyle) -> String {
        let red = Int(round(style.textColor.red * 255))
        let green = Int(round(style.textColor.green * 255))
        let blue = Int(round(style.textColor.blue * 255))
        return "font=\(style.fontSize.rawValue) color=#\(String(format: "%02X%02X%02X", red, green, blue)) bg=\(style.background.rawValue) shadow=\(style.usesShadow) pos=\(style.position.rawValue) pOffset=\(style.primaryVerticalOffset) sOffset=\(style.secondaryVerticalOffset)"
    }
}
