import Foundation

/// Persists step 1 selections so they are restored on next launch.
enum SetupPreferences {
    private static let transcriptionKey = "setup_transcriptionLocale"
    private static let subtitleModeKey = "setup_subtitleMode"
    private static let translationTargetKey = "setup_translationTarget"

    static func loadTranscriptionLocale() -> String? {
        UserDefaults.standard.string(forKey: transcriptionKey)
    }

    static func loadSubtitleMode() -> SubtitleMode? {
        guard let raw = UserDefaults.standard.string(forKey: subtitleModeKey) else { return nil }
        return SubtitleMode(rawValue: raw)
    }

    static func loadTranslationTarget() -> String? {
        UserDefaults.standard.string(forKey: translationTargetKey)
    }

    static func save(transcriptionLocale: String, subtitleMode: SubtitleMode, translationTarget: String?) {
        UserDefaults.standard.set(transcriptionLocale, forKey: transcriptionKey)
        UserDefaults.standard.set(subtitleMode.rawValue, forKey: subtitleModeKey)
        UserDefaults.standard.set(translationTarget, forKey: translationTargetKey)
    }
}
