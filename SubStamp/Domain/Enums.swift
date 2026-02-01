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
    var fontSize: SubtitleFontSize = .medium
    var background: SubtitleBackground = .translucent
    var secondaryStyle: SubtitleSecondaryStyle = .subdued
    var usesShadow: Bool = true
    var padding: Double = 10
    var lineSpacing: Double = 2
    var position: SubtitlePosition = .bottom
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
