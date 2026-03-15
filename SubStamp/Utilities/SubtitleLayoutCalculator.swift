import CoreGraphics
import UIKit

struct SubtitleLineLayout {
    let text: String
    let outerFrame: CGRect // top-based coordinates within the video rect
    let innerSize: CGSize
    let font: UIFont
    let color: UIColor
    let opacity: CGFloat
    let padding: CGFloat
}

struct SubtitleCueLayout {
    let background: SubtitleBackground
    let usesShadow: Bool
    let lineSpacing: Double
    let primary: SubtitleLineLayout
    let secondary: SubtitleLineLayout?
}

enum SubtitleLayoutCalculator {
    static func makeCueLayout(
        primaryText: String,
        secondaryText: String?,
        style: SubtitleStyle,
        renderSize: CGSize
    ) -> SubtitleCueLayout {
        let anchorMargin = max(24, renderSize.height * 0.06)
        let edgeInset: CGFloat = 0
        let baseFontSize = fontSize(for: style.fontSize, renderSize: renderSize)
        let background: SubtitleBackground = style.usesShadow ? .translucent : .none
        let padding: CGFloat = background == .none ? 0 : 4
        let maxOuterWidth = renderSize.width * 0.86
        let maxTextWidth = max(1, maxOuterWidth - (padding * 2))

        let primaryWeight: UIFont.Weight = .semibold
        let primaryFont = UIFont.systemFont(ofSize: baseFontSize, weight: primaryWeight)
        let textColor = style.textColor.uiColor
        let primaryTextSize = measuredTextSize(
            text: primaryText,
            font: primaryFont,
            lineSpacing: style.lineSpacing,
            maxWidth: maxTextWidth
        )
        let primaryOuterSize = CGSize(
            width: primaryTextSize.width + (padding * 2),
            height: primaryTextSize.height + (padding * 2)
        )

        let secondaryWeight: UIFont.Weight = (style.secondaryStyle == .subdued) ? .regular : .semibold
        let secondaryOpacity: CGFloat = (style.secondaryStyle == .subdued) ? 0.85 : 1
        let secondaryFont = UIFont.systemFont(ofSize: baseFontSize, weight: secondaryWeight)
        let secondaryTextSize: CGSize?
        let secondaryOuterSize: CGSize?
        if let secondaryText, !secondaryText.isEmpty {
            let size = measuredTextSize(
                text: secondaryText,
                font: secondaryFont,
                lineSpacing: style.lineSpacing,
                maxWidth: maxTextWidth
            )
            secondaryTextSize = size
            secondaryOuterSize = CGSize(
                width: size.width + (padding * 2),
                height: size.height + (padding * 2)
            )
        } else {
            secondaryTextSize = nil
            secondaryOuterSize = nil
        }

        let gap = (secondaryOuterSize != nil) ? (anchorMargin * 0.1) : 0
        let combinedHeight = primaryOuterSize.height + (secondaryOuterSize?.height ?? 0) + gap
        let containerTop = baseContainerTop(
            for: style.position,
            renderHeight: renderSize.height,
            combinedHeight: combinedHeight,
            margin: anchorMargin
        )

        let primaryBaseTop = containerTop
        let secondaryBaseTop = containerTop + primaryOuterSize.height + gap

        let primaryTop = adjustedTop(
            baseTop: primaryBaseTop,
            offsetValue: style.primaryVerticalOffset,
            minTop: edgeInset,
            maxTop: renderSize.height - edgeInset - primaryOuterSize.height
        )
        let primaryOuterFrame = CGRect(
            x: (renderSize.width - primaryOuterSize.width) / 2,
            y: primaryTop,
            width: primaryOuterSize.width,
            height: primaryOuterSize.height
        )

        let primary = SubtitleLineLayout(
            text: primaryText,
            outerFrame: primaryOuterFrame,
            innerSize: primaryTextSize,
            font: primaryFont,
            color: textColor,
            opacity: 1,
            padding: padding
        )

        let secondary: SubtitleLineLayout?
        if let secondaryText, let secondaryTextSize, let secondaryOuterSize {
            let secondaryTop = adjustedTop(
                baseTop: secondaryBaseTop,
                offsetValue: style.secondaryVerticalOffset,
                minTop: edgeInset,
                maxTop: renderSize.height - edgeInset - secondaryOuterSize.height
            )
            secondary = SubtitleLineLayout(
                text: secondaryText,
                outerFrame: CGRect(
                    x: (renderSize.width - secondaryOuterSize.width) / 2,
                    y: secondaryTop,
                    width: secondaryOuterSize.width,
                    height: secondaryOuterSize.height
                ),
                innerSize: secondaryTextSize,
                font: secondaryFont,
                color: textColor,
                opacity: secondaryOpacity,
                padding: padding
            )
        } else {
            secondary = nil
        }

        return SubtitleCueLayout(
            background: background,
            usesShadow: style.usesShadow,
            lineSpacing: style.lineSpacing,
            primary: primary,
            secondary: secondary
        )
    }

    private static func measuredTextSize(
        text: String,
        font: UIFont,
        lineSpacing: Double,
        maxWidth: CGFloat
    ) -> CGSize {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = lineSpacing
        paragraph.lineBreakMode = .byWordWrapping

        let attributed = NSAttributedString(
            string: SubtitleTextCleaner.clean(text),
            attributes: [
                .font: font,
                .paragraphStyle: paragraph
            ]
        )

        let rect = attributed.boundingRect(
            with: CGSize(width: maxWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )

        return CGSize(
            width: ceil(min(maxWidth, rect.width)),
            height: ceil(rect.height)
        )
    }

    private static func baseContainerTop(
        for position: SubtitlePosition,
        renderHeight: CGFloat,
        combinedHeight: CGFloat,
        margin: CGFloat
    ) -> CGFloat {
        switch position {
        case .top:
            return margin
        case .middle:
            return (renderHeight - combinedHeight) / 2
        case .bottom:
            return renderHeight - margin - combinedHeight
        }
    }

    private static func adjustedTop(
        baseTop: CGFloat,
        offsetValue: Int,
        minTop: CGFloat,
        maxTop: CGFloat
    ) -> CGFloat {
        guard maxTop >= minTop else { return baseTop }
        let clampedValue = max(SubtitleStyle.minimumVerticalOffset, min(SubtitleStyle.maximumVerticalOffset, offsetValue))
        guard clampedValue != 0 else { return baseTop }

        let fraction = min(1, CGFloat(abs(clampedValue)) / CGFloat(SubtitleStyle.maximumVerticalOffset))
        if clampedValue > 0 {
            return baseTop - ((baseTop - minTop) * fraction)
        } else {
            return baseTop + ((maxTop - baseTop) * fraction)
        }
    }

    private static func fontSize(for size: SubtitleFontSize, renderSize: CGSize) -> CGFloat {
        let referenceDimension = (renderSize.width + renderSize.height) / 2
        let base = referenceDimension * 0.03
        switch size {
        case .small:
            return base * 0.8
        case .medium:
            return base
        case .large:
            return base * 1.25
        }
    }
}
