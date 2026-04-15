import Combine
import SwiftUI

/// Developer-only settings for testing legacy code paths on iOS 26+.
/// Access the dev page via 16 consecutive taps on the "Settings" title (iOS 26+ only).
final class DevSettings: ObservableObject {

    // MARK: - Singleton
    static let shared = DevSettings()

    // MARK: - Keys
    private static let forceLegacyModeKey = "developer_forceLegacyMode"

    // MARK: - Published properties

    /// When true, all `#available(iOS 26.0, *)` feature branches behave as if running
    /// on iOS 18, even on a real iOS 26+ device.
    @Published var forceLegacyMode: Bool {
        didSet { UserDefaults.standard.set(forceLegacyMode, forKey: Self.forceLegacyModeKey) }
    }

    // MARK: - Computed helpers

    /// Returns `true` only when the real device is iOS 26+ AND `forceLegacyMode` is off.
    ///
    /// Reads directly from `UserDefaults` so it is safe to call from any actor context.
    /// Usage at call sites:
    /// ```swift
    /// if #available(iOS 26.0, *), DevSettings.useModernAPIs { ... }
    /// ```
    static var useModernAPIs: Bool {
        if #available(iOS 26.0, *) {
            return !UserDefaults.standard.bool(forKey: forceLegacyModeKey)
        }
        return false
    }

    // MARK: - Init (private — use .shared)
    private init() {
        self.forceLegacyMode = UserDefaults.standard.bool(forKey: Self.forceLegacyModeKey)
    }
}
