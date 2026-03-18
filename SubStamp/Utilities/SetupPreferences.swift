import Foundation

/// Persists step 1 selections so they are restored on next launch.
enum SetupPreferences {
    private static let transcriptionKey = "setup_transcriptionLocale"
    private static let subtitleModeKey = "setup_subtitleMode"
    private static let translationTargetKey = "setup_translationTarget"
    private static let translationProviderKey = "setup_translationProvider"
    private static let fixTranscriptionWithAppleIntelligenceKey = "setup_fixTranscriptionWithAppleIntelligence"
    private static let subtitleStyleKey = "setup_subtitleStyle"
    private static let language1Key = "setup_language1"
    private static let language2Key = "setup_language2"
    static let projectAutosaveKey = "projects_autoSave"

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

    static func loadTranslationProvider() -> TranslationProvider? {
        guard let raw = UserDefaults.standard.string(forKey: translationProviderKey) else { return nil }
        return TranslationProvider(rawValue: raw)
    }

    static func loadFixTranscriptionWithAppleIntelligence() -> Bool {
        if UserDefaults.standard.object(forKey: fixTranscriptionWithAppleIntelligenceKey) == nil {
            // Default OFF: only enable if the user explicitly opts in.
            return false
        }
        return UserDefaults.standard.bool(forKey: fixTranscriptionWithAppleIntelligenceKey)
    }

    static func save(
        transcriptionLocale: String,
        subtitleMode: SubtitleMode,
        translationTarget: String?,
        translationProvider: TranslationProvider,
        fixTranscriptionWithAppleIntelligence: Bool
    ) {
        UserDefaults.standard.set(transcriptionLocale, forKey: transcriptionKey)
        UserDefaults.standard.set(subtitleMode.rawValue, forKey: subtitleModeKey)
        UserDefaults.standard.set(translationTarget, forKey: translationTargetKey)
        UserDefaults.standard.set(translationProvider.rawValue, forKey: translationProviderKey)
        if translationProvider == .appleIntelligence {
            UserDefaults.standard.set(fixTranscriptionWithAppleIntelligence, forKey: fixTranscriptionWithAppleIntelligenceKey)
        }
    }
    
    // MARK: - Subtitle Style Persistence
    
    static func loadSubtitleStyle() -> SubtitleStyle {
        guard let data = UserDefaults.standard.data(forKey: subtitleStyleKey),
              let style = try? JSONDecoder().decode(SubtitleStyle.self, from: data) else {
            return SubtitleStyle() // Return default style
        }
        return style
    }
    
    static func saveSubtitleStyle(_ style: SubtitleStyle) {
        if let data = try? JSONEncoder().encode(style) {
            UserDefaults.standard.set(data, forKey: subtitleStyleKey)
        }
    }
    
    // MARK: - Language 1 & 2 Persistence
    
    static func loadLanguage1() -> String? {
        UserDefaults.standard.string(forKey: language1Key)
    }
    
    static func loadLanguage2() -> String? {
        UserDefaults.standard.string(forKey: language2Key)
    }
    
    static func saveLanguages(language1: String, language2: String?) {
        UserDefaults.standard.set(language1, forKey: language1Key)
        UserDefaults.standard.set(language2, forKey: language2Key)
    }

    static func loadProjectAutosave() -> Bool {
        if UserDefaults.standard.object(forKey: projectAutosaveKey) == nil {
            return false
        }
        return UserDefaults.standard.bool(forKey: projectAutosaveKey)
    }

    static func saveProjectAutosave(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: projectAutosaveKey)
    }
}
