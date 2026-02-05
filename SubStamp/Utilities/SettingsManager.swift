import Combine
import SwiftUI

/// Manages user preferences for display language and appearance (dark/light mode).
/// Inject as `@EnvironmentObject` from the app root.
final class SettingsManager: ObservableObject {
    // MARK: - Keys
    private static let displayLanguageKey = "settings_displayLanguage"
    private static let appearanceModeKey = "settings_appearanceMode"

    // MARK: - Published properties

    /// `nil` means "follow system". Otherwise a BCP-47 identifier: "en", "zh-Hans", "ko".
    @Published var displayLanguage: String? {
        didSet { Self.save(displayLanguage, forKey: Self.displayLanguageKey) }
    }

    /// `nil` means "follow system". `.light` or `.dark` for explicit override.
    @Published var appearanceMode: ColorScheme? {
        didSet { Self.saveAppearance(appearanceMode) }
    }

    // MARK: - Computed helpers

    /// The `Locale` that should override the environment, or `nil` for system default.
    var overrideLocale: Locale? {
        guard let lang = displayLanguage else { return nil }
        return Locale(identifier: lang)
    }

    // MARK: - Supported display languages (shown in the menu)

    struct DisplayLanguageOption: Identifiable {
        let id: String?        // nil = system
        let label: String       // Always shown in the language's own script
        let nativeLabel: String // Short label for the menu
    }

    static let supportedDisplayLanguages: [DisplayLanguageOption] = [
        DisplayLanguageOption(id: nil, label: "System Default", nativeLabel: "System"),
        DisplayLanguageOption(id: "en", label: "English", nativeLabel: "English"),
        DisplayLanguageOption(id: "zh-Hans", label: "简体中文", nativeLabel: "简体中文"),
        DisplayLanguageOption(id: "ko", label: "한국어", nativeLabel: "한국어"),
    ]

    // MARK: - Init

    init() {
        self.displayLanguage = Self.loadDisplayLanguage()
        self.appearanceMode = Self.loadAppearance()
    }

    // MARK: - Persistence

    private static func loadDisplayLanguage() -> String? {
        UserDefaults.standard.string(forKey: displayLanguageKey)
    }

    private static func save(_ value: String?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private static func loadAppearance() -> ColorScheme? {
        guard let raw = UserDefaults.standard.string(forKey: appearanceModeKey) else { return nil }
        switch raw {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    private static func saveAppearance(_ scheme: ColorScheme?) {
        switch scheme {
        case .light:
            UserDefaults.standard.set("light", forKey: appearanceModeKey)
        case .dark:
            UserDefaults.standard.set("dark", forKey: appearanceModeKey)
        default:
            UserDefaults.standard.removeObject(forKey: appearanceModeKey)
        }
    }
}
