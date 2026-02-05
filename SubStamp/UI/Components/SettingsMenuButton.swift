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
                Label("Display Language", systemImage: "globe")
            }

            Divider()

            // MARK: - Appearance
            Menu {
                Button {
                    settingsManager.appearanceMode = nil
                } label: {
                    HStack {
                        Text("System")
                        if settingsManager.appearanceMode == nil {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                Button {
                    settingsManager.appearanceMode = .light
                } label: {
                    HStack {
                        Text("Light")
                        if settingsManager.appearanceMode == .light {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                Button {
                    settingsManager.appearanceMode = .dark
                } label: {
                    HStack {
                        Text("Dark")
                        if settingsManager.appearanceMode == .dark {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            } label: {
                Label("Appearance", systemImage: "moon.circle")
            }
        } label: {
            Image(systemName: "gearshape")
                .font(AppTypography.bodyEmphasis)
                .foregroundStyle(AppColors.secondaryText)
        }
    }
}
