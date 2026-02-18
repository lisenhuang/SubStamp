import SwiftUI

/// A gear-icon button that opens a dropdown menu with display language and appearance settings.
struct SettingsMenuButton: View {
    @EnvironmentObject private var settingsManager: SettingsManager
    @ObservedObject var purchaseManager: PurchaseManager
    @State private var showPaywall = false
    @State private var paywallUsedCount = 0

    var body: some View {
        Menu {
            if purchaseManager.hasCheckedEntitlements && !purchaseManager.hasPremiumAccess {
                Button {
                    Task { @MainActor in
                        paywallUsedCount = await SaveShareQuotaStore.shared.totalUsedCount()
                        showPaywall = true
                    }
                } label: {
                    Label("Upgrade to Pro", systemImage: "crown.fill")
                }

                Divider()
            }

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
        .sheet(isPresented: $showPaywall) {
            PurchasePaywallView(
                purchaseManager: purchaseManager,
                usedCount: paywallUsedCount,
                freeLimit: SaveShareQuotaStore.freeLimit
            ) {}
        }
        .task {
            await purchaseManager.prepareEntitlementsIfNeeded()
        }
    }
}
