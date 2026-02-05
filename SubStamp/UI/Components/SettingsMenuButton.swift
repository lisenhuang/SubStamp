import SwiftUI

/// A gear-icon button that opens a dropdown menu with display language and appearance settings.
struct SettingsMenuButton: View {
    @EnvironmentObject private var settingsManager: SettingsManager

    var body: some View {
        Menu {
            // MARK: - Display Language
            Menu {
                ForEach(SettingsManager.supportedDisplayLanguages) { option in
                    Button {
                        settingsManager.displayLanguage = option.id
                    } label: {
                        HStack {
                            Text(option.label)
                            if settingsManager.displayLanguage == option.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Label(String(localized: "Display Language", table: nil, bundle: .main, comment: "Settings menu: display language section"),
                      systemImage: "globe")
            }

            Divider()

            // MARK: - Appearance
            Menu {
                Button {
                    settingsManager.appearanceMode = nil
                } label: {
                    HStack {
                        Text(String(localized: "System", table: nil, bundle: .main, comment: "Appearance: follow system"))
                        if settingsManager.appearanceMode == nil {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                Button {
                    settingsManager.appearanceMode = .light
                } label: {
                    HStack {
                        Text(String(localized: "Light", table: nil, bundle: .main, comment: "Appearance: light mode"))
                        if settingsManager.appearanceMode == .light {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                Button {
                    settingsManager.appearanceMode = .dark
                } label: {
                    HStack {
                        Text(String(localized: "Dark", table: nil, bundle: .main, comment: "Appearance: dark mode"))
                        if settingsManager.appearanceMode == .dark {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            } label: {
                Label(String(localized: "Appearance", table: nil, bundle: .main, comment: "Settings menu: appearance section"),
                      systemImage: "moon.circle")
            }
        } label: {
            Image(systemName: "gearshape")
                .font(AppTypography.bodyEmphasis)
                .foregroundStyle(AppColors.secondaryText)
        }
    }
}
