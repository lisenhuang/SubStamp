import SwiftUI

struct SettingsMenuButton: View {
    @EnvironmentObject private var settingsManager: SettingsManager
    @ObservedObject var purchaseManager: PurchaseManager
    @State private var showSettingsSheet = false
    @State private var showPaywall = false
    @State private var paywallUsedCount = 0
    @Environment(\.locale) private var locale

    var body: some View {
        Button {
            showSettingsSheet = true
        } label: {
            Image(systemName: "gearshape")
                .font(AppTypography.bodyEmphasis)
                .foregroundStyle(AppColors.secondaryText)
        }
        .sheet(isPresented: $showSettingsSheet) {
            SettingsSheetView(
                purchaseManager: purchaseManager,
                showPaywall: $showPaywall,
                paywallUsedCount: $paywallUsedCount
            )
            .environmentObject(settingsManager)
        }
        .sheet(isPresented: $showPaywall) {
            PurchasePaywallView(
                purchaseManager: purchaseManager,
                usedCount: paywallUsedCount,
                freeLimit: SaveShareQuotaStore.freeLimit
            ) {}
        }
    }
}

private struct SettingsSheetView: View {
    @EnvironmentObject private var settingsManager: SettingsManager
    @ObservedObject var purchaseManager: PurchaseManager
    @Binding var showPaywall: Bool
    @Binding var paywallUsedCount: Int

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    var body: some View {
        NavigationStack {
            List {
                if purchaseManager.hasCheckedEntitlements && !purchaseManager.hasPremiumAccess {
                    Section {
                        Button {
                            Task { @MainActor in
                                paywallUsedCount = await SaveShareQuotaStore.shared.totalUsedCount()
                                dismiss()
                                try? await Task.sleep(nanoseconds: 150_000_000)
                                showPaywall = true
                            }
                        } label: {
                            Label(
                                String(localized: "Upgrade to Pro", bundle: .forLocale(locale)),
                                systemImage: "crown.fill"
                            )
                            .foregroundStyle(AppColors.accent)
                        }
                    }
                }

                Section(String(localized: "Display Language", bundle: .forLocale(locale))) {
                    ForEach(SettingsManager.supportedDisplayLanguages) { option in
                        Button {
                            settingsManager.displayLanguage = option.id
                        } label: {
                            HStack {
                                Text(option.label)
                                    .foregroundStyle(AppColors.primaryText)
                                Spacer()
                                if settingsManager.displayLanguage == option.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(AppColors.accent)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section(String(localized: "Appearance", bundle: .forLocale(locale))) {
                    appearanceOption(
                        title: String(localized: "System", bundle: .forLocale(locale)),
                        value: nil
                    )
                    appearanceOption(
                        title: String(localized: "Light", bundle: .forLocale(locale)),
                        value: .light
                    )
                    appearanceOption(
                        title: String(localized: "Dark", bundle: .forLocale(locale)),
                        value: .dark
                    )
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(String(localized: "Settings", bundle: .forLocale(locale)))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "Close", bundle: .forLocale(locale))) {
                        dismiss()
                    }
                }
            }
        }
        .preferredColorScheme(settingsManager.appearanceMode)
    }

    private func appearanceOption(title: String, value: ColorScheme?) -> some View {
        Button {
            settingsManager.appearanceMode = value
        } label: {
            HStack {
                Text(title)
                    .foregroundStyle(AppColors.primaryText)
                Spacer()
                if settingsManager.appearanceMode == value {
                    Image(systemName: "checkmark")
                        .foregroundStyle(AppColors.accent)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
