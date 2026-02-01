import SwiftUI

enum AppTypography {
    static let title = Font.system(.largeTitle, design: .rounded).weight(.bold)
    static let headline = Font.system(.title2, design: .rounded).weight(.semibold)
    static let sectionTitle = Font.system(.title3, design: .rounded).weight(.semibold)
    static let body = Font.system(.body, design: .rounded)
    static let bodyEmphasis = Font.system(.body, design: .rounded).weight(.semibold)
    static let caption = Font.system(.caption, design: .rounded)
    static let monospace = Font.system(.footnote, design: .monospaced)
}
