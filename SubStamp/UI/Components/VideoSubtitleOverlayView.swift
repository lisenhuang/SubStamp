import SwiftUI

/// Live (non-burned) subtitle overlay for previewing timing + style.
///
/// This is intentionally lightweight and uses the same size/position heuristics as `SubtitleRenderer`.
struct VideoSubtitleOverlayView: View {
    let primaryText: String
    let secondaryText: String?
    let style: SubtitleStyle
    let videoRenderSize: CGSize?

    var body: some View {
        GeometryReader { proxy in
            let containerSize = proxy.size
            let videoRect = displayedVideoRect(in: containerSize)
            let margin = max(12, videoRect.height * 0.06)
            let maxWidth = videoRect.width * 0.86
            let baseFontSize = fontSize(for: style.fontSize, in: videoRect.size)
            let background: SubtitleBackground = style.usesShadow ? .translucent : .none

            ZStack {
                positionedContainer(in: videoRect, position: style.position, margin: margin) {
                    VStack(spacing: margin * 0.12) {
                        subtitleLine(
                            primaryText,
                            fontSize: baseFontSize,
                            weight: .semibold,
                            opacity: 1,
                            background: background
                        )

                        if let secondaryText, !secondaryText.isEmpty {
                            let secondaryOpacity: Double = (style.secondaryStyle == .subdued) ? 0.85 : 1
                            let secondaryWeight: Font.Weight = (style.secondaryStyle == .subdued) ? .regular : .semibold
                            subtitleLine(
                                secondaryText,
                                fontSize: baseFontSize,
                                weight: secondaryWeight,
                                opacity: secondaryOpacity,
                                background: background
                            )
                        }
                    }
                    .frame(maxWidth: maxWidth)
                    .padding(.horizontal, (videoRect.width - maxWidth) / 2)
                }
            }
            .frame(width: containerSize.width, height: containerSize.height)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func positionedContainer<Content: View>(
        in videoRect: CGRect,
        position: SubtitlePosition,
        margin: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ZStack {
            switch position {
            case .top:
                VStack {
                    content()
                        .padding(.top, margin)
                    Spacer(minLength: 0)
                }
            case .middle:
                VStack {
                    Spacer(minLength: 0)
                    content()
                    Spacer(minLength: 0)
                }
            case .bottom:
                VStack {
                    Spacer(minLength: 0)
                    content()
                        .padding(.bottom, margin)
                }
            }
        }
        .frame(width: videoRect.width, height: videoRect.height)
        .position(x: videoRect.midX, y: videoRect.midY)
    }

    private func subtitleLine(
        _ text: String,
        fontSize: CGFloat,
        weight: Font.Weight,
        opacity: Double,
        background: SubtitleBackground
    ) -> some View {
        let padding: CGFloat = 4

        return Text(text)
            .font(.system(size: fontSize, weight: weight))
            .foregroundStyle(Color.white.opacity(opacity))
            .multilineTextAlignment(.center)
            .lineSpacing(style.lineSpacing)
            .shadow(
                color: style.usesShadow ? Color.black.opacity(0.6) : .clear,
                radius: style.usesShadow ? 3 : 0,
                x: 0,
                y: style.usesShadow ? 1 : 0
            )
            .padding(.horizontal, padding)
            .padding(.vertical, padding)
            .background(backgroundView(background))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func backgroundView(_ background: SubtitleBackground) -> some View {
        switch background {
        case .none:
            EmptyView()
        case .translucent:
            Color.black.opacity(0.5)
        case .solid:
            Color.black
        }
    }

    private func fontSize(for size: SubtitleFontSize, in renderSize: CGSize) -> CGFloat {
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

    private func displayedVideoRect(in containerSize: CGSize) -> CGRect {
        guard containerSize.width > 0, containerSize.height > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }

        guard let videoRenderSize,
              videoRenderSize.width > 0,
              videoRenderSize.height > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }

        let scale = min(containerSize.width / videoRenderSize.width, containerSize.height / videoRenderSize.height)
        let fittedSize = CGSize(
            width: videoRenderSize.width * scale,
            height: videoRenderSize.height * scale
        )
        let origin = CGPoint(
            x: (containerSize.width - fittedSize.width) / 2,
            y: (containerSize.height - fittedSize.height) / 2
        )
        return CGRect(origin: origin, size: fittedSize)
    }
}
