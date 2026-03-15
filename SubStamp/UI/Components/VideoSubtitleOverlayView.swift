import SwiftUI

/// Live (non-burned) subtitle overlay for previewing timing + style.
///
/// Layout is derived from the same calculator used by the export renderer so
/// inline preview, fullscreen preview, and the burned-in output stay aligned.
struct VideoSubtitleOverlayView: View {
    let primaryText: String
    let secondaryText: String?
    let style: SubtitleStyle
    let videoRenderSize: CGSize?
    let displayedVideoRect: CGRect?

    var body: some View {
        GeometryReader { proxy in
            let containerSize = proxy.size
            let videoRect = resolvedVideoRect(in: containerSize)
            let layout = SubtitleLayoutCalculator.makeCueLayout(
                primaryText: primaryText,
                secondaryText: secondaryText,
                style: style,
                renderSize: videoRect.size
            )

            ZStack(alignment: .topLeading) {
                subtitleLine(layout.primary, background: layout.background, lineSpacing: layout.lineSpacing)
                    .position(
                        x: videoRect.minX + layout.primary.outerFrame.midX,
                        y: videoRect.minY + layout.primary.outerFrame.midY
                    )

                if let secondary = layout.secondary {
                    subtitleLine(secondary, background: layout.background, lineSpacing: layout.lineSpacing)
                        .position(
                            x: videoRect.minX + secondary.outerFrame.midX,
                            y: videoRect.minY + secondary.outerFrame.midY
                        )
                }
            }
            .frame(width: containerSize.width, height: containerSize.height)
        }
        .allowsHitTesting(false)
    }

    private func subtitleLine(
        _ line: SubtitleLineLayout,
        background: SubtitleBackground,
        lineSpacing: Double
    ) -> some View {
        let innerWidth = line.innerSize.width
        let innerHeight = line.innerSize.height

        return Text(line.text)
            .font(.system(size: line.font.pointSize, weight: Font.Weight(line.font.weight)))
            .foregroundStyle(Color(uiColor: line.color).opacity(line.opacity))
            .multilineTextAlignment(.center)
            .lineSpacing(lineSpacing)
            .shadow(
                color: style.usesShadow ? Color.black.opacity(0.6) : .clear,
                radius: style.usesShadow ? 3 : 0,
                x: 0,
                y: style.usesShadow ? 1 : 0
            )
            .frame(width: innerWidth, height: innerHeight, alignment: .center)
            .padding(.horizontal, line.padding)
            .padding(.vertical, line.padding)
            .background(backgroundView(background))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .frame(width: line.outerFrame.width, height: line.outerFrame.height, alignment: .center)
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

    private func resolvedVideoRect(in containerSize: CGSize) -> CGRect {
        if let displayedVideoRect,
           !displayedVideoRect.isEmpty,
           displayedVideoRect.width > 0,
           displayedVideoRect.height > 0 {
            return displayedVideoRect
        }

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

private extension Font.Weight {
    init(_ uiWeight: UIFont.Weight) {
        switch uiWeight {
        case .ultraLight: self = .ultraLight
        case .thin: self = .thin
        case .light: self = .light
        case .regular: self = .regular
        case .medium: self = .medium
        case .semibold: self = .semibold
        case .bold: self = .bold
        case .heavy: self = .heavy
        case .black: self = .black
        default: self = .regular
        }
    }
}

private extension UIFont {
    var weight: UIFont.Weight {
        let traits = fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
        let raw = traits?[.weight] as? CGFloat ?? UIFont.Weight.regular.rawValue
        return UIFont.Weight(raw)
    }
}
