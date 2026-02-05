import Foundation

extension Bundle {
    /// Returns a bundle for the specified locale's `.lproj`, falling back to the main bundle.
    ///
    /// Use this with `String(localized:bundle:)` to resolve translations for the
    /// user-selected display language instead of the device language.
    ///
    ///     let bundle = Bundle.forLocale(locale) // locale from @Environment(\.locale)
    ///     let text = String(localized: "Cancel", bundle: bundle) // → "取消" when zh-Hans
    ///
    static func forLocale(_ locale: Locale) -> Bundle {
        // Try full identifier first (e.g. "zh-Hans")
        let identifier = locale.identifier
        if let path = Bundle.main.path(forResource: identifier, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        // Try language code only (e.g. "en", "ko")
        if let langCode = locale.language.languageCode?.identifier,
           langCode != identifier,
           let path = Bundle.main.path(forResource: langCode, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        return .main
    }
}
