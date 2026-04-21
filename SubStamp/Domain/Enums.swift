import Foundation
import UIKit

enum SubtitleMode: String, Codable, CaseIterable, Identifiable {
    case single
    case bilingual

    var id: String { rawValue }
}

enum SubtitleLayout: String, Codable, CaseIterable, Identifiable {
    case single
    case stacked

    var id: String { rawValue }
}

enum ProcessingStage: String, Codable, CaseIterable, Identifiable {
    case idle
    case assets
    case transcribing
    case translating
    case rendering
    case exporting
    case completed

    var id: String { rawValue }
}

enum PipelineStageState: String, Codable, CaseIterable {
    case pending
    case active
    case done
    case failed
}

enum AssetState: Equatable {
    case notInstalled
    case downloading(progress: Double)
    case ready
    case failed(message: String)
}

enum ExportPreset: String, Codable, CaseIterable, Identifiable {
    case fast
    case balanced
    case best

    var id: String { rawValue }
}

enum TranslationProvider: String, Codable, CaseIterable, Identifiable {
    case translationFramework

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = TranslationProvider(rawValue: rawValue) ?? .translationFramework
    }
}

enum SubtitleFontSize: String, Codable, CaseIterable, Identifiable {
    case small
    case medium
    case large

    var id: String { rawValue }
}

enum SubtitleBackground: String, Codable, CaseIterable, Identifiable {
    case none
    case translucent
    case solid

    var id: String { rawValue }
}

enum SubtitleSecondaryStyle: String, Codable, CaseIterable, Identifiable {
    case subdued
    case equal

    var id: String { rawValue }
}

enum SubtitleTextColor: String, Codable, CaseIterable, Identifiable {
    case white
    case yellow
    case cyan
    case green
    case pink

    var id: String { rawValue }

    var subtitleColor: SubtitleColor {
        switch self {
        case .white:
            return .white
        case .yellow:
            return SubtitleColor(uiColor: UIColor(red: 1.0, green: 0.91, blue: 0.35, alpha: 1.0))
        case .cyan:
            return SubtitleColor(uiColor: UIColor(red: 0.46, green: 0.94, blue: 1.0, alpha: 1.0))
        case .green:
            return SubtitleColor(uiColor: UIColor(red: 0.56, green: 0.98, blue: 0.55, alpha: 1.0))
        case .pink:
            return SubtitleColor(uiColor: UIColor(red: 1.0, green: 0.64, blue: 0.86, alpha: 1.0))
        }
    }
}

struct SubtitleColor: Codable, Hashable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    static let white = SubtitleColor(red: 1, green: 1, blue: 1, alpha: 1)

    init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(uiColor: UIColor) {
        let resolved = uiColor.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var red: CGFloat = 1
        var green: CGFloat = 1
        var blue: CGFloat = 1
        var alpha: CGFloat = 1

        if !resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha),
           let components = resolved.cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components,
           components.count >= 4 {
            red = components[0]
            green = components[1]
            blue = components[2]
            alpha = components[3]
        }

        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    var uiColor: UIColor {
        UIColor(
            red: red,
            green: green,
            blue: blue,
            alpha: alpha
        )
    }
}

enum SubtitlePosition: String, Codable, CaseIterable, Identifiable {
    case top
    case middle
    case bottom

    var id: String { rawValue }
}

struct SubtitleStyle: Codable, Hashable {
    static let minimumVerticalOffset = -20
    static let maximumVerticalOffset = 20

    var fontSize: SubtitleFontSize = .medium
    var textColor: SubtitleColor = .white
    var background: SubtitleBackground = .translucent
    var secondaryStyle: SubtitleSecondaryStyle = .subdued
    var usesShadow: Bool = true
    var padding: Double = 4
    var lineSpacing: Double = 2
    var position: SubtitlePosition = .bottom
    var primaryVerticalOffset: Int = 0
    var secondaryVerticalOffset: Int = 0

    init() {}

    func adjustingPrimaryVerticalOffset(by delta: Int) -> SubtitleStyle {
        var updated = self
        updated.primaryVerticalOffset = Self.clampedVerticalOffset(updated.primaryVerticalOffset + delta)
        return updated
    }

    func adjustingSecondaryVerticalOffset(by delta: Int) -> SubtitleStyle {
        var updated = self
        updated.secondaryVerticalOffset = Self.clampedVerticalOffset(updated.secondaryVerticalOffset + delta)
        return updated
    }

