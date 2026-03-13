import CoreGraphics
import Foundation

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
    case appleIntelligence

    var id: String { rawValue }
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

enum SubtitlePosition: String, Codable, CaseIterable, Identifiable {
    case top
    case middle
    case bottom

    var id: String { rawValue }
}

struct SubtitleStyle: Codable, Hashable {
    static let minimumVerticalOffset = -20
    static let maximumVerticalOffset = 20
    private static let verticalOffsetStepFraction: CGFloat = 0.012
    private static let minimumVerticalOffsetDistance: CGFloat = 6

    var fontSize: SubtitleFontSize = .medium
    var background: SubtitleBackground = .translucent
    var secondaryStyle: SubtitleSecondaryStyle = .subdued
    var usesShadow: Bool = true
    var padding: Double = 4
    var lineSpacing: Double = 2
    var position: SubtitlePosition = .bottom
    var primaryVerticalOffset: Int = 0
    var secondaryVerticalOffset: Int = 0

    init() {}

    func primaryVerticalOffsetDistance(in renderSize: CGSize) -> CGFloat {
        guard renderSize.height > 0 else { return 0 }
        let stepDistance = max(Self.minimumVerticalOffsetDistance, renderSize.height * Self.verticalOffsetStepFraction)
        return CGFloat(primaryVerticalOffset) * stepDistance
    }

    func secondaryVerticalOffsetDistance(in renderSize: CGSize) -> CGFloat {
        guard renderSize.height > 0 else { return 0 }
        let stepDistance = max(Self.minimumVerticalOffsetDistance, renderSize.height * Self.verticalOffsetStepFraction)
        return CGFloat(secondaryVerticalOffset) * stepDistance
    }

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