    enum CodingKeys: String, CodingKey {
        case fontSize
        case textColor
        case primaryTextColor
        case secondaryTextColor
        case background
        case secondaryStyle
        case usesShadow
        case padding
        case lineSpacing
        case position
        case primaryVerticalOffset
        case secondaryVerticalOffset
        case verticalOffset
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fontSize = try container.decodeIfPresent(SubtitleFontSize.self, forKey: .fontSize) ?? .medium
        let legacyPrimaryTextColor = try container.decodeIfPresent(SubtitleTextColor.self, forKey: .primaryTextColor)
        let legacySecondaryTextColor = try container.decodeIfPresent(SubtitleTextColor.self, forKey: .secondaryTextColor)
        textColor = try container.decodeIfPresent(SubtitleColor.self, forKey: .textColor)
            ?? legacyPrimaryTextColor?.subtitleColor
            ?? legacySecondaryTextColor?.subtitleColor
            ?? .white
        background = try container.decodeIfPresent(SubtitleBackground.self, forKey: .background) ?? .translucent
        secondaryStyle = try container.decodeIfPresent(SubtitleSecondaryStyle.self, forKey: .secondaryStyle) ?? .subdued
        usesShadow = try container.decodeIfPresent(Bool.self, forKey: .usesShadow) ?? true
        padding = try container.decodeIfPresent(Double.self, forKey: .padding) ?? 4
        lineSpacing = try container.decodeIfPresent(Double.self, forKey: .lineSpacing) ?? 2
        position = try container.decodeIfPresent(SubtitlePosition.self, forKey: .position) ?? .bottom
        let legacyOffset = Self.clampedVerticalOffset(try container.decodeIfPresent(Int.self, forKey: .verticalOffset) ?? 0)
        primaryVerticalOffset = Self.clampedVerticalOffset(
            try container.decodeIfPresent(Int.self, forKey: .primaryVerticalOffset) ?? legacyOffset
        )
        secondaryVerticalOffset = Self.clampedVerticalOffset(
            try container.decodeIfPresent(Int.self, forKey: .secondaryVerticalOffset) ?? legacyOffset
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fontSize, forKey: .fontSize)
        try container.encode(textColor, forKey: .textColor)
        try container.encode(background, forKey: .background)
        try container.encode(secondaryStyle, forKey: .secondaryStyle)
        try container.encode(usesShadow, forKey: .usesShadow)
        try container.encode(padding, forKey: .padding)
        try container.encode(lineSpacing, forKey: .lineSpacing)
        try container.encode(position, forKey: .position)
        try container.encode(primaryVerticalOffset, forKey: .primaryVerticalOffset)
        try container.encode(secondaryVerticalOffset, forKey: .secondaryVerticalOffset)
    }

    private static func clampedVerticalOffset(_ value: Int) -> Int {
        min(maximumVerticalOffset, max(minimumVerticalOffset, value))
    }
}

enum SubStampError: LocalizedError {
    case assetInstallFailed(locale: String)
    case unsupportedLanguagePair(from: String, to: String)
    case noAudioTrack
    case speechAnalyzerError(underlying: Error)
    case translationError(underlying: Error)
    case exportFailed(underlying: Error)
    case insufficientStorage
    case backgroundTaskCancelled
    case jobNotFound(id: UUID)

    var errorDescription: String? {
        switch self {
        case .assetInstallFailed:
            return "Unable to install required language assets."
        case .unsupportedLanguagePair:
            return "This language pair isn't supported for translation."
        case .noAudioTrack:
            return "The selected video doesn't contain an audio track."
        case .speechAnalyzerError:
            return "Speech analysis failed."
        case .translationError:
            return "Translation failed."
        case .exportFailed:
            return "Export failed."
        case .insufficientStorage:
            return "Not enough storage available."
        case .backgroundTaskCancelled:
            return "Background processing was cancelled."
        case .jobNotFound:
            return "We couldn't find the saved job to resume."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .assetInstallFailed:
            return "Check storage and try downloading again."
        case .unsupportedLanguagePair:
            return "Choose a different translation language."
        case .noAudioTrack:
            return "Pick a different video or record one with audio."
        case .speechAnalyzerError:
            return "Try again or switch the transcription language."
        case .translationError:
            return "Retry translation or continue with transcript only."
        case .exportFailed:
            return "Try exporting again or choose a lower quality preset."
        case .insufficientStorage:
            return "Free up space and retry."
        case .backgroundTaskCancelled:
            return "Resume processing from the last checkpoint."
        case .jobNotFound:
            return "Start a new project."
        }
    }
}
