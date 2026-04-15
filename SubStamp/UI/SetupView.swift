import FoundationModels
import Speech
import SwiftUI
import SafariServices
@preconcurrency import Translation

struct SetupView: View {
    @ObservedObject var assetManager: AssetReadinessManager
    @Binding var transcriptionLocaleIdentifier: String
    @Binding var language1Identifier: String
    @Binding var language2Identifier: String?
    @Binding var subtitle1Mode: TranslationMode?
    @Binding var subtitle2Mode: TranslationMode?
    @Binding var translationProvider: TranslationProvider
    @Binding var fixTranscriptionWithAppleIntelligence: Bool
    var onOpenProjects: () -> Void
    var onContinue: () -> Void

    @State private var selectionLogic = LanguageSelectionLogic()
    @State private var supportedSpeechLocales: [Locale] = []
    @State private var installedSpeechIDs: Set<String> = []
    
    @State private var subtitleTargets: [TargetOption] = []
    @State private var selectedSubtitle1ID: String = "transcript"
    @State private var subtitle2Enabled: Bool = false
    @State private var selectedSubtitle2ID: String?
    
    @State private var translationConfig: TranslationSession.Configuration?
    @State private var shouldPrepareTranslation = false
    @State private var speechAvailable = true
    @State private var appleIntelligenceAvailable = false
    @State private var deviceSupportsAppleIntelligence = false
    @State private var showAINotEnabledAlert = false
    @State private var safariURL: URL?
    @StateObject private var purchaseManager = PurchaseManager()
    @State private var showPaywall = false
    @State private var paywallUsedCount = 0
    @State private var isApplyingSelectionBindings = false
    @State private var assetCheckTask: Task<Void, Never>?
    @State private var subtitleTargetsTask: Task<Void, Never>?
    @State private var activeSelectionSheet: SetupSelectionSheet?
    
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.locale) private var locale

    var body: some View {
        ScrollView {
            VStack(spacing: AppSpacing.l) {
                HStack {
                    Button {
                        onOpenProjects()
                    } label: {
                        Label(String(localized: "Projects", bundle: .forLocale(locale)), systemImage: "folder")
                            .font(AppTypography.bodyEmphasis)
                            .foregroundStyle(AppColors.secondaryText)
                    }
                    Spacer()
                    if purchaseManager.hasCheckedEntitlements && !purchaseManager.hasPremiumAccess {
                        Button {
                            Task { @MainActor in
                                paywallUsedCount = await SaveShareQuotaStore.shared.totalUsedCount()
                                showPaywall = true
                            }
                        } label: {
                            Label(String(localized: "Upgrade", bundle: .forLocale(locale)), systemImage: "crown.fill")
                                .font(AppTypography.bodyEmphasis)
                                .foregroundStyle(AppColors.accent)
                                .padding(.horizontal, AppSpacing.m)
                                .padding(.vertical, AppSpacing.s)
                                .background(AppColors.cardBackground)
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule()
                                        .stroke(AppColors.cardBorder, lineWidth: 1)
                                )
                        }
                    }
                    SettingsMenuButton(purchaseManager: purchaseManager)
                }

                WizardHeaderView(
                    step: 1,
                    total: 4,
                    title: "Setup languages",
                    subtitle: "Select your transcription and subtitle options."
                )

                audioLanguageCard
                subtitleSelectionCard
                translationProviderCard
                transcriptionFixCard
                readinessCard

                if !assetManager.isReadyToProceed {
                    downloadAssetsButton
                }
                continueButton
            }
            .padding(AppSpacing.l)
        }
        .background(AppColors.background)
        .sheet(isPresented: $showPaywall) {
            PurchasePaywallView(
                purchaseManager: purchaseManager,
                usedCount: paywallUsedCount,
                freeLimit: SaveShareQuotaStore.freeLimit
            ) {}
        }
        .sheet(item: $activeSelectionSheet) { sheet in
            SetupSelectionSheetView(
                sheet: sheet,
                locale: locale,
                supportedSpeechLocales: supportedSpeechLocales,
                installedSpeechIDs: installedSpeechIDs,
                subtitleTargets: subtitleTargets,
                transcriptionLocaleIdentifier: $transcriptionLocaleIdentifier,
                selectedSubtitle1ID: $selectedSubtitle1ID,
                selectedSubtitle2ID: $selectedSubtitle2ID
            )
        }
        .onAppear {
            applyCachedLanguageOptions()
            syncSubtitleSelectionsFromBindings()
            updateAssetManager()
        }
        .onDisappear {
            assetCheckTask?.cancel()
            subtitleTargetsTask?.cancel()
        }
        .task {
            await purchaseManager.prepareEntitlementsIfNeeded()

            if #available(iOS 26.0, *) {
                logAppleIntelligenceDiagnostics(context: "SetupView.task(start)")
                speechAvailable = SpeechTranscriber.isAvailable

                let model = SystemLanguageModel.default
                appleIntelligenceAvailable = model.isAvailable

                switch model.availability {
                case .available:
                    deviceSupportsAppleIntelligence = true
                case .unavailable(let reason):
                    deviceSupportsAppleIntelligence = (reason != .deviceNotEligible)
                }

                logAppleIntelligenceDiagnostics(context: "SetupView.task(initial-check)")
            } else {
                // iOS 18–25: SpeechTranscriber/SystemLanguageModel not available
                speechAvailable = SFSpeechRecognizer()?.isAvailable ?? true
                appleIntelligenceAvailable = false
                deviceSupportsAppleIntelligence = false
            }

            if !deviceSupportsAppleIntelligence {
                translationProvider = .translationFramework
                fixTranscriptionWithAppleIntelligence = false
            }

            if translationProvider != .appleIntelligence {
                fixTranscriptionWithAppleIntelligence = false
            }

            // Retry once shortly after launch in case the system model is still initializing.
            if #available(iOS 26.0, *) {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    let retryModel = SystemLanguageModel.default
                    let retryAvailable = retryModel.isAvailable
                    if retryAvailable != appleIntelligenceAvailable {
                        appleIntelligenceAvailable = retryAvailable

                        switch retryModel.availability {
                        case .available:
                            deviceSupportsAppleIntelligence = true
                        case .unavailable(let reason):
                            deviceSupportsAppleIntelligence = (reason != .deviceNotEligible)
                        }

                        logAppleIntelligenceDiagnostics(context: "SetupView.task(retry-changed)")
                    } else {
                        logAppleIntelligenceDiagnostics(context: "SetupView.task(retry-unchanged)")
                    }
                }
            }
            
            // 1. Fetch Speech locales
            if #available(iOS 26.0, *) {
                let speechLocales = await SpeechTranscriber.supportedLocales.sorted { 
                    let name1 = $0.localizedString(forIdentifier: $0.identifier) ?? $0.identifier
                    let name2 = $1.localizedString(forIdentifier: $1.identifier) ?? $1.identifier
                    return name1 < name2
                }
                self.supportedSpeechLocales = speechLocales
                AppLog.append("[SETUP] Available audio languages (\(speechLocales.count)): \(speechLocales.map { $0.identifier(.bcp47) }.joined(separator: ", "))")
                
                let installed = await SpeechTranscriber.installedLocales
                self.installedSpeechIDs = Set(installed.map { $0.identifier(.bcp47) })
                AppLog.append("[SETUP] Installed audio languages (\(installed.count)): \(installed.map { $0.identifier(.bcp47) }.joined(separator: ", "))")
                SetupPreferences.saveCachedSpeechLocales(speechLocales, installedIDs: installedSpeechIDs)
            } else {
                // iOS 18–25: use SFSpeechRecognizer.supportedLocales()
                let sfLocales = SFSpeechRecognizer.supportedLocales().sorted {
                    let name1 = $0.localizedString(forIdentifier: $0.identifier) ?? $0.identifier
                    let name2 = $1.localizedString(forIdentifier: $1.identifier) ?? $1.identifier
                    return name1 < name2
                }
                self.supportedSpeechLocales = sfLocales
                // SFSpeechRecognizer downloads on demand; treat all supported as installed
                self.installedSpeechIDs = Set(sfLocales.map { $0.identifier(.bcp47) })
                AppLog.append("[SETUP] Legacy audio languages (\(sfLocales.count))")
                SetupPreferences.saveCachedSpeechLocales(sfLocales, installedIDs: installedSpeechIDs)
            }
            
            // Normalize transcription locale to match a valid picker tag.
            let normalizedTranscription = bestMatchingSpeechLocale(for: transcriptionLocaleIdentifier, in: supportedSpeechLocales)
            if normalizedTranscription != transcriptionLocaleIdentifier {
                AppLog.append("[SETUP] Normalized audio locale: \(transcriptionLocaleIdentifier) -> \(normalizedTranscription)")
                transcriptionLocaleIdentifier = normalizedTranscription
                language1Identifier = normalizedTranscription
            }
            
            await refreshSubtitleTargets()
        }
        .translationTask(translationConfig) { session in
            guard shouldPrepareTranslation else { return }
            Task {
                await assetManager.downloadTranslationAssets(session: session)
                shouldPrepareTranslation = false
            }
        }
        .onChange(of: translationProvider) { _, newValue in
            if #available(iOS 26.0, *) {
                appleIntelligenceAvailable = SystemLanguageModel.default.isAvailable
                logAppleIntelligenceDiagnostics(context: "translationProvider changed -> \(newValue.rawValue)")
            } else {
                appleIntelligenceAvailable = false
            }
            if newValue == .appleIntelligence {
                fixTranscriptionWithAppleIntelligence = SetupPreferences.loadFixTranscriptionWithAppleIntelligence()
            } else {
                fixTranscriptionWithAppleIntelligence = false
            }
            if newValue == .appleIntelligence, !appleIntelligenceAvailable {
                translationProvider = .translationFramework
                fixTranscriptionWithAppleIntelligence = false
                return
            }
            if newValue == .appleIntelligence {
                translationConfig = nil
                shouldPrepareTranslation = false
            }
            applyCachedSubtitleTargets()
            syncSubtitleSelectionsFromBindings()
            scheduleSubtitleTargetsRefresh()
        }
        .onChange(of: transcriptionLocaleIdentifier) { _, _ in
            applyCachedSubtitleTargets()
            syncSubtitleSelectionsFromBindings()
            scheduleSubtitleTargetsRefresh()
        }
        .onChange(of: selectedSubtitle1ID) { _, _ in
            guard !isApplyingSelectionBindings else { return }
            updateAssetManager()
        }
        .onChange(of: subtitle2Enabled) { _, _ in
            guard !isApplyingSelectionBindings else { return }
            updateAssetManager()
        }
        .onChange(of: selectedSubtitle2ID) { _, _ in
            guard !isApplyingSelectionBindings else { return }
            updateAssetManager()
        }
        .onChange(of: scenePhase) { _, newValue in
            if newValue == .active {
                Task { await purchaseManager.refreshEntitlements() }
                if #available(iOS 26.0, *) {
                    appleIntelligenceAvailable = SystemLanguageModel.default.isAvailable
                    logAppleIntelligenceDiagnostics(context: "scenePhase -> active")
                } else {
                    appleIntelligenceAvailable = false
                }
                if !appleIntelligenceAvailable {
                    translationProvider = .translationFramework
                    fixTranscriptionWithAppleIntelligence = false
                    translationConfig = nil
                    shouldPrepareTranslation = false
                }
                applyCachedSubtitleTargets()
                syncSubtitleSelectionsFromBindings()
                scheduleSubtitleTargetsRefresh()
            }
        }
    }

    private func logAppleIntelligenceDiagnostics(context: String) {
#if DEBUG
        guard #available(iOS 26.0, *) else {
            AppLog.append("[AI-DETECT] \(context) (iOS < 26, skipped)")
            return
        }
        let prefix = "[AI-DETECT]"
        let model = SystemLanguageModel.default
        let availability = describeAppleIntelligenceAvailability(model.availability)
        let supportsCurrentLocale = model.supportsLocale(Locale.current)

        let supported = model.supportedLanguages.map { $0.minimalIdentifier }
        let supportedSample = supported.prefix(12).joined(separator: ", ")

        let preferred = Locale.preferredLanguages.prefix(5).joined(separator: ", ")
        let currentLocale = Locale.current.identifier

        AppLog.append("\(prefix) \(context)")
        AppLog.append("\(prefix) isAvailable=\(model.isAvailable) availability=\(availability) supportsLocale(current)=\(supportsCurrentLocale)")
        AppLog.append("\(prefix) supportedCount=\(supported.count) sample=\(supportedSample)")
        AppLog.append("\(prefix) currentLocale=\(currentLocale) preferred=\(preferred)")
        AppLog.append("\(prefix) selectedProvider=\(translationProvider.rawValue) fixTranscription=\(fixTranscriptionWithAppleIntelligence) transcription=\(transcriptionLocaleIdentifier) s1=\(selectedSubtitle1ID) s2=\(selectedSubtitle2ID ?? "nil")")
#endif
    }

#if DEBUG
    @available(iOS 26.0, *)
    private func describeAppleIntelligenceAvailability(_ availability: SystemLanguageModel.Availability) -> String {
        switch availability {
        case .available:
            return "available"
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "unavailable(deviceNotEligible)"
            case .appleIntelligenceNotEnabled:
                return "unavailable(appleIntelligenceNotEnabled)"
            case .modelNotReady:
                return "unavailable(modelNotReady)"
            @unknown default:
                return "unavailable(unknown)"
            }
        @unknown default:
            return "unknown"
        }
    }
#endif

    private var audioLanguageCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            Text("Audio language")
                .font(AppTypography.bodyEmphasis)
            Button {
                activeSelectionSheet = .audioLanguage
            } label: {
                selectionFieldLabel(text: selectedAudioLocaleLabel())
            }
            .buttonStyle(.plain)
            
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppColors.warning)
                    .font(.system(size: 14))
                Text("Must match the language spoken in the video. Incorrect selection will cause transcription to fail.")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.warning)
            }
            .padding(AppSpacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.warning.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius)
                .stroke(AppColors.cardBorder, lineWidth: 1)
        )
    }

    private var subtitleSelectionCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.l) {
            // Subtitle 1 (Required)
            VStack(alignment: .leading, spacing: AppSpacing.s) {
                Text("Subtitle 1")
                    .font(AppTypography.bodyEmphasis)
                Button {
                    activeSelectionSheet = .subtitle1
                } label: {
                    selectionFieldLabel(text: selectedSubtitle1Label())
                }
                .buttonStyle(.plain)
                
                if let option = subtitleTargets.first(where: { $0.id == selectedSubtitle1ID }),
                   option.mode == .pivot {
                    pivotWarning
                }
            }
            
            Divider()
            
            // Subtitle 2 (Optional)
            VStack(alignment: .leading, spacing: AppSpacing.s) {
                HStack {
                    Text("Subtitle 2")
                        .font(AppTypography.bodyEmphasis)
                    Spacer()
                    Toggle("Add Subtitle 2", isOn: $subtitle2Enabled)
                        .labelsHidden()
                }
                
                if subtitle2Enabled {
                    if subtitleTargets.isEmpty {
                        Text("Translation not available for this audio language.")
                            .font(AppTypography.caption)
                            .foregroundStyle(AppColors.warning)
                    } else {
                        Button {
                            activeSelectionSheet = .subtitle2
                        } label: {
                            selectionFieldLabel(text: selectedSubtitle2Label())
                        }
                        .buttonStyle(.plain)
                        
                        if let selectedID = selectedSubtitle2ID,
                           let option = subtitleTargets.first(where: { $0.id == selectedID }),
                           option.mode == .pivot {
                            pivotWarning
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius)
                .stroke(AppColors.cardBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var translationProviderCard: some View {
        if deviceSupportsAppleIntelligence {
            VStack(alignment: .leading, spacing: AppSpacing.s) {
                Text("Translation engine")
                    .font(AppTypography.bodyEmphasis)

                translationEnginePicker

                Text("AI uses the on-device system model. Framework uses TranslationSession and may require downloading language assets.")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(AppColors.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius)
                    .stroke(AppColors.cardBorder, lineWidth: 1)
            )
        }
    }

    private var translationEnginePicker: some View {
        HStack(spacing: 0) {
            translationEngineOption(
                isSelected: translationProvider == .translationFramework,
                action: { translationProvider = .translationFramework }
            ) {
                Text("Framework")
                    .font(AppTypography.bodyEmphasis)
                    .foregroundStyle(translationProvider == .translationFramework ? AppColors.primaryText : AppColors.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            translationEngineOption(
                isSelected: translationProvider == .appleIntelligence,
                action: {
                    if appleIntelligenceAvailable {
                        translationProvider = .appleIntelligence
                    } else {
                        // AI not enabled, show alert
                        showAINotEnabledAlert = true
                    }
                }
            ) {
                Text("AI")
                    .font(AppTypography.bodyEmphasis)
                    .foregroundStyle(appleIntelligenceGradient)
                    .shadow(color: .purple.opacity(0.25), radius: 12, x: 0, y: 0)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
        .padding(2)
        .background(AppColors.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppSpacing.controlCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppSpacing.controlCornerRadius)
                .stroke(AppColors.cardBorder, lineWidth: 1)
        )
        .accessibilityLabel("Translation engine")
        .alert(Text(String(localized: "AI Not Enabled", bundle: .forLocale(locale))), isPresented: $showAINotEnabledAlert) {
            Button(String(localized: "Open Settings Guide", bundle: .forLocale(locale))) {
                safariURL = URL(string: "https://support.apple.com/guide/iphone/iphc28624b81/ios#:~:text=of%20iOS.-,Turn%20on%20Apple%20Intelligence,-If%20Apple%20Intelligence")
            }
            Button(String(localized: "Cancel", bundle: .forLocale(locale)), role: .cancel) { }
        } message: {
            Text(String(localized: "To use AI translation, you need to enable AI in your iPhone settings. Tap 'Open Settings Guide' to learn how.", bundle: .forLocale(locale)))
        }
        .sheet(item: Binding(
            get: { safariURL.map { SafariURLItem(url: $0) } },
            set: { safariURL = $0?.url }
        )) { item in
            SafariView(url: item.url)
        }
    }

    private var appleIntelligenceGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 1.0, green: 0.31, blue: 0.85), // pink-ish
                Color(red: 0.54, green: 0.36, blue: 1.0), // purple-ish
                Color(red: 0.18, green: 0.48, blue: 1.0), // blue-ish
                Color(red: 1.0, green: 0.54, blue: 0.24)  // orange-ish
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private func translationEngineOption<Content: View>(
        isSelected: Bool,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: action) {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: AppSpacing.controlCornerRadius - 2)
                .fill(isSelected ? AppColors.cardBackground : Color.clear)
        )
    }

    @ViewBuilder
    private var transcriptionFixCard: some View {
        if appleIntelligenceAvailable && translationProvider == .appleIntelligence {
            VStack(alignment: .leading, spacing: AppSpacing.s) {
                Text("Transcription quality")
                    .font(AppTypography.bodyEmphasis)

                Toggle("Fix transcription mistakes (AI)", isOn: $fixTranscriptionWithAppleIntelligence)
                    .font(AppTypography.caption)

                Text("Optional. Proofreads the transcript to correct obvious speech-to-text mistakes while preserving cue alignment (same number/order). You can review/edit before export.")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(AppColors.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius)
                    .stroke(AppColors.cardBorder, lineWidth: 1)
            )
        }
    }

    private var pivotWarning: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle")
            Text("May reduce quality (via English)")
        }
        .font(.system(size: 11))
        .foregroundStyle(AppColors.warning)
    }

    private var readinessCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            Text("Model readiness")
                .font(AppTypography.bodyEmphasis)
            AssetStatusCard(
                title: "Speech assets",
                state: assetManager.speechAssetsState,
                description: assetStateDescription(assetManager.speechAssetsState)
            )
            AssetStatusCard(
                title: translationProvider == .appleIntelligence ? "AI" : "Translation model",
                state: assetManager.translationAssetsState,
                description: assetStateDescription(assetManager.translationAssetsState)
            )
            
            if let warning = assetManager.lowStorageWarning {
                Text(warning)
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.warning)
            }
            if let error = assetManager.lastError {
                Text(error.localizedDescription)
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.error)
            }
        }
    }

    private func assetStateDescription(_ state: AssetState) -> String? {
        if case let .failed(message) = state, !message.isEmpty {
            return message
        }
        return nil
    }

    private var downloadAssetsButton: some View {
        PrimaryButton(
            title: "Download required assets",
            systemImage: "arrow.down.circle",
            isEnabled: !assetManager.isBusy
        ) {
            Task {
                await assetManager.downloadSpeechAssets()

                if translationProvider == .appleIntelligence {
                    await assetManager.check()
                    return
                }
                
                guard let config = assetManager.config else { return }
                
                let availability = LanguageAvailability()
                let sourceLang = Locale.Language(identifier: config.audioLocale.identifier)
                let englishLang = Locale.Language(identifier: "en-US")
                
                let tracks: [LanguageSelectionConfig.SubtitleTrackConfig] = [config.subtitle1, config.subtitle2].compactMap { $0 }
                
                for track in tracks {
                    switch track {
                    case .transcript: continue
                    case .direct(let target):
                        let status = await availability.status(from: sourceLang, to: target)
                        if status == .supported {
                            assetManager.setTranslationDownloading()
                            translationConfig = TranslationSession.Configuration(source: sourceLang, target: target)
                            shouldPrepareTranslation = true
                            return // One at a time for system prompts
                        }
                    case .pivot(let pivot, let target):
                        let status1 = await availability.status(from: sourceLang, to: pivot)
                        if status1 == .supported {
                            assetManager.setTranslationDownloading()
                            translationConfig = TranslationSession.Configuration(source: sourceLang, target: pivot)
                            shouldPrepareTranslation = true
                            return
                        } else {
                            let status2 = await availability.status(from: pivot, to: target)
                            if status2 == .supported {
                                assetManager.setTranslationDownloading()
                                translationConfig = TranslationSession.Configuration(source: pivot, target: target)
                                shouldPrepareTranslation = true
                                return
                            }
                        }
                    }
                }
            }
        }
    }

    private var continueButton: some View {
        // Treat "Subtitle 2 enabled but no language selected" as effectively disabled.
        let effectiveSubtitle2ID: String? = {
            guard subtitle2Enabled else { return nil }
            guard let id = selectedSubtitle2ID, !id.isEmpty else { return nil }
            return id
        }()
        return PrimaryButton(
            title: "Continue",
            systemImage: "arrow.right.circle",
            isEnabled: assetManager.isReadyToProceed && (!selectedSubtitle1ID.isEmpty)
        ) {
            // Update bindings
            language1Identifier = (selectedSubtitle1ID == "transcript") ? transcriptionLocaleIdentifier : selectedSubtitle1ID
            if let s2 = effectiveSubtitle2ID {
                language2Identifier = (s2 == "transcript") ? transcriptionLocaleIdentifier : s2
            } else {
                language2Identifier = nil
            }
            
            // Mode 1
            if selectedSubtitle1ID == "transcript" {
                subtitle1Mode = nil
            } else if let option = subtitleTargets.first(where: { $0.id == selectedSubtitle1ID }) {
                subtitle1Mode = option.mode
            }
            
            // Mode 2
            if let targetID = effectiveSubtitle2ID {
                if targetID == "transcript" {
                    subtitle2Mode = nil
                } else if let option = subtitleTargets.first(where: { $0.id == targetID }) {
                    subtitle2Mode = option.mode
                } else {
                    subtitle2Mode = nil
                }
            } else {
                subtitle2Mode = nil
            }
            
            onContinue()
        }
    }

    // MARK: - Helpers

    private func audioLocaleLabel(_ locale: Locale) -> String {
        let name = locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
        let flag = flagPrefix(for: locale.identifier(.bcp47))
        return "\(flag) \(name) (\(locale.identifier(.bcp47)))"
    }

    private func targetLabel(_ target: TargetOption) -> String {
        let flag = flagPrefix(for: target.id)
        var label = "\(flag) \(target.displayName) (\(target.id))"
        if target.mode == .pivot {
            label += " " + String(localized: "(via English)", bundle: .forLocale(locale))
        }
        return label
    }

    private func selectedAudioLocaleLabel() -> String {
        if let locale = supportedSpeechLocales.first(where: { $0.identifier == transcriptionLocaleIdentifier }) {
            return audioLocaleLabel(locale)
        }
        return transcriptionLocaleIdentifier
    }

    private func selectedSubtitle1Label() -> String {
        if selectedSubtitle1ID == "transcript" {
            return "\(flagPrefix(for: transcriptionLocaleIdentifier)) \(String(localized: "Transcript (Audio Language)", bundle: .forLocale(locale)))"
        }
        if let target = subtitleTargets.first(where: { $0.id == selectedSubtitle1ID }) {
            return targetLabel(target)
        }
        return selectedSubtitle1ID
    }

    private func selectedSubtitle2Label() -> String {
        guard let id = selectedSubtitle2ID else { return String(localized: "Select language", bundle: .forLocale(locale)) }
        if id == "transcript" {
            return "\(flagPrefix(for: transcriptionLocaleIdentifier)) \(String(localized: "Transcript (Audio Language)", bundle: .forLocale(locale)))"
        }
        if let target = subtitleTargets.first(where: { $0.id == id }) {
            return targetLabel(target)
        }
        return id
    }

    private func flagPrefix(for identifier: String) -> String {
        guard let region = regionCode(from: identifier) else { return "🌐" }
        if let flag = flagEmoji(forRegionCode: region) {
            return flag
        }
        // Numeric regions like "419" (Latin America) don't have a flag emoji.
        if isNumericRegion(region) {
            return "🌎"
        }
        return "🏳️"
    }

    private func regionCode(from identifier: String) -> String? {
        // BCP-47: language[-script][-region][-variant...]
        // Region is a 2-letter (ISO 3166-1) or 3-digit (UN M.49) subtag.
        let components = identifier
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .map(String.init)

        guard !components.isEmpty else { return nil }

        var candidateIndex = 1 // after language
        if components.count > 2, isScriptSubtag(components[1]) {
            candidateIndex = 2
        }

        if components.indices.contains(candidateIndex), isRegionSubtag(components[candidateIndex]) {
            return components[candidateIndex].uppercased()
        }

        // Fallback: scan remaining subtags (skip language).
        for component in components.dropFirst() {
            if isRegionSubtag(component) {
                return component.uppercased()
            }
        }

        // Fallback: ask Foundation for a likely region (useful for language-only identifiers like "es").
        let locale = Locale(identifier: identifier)
        if let region = locale.region?.identifier ?? locale.regionCode?.uppercased() {
            return region
        }

        // Last resort: for language-only identifiers (e.g. "fr"), pick a representative region
        // so we can show a more useful flag than the generic globe.
        let languageCode = components[0].lowercased()
        return defaultRegion(forLanguageCode: languageCode)
    }

    private func flagEmoji(forRegionCode regionCode: String) -> String? {
        let code = regionCode.uppercased()
        guard code.count == 2 else { return nil }
        let scalars = code.unicodeScalars
        guard scalars.allSatisfy({ $0.value >= 65 && $0.value <= 90 }) else { return nil }

        let base: UInt32 = 0x1F1E6 // Regional Indicator Symbol Letter A
        let first = base + (scalars[scalars.startIndex].value - 65)
        let second = base + (scalars[scalars.index(after: scalars.startIndex)].value - 65)
        guard let s1 = UnicodeScalar(first), let s2 = UnicodeScalar(second) else { return nil }
        return String(Character(s1)) + String(Character(s2))
    }

    private func isRegionSubtag(_ component: String) -> Bool {
        if component.count == 2 {
            return component.unicodeScalars.allSatisfy { scalar in
                let v = scalar.value
                return (v >= 65 && v <= 90) || (v >= 97 && v <= 122)
            }
        }
        if component.count == 3 {
            return component.unicodeScalars.allSatisfy { scalar in
                let v = scalar.value
                return v >= 48 && v <= 57
            }
        }
        return false
    }

    private func isScriptSubtag(_ component: String) -> Bool {
        guard component.count == 4 else { return false }
        return component.unicodeScalars.allSatisfy { scalar in
            let v = scalar.value
            return (v >= 65 && v <= 90) || (v >= 97 && v <= 122)
        }
    }

    private func isNumericRegion(_ regionCode: String) -> Bool {
        guard regionCode.count == 3 else { return false }
        return regionCode.unicodeScalars.allSatisfy { scalar in
            let v = scalar.value
            return v >= 48 && v <= 57
        }
    }

    private func defaultRegion(forLanguageCode languageCode: String) -> String? {
        // These are heuristics for display only (BCP-47 language-only tags don’t imply a country).
        // Keep this list small and obvious; unknowns fall back to 🌐.
        let map: [String: String] = [
            "ar": "SA",
            "ca": "ES",
            "cs": "CZ",
            "da": "DK",
            "de": "DE",
            "el": "GR",
            "en": "US",
            "es": "ES",
            "fa": "IR",
            "fi": "FI",
            "fr": "FR",
            "he": "IL",
            "hi": "IN",
            "hr": "HR",
            "hu": "HU",
            "id": "ID",
            "it": "IT",
            "ja": "JP",
            "ko": "KR",
            "ms": "MY",
            "nb": "NO",
            "nl": "NL",
            "nn": "NO",
            "no": "NO",
            "pl": "PL",
            "pt": "BR",
            "ro": "RO",
            "ru": "RU",
            "sk": "SK",
            "sv": "SE",
            "th": "TH",
            "tr": "TR",
            "uk": "UA",
            "vi": "VN",
            "zh": "CN"
        ]
        return map[languageCode]
    }

    private func mappedSubtitleSelection(_ identifier: String) -> String? {
        if identifier == "transcript" { return "transcript" }
        guard !subtitleTargets.isEmpty else { return nil }

        let normalizedSaved = normalizeLocaleIdentifier(identifier)
        if let exact = subtitleTargets.first(where: { normalizeLocaleIdentifier($0.id) == normalizedSaved }) {
            return exact.id
        }

        guard let savedLang = languageCode(from: normalizedSaved) else { return nil }
        let candidates = subtitleTargets.filter { languageCode(from: normalizeLocaleIdentifier($0.id)) == savedLang }
        guard !candidates.isEmpty else { return nil }

        if let savedScript = scriptSubtag(from: normalizedSaved),
           let match = candidates.first(where: { normalizeLocaleIdentifier($0.id).contains("-\(savedScript)") }) {
            return match.id
        }

        if let savedRegion = regionSubtag(from: normalizedSaved),
           let match = candidates.first(where: { normalizeLocaleIdentifier($0.id).contains("-\(savedRegion)") }) {
            return match.id
        }

        if savedLang == "zh" {
            if let hans = candidates.first(where: { normalizeLocaleIdentifier($0.id).contains("-hans") }) {
                return hans.id
            }
        }

        return candidates.first?.id
    }

    private func normalizeLocaleIdentifier(_ identifier: String) -> String {
        identifier
            .replacingOccurrences(of: "_", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    /// Finds the best matching speech locale identifier for a raw locale string.
    /// Handles cases where Locale.current.identifier returns values like "en_US@rg=nzzzzz"
    /// which don't match any SpeechTranscriber locale identifier.
    private func bestMatchingSpeechLocale(for rawIdentifier: String, in locales: [Locale]) -> String {
        // 1. Exact match
        if locales.contains(where: { $0.identifier == rawIdentifier }) {
            return rawIdentifier
        }
        
        // 2. Strip everything after "@" (removes @rg=nzzzzz etc.) and try exact match
        let stripped = rawIdentifier.components(separatedBy: "@").first ?? rawIdentifier
        if locales.contains(where: { $0.identifier == stripped }) {
            return stripped
        }
        
        // 3. Use Locale to extract language code and region, then match by BCP-47
        let parsed = Locale(identifier: rawIdentifier)
        let parsedBCP47 = parsed.identifier(.bcp47)
        if let match = locales.first(where: { $0.identifier(.bcp47) == parsedBCP47 }) {
            return match.identifier
        }
        
        // 4. Match by language + region (e.g. en + US)
        let parsedLang = parsed.language.languageCode?.identifier
        let parsedRegion = parsed.language.region?.identifier
        if let lang = parsedLang, let region = parsedRegion {
            if let match = locales.first(where: {
                $0.language.languageCode?.identifier == lang && $0.language.region?.identifier == region
            }) {
                return match.identifier
            }
        }
        
        // 5. Match by language code only (first available variant)
        if let lang = parsedLang {
            if let match = locales.first(where: {
                $0.language.languageCode?.identifier == lang
            }) {
                return match.identifier
            }
        }
        
        // 6. Give up, return first locale or the raw identifier
        return locales.first?.identifier ?? rawIdentifier
    }

    private func languageCode(from normalizedIdentifier: String) -> String? {
        normalizeLocaleIdentifier(normalizedIdentifier).split(separator: "-").first.map(String.init)
    }

    private func scriptSubtag(from normalizedIdentifier: String) -> String? {
        let parts = normalizeLocaleIdentifier(normalizedIdentifier).split(separator: "-").map(String.init)
        return parts.first(where: { isScriptSubtag($0) })
    }

    private func regionSubtag(from normalizedIdentifier: String) -> String? {
        let parts = normalizeLocaleIdentifier(normalizedIdentifier).split(separator: "-").map(String.init)
        return parts.first(where: { isRegionSubtag($0) })
    }

    private func scheduleSubtitleTargetsRefresh() {
        subtitleTargetsTask?.cancel()
        subtitleTargetsTask = Task {
            await refreshSubtitleTargets()
        }
    }

    private func refreshSubtitleTargets() async {
        let transcriptionID = transcriptionLocaleIdentifier
        let provider = translationProvider
        let audioLocale = Locale(identifier: transcriptionID)
        let computedTargets = await selectionLogic.computeTargets(for: audioLocale, provider: provider)
        guard !Task.isCancelled else { return }
        guard transcriptionLocaleIdentifier == transcriptionID, translationProvider == provider else { return }

        subtitleTargets = computedTargets
        
        // Validation
        if selectedSubtitle1ID != "transcript" && !subtitleTargets.contains(where: { $0.id == selectedSubtitle1ID }) {
            selectedSubtitle1ID = mappedSubtitleSelection(selectedSubtitle1ID) ?? "transcript"
        }
        if let current = selectedSubtitle2ID, current != "transcript" && !subtitleTargets.contains(where: { $0.id == current }) {
            selectedSubtitle2ID = mappedSubtitleSelection(current)
        }

        // Only sync/apply after the target list is known and still current.
        syncSubtitleSelectionsFromBindings()
        updateAssetManager()
    }

    private func applyCachedLanguageOptions() {
        if supportedSpeechLocales.isEmpty {
            let cachedSpeechLocales = SetupPreferences.loadCachedSpeechLocales()
            if !cachedSpeechLocales.isEmpty {
                supportedSpeechLocales = cachedSpeechLocales
            }
        }

        if installedSpeechIDs.isEmpty {
            let cachedInstalled = SetupPreferences.loadCachedInstalledSpeechIDs()
            if !cachedInstalled.isEmpty {
                installedSpeechIDs = cachedInstalled
            }
        }

        applyCachedSubtitleTargets()
    }

    private func applyCachedSubtitleTargets() {
        subtitleTargets = SetupPreferences.loadCachedSubtitleTargets(
            for: transcriptionLocaleIdentifier,
            provider: translationProvider
        ) ?? []
    }

    private func syncSubtitleSelectionsFromBindings() {
        isApplyingSelectionBindings = true
        defer { isApplyingSelectionBindings = false }

        let desiredSubtitle1ID = language1Identifier == transcriptionLocaleIdentifier ? "transcript" : language1Identifier
        if desiredSubtitle1ID == "transcript" {
            selectedSubtitle1ID = "transcript"
        } else if let mapped = mappedSubtitleSelection(desiredSubtitle1ID) {
            selectedSubtitle1ID = mapped
        } else if subtitleTargets.isEmpty {
            selectedSubtitle1ID = "transcript"
        }

        guard let lang2 = language2Identifier else {
            subtitle2Enabled = false
            selectedSubtitle2ID = nil
            return
        }

        subtitle2Enabled = true
        let desiredSubtitle2ID = lang2 == transcriptionLocaleIdentifier ? "transcript" : lang2
        if desiredSubtitle2ID == "transcript" {
            selectedSubtitle2ID = "transcript"
            return
        }

        if let mapped = mappedSubtitleSelection(lang2) {
            selectedSubtitle2ID = mapped
        } else if subtitleTargets.isEmpty {
            selectedSubtitle2ID = nil
        } else {
            selectedSubtitle2ID = nil
            subtitle2Enabled = false
        }
    }

    private func updateAssetManager() {
        let audioLocale = Locale(identifier: transcriptionLocaleIdentifier)
        
        var s1: LanguageSelectionConfig.SubtitleTrackConfig = .transcript(audioLocale)
        if selectedSubtitle1ID != "transcript", 
           let option = subtitleTargets.first(where: { $0.id == selectedSubtitle1ID }) {
            let targetLang = Locale.Language(identifier: selectedSubtitle1ID)
            if option.mode == .direct {
                s1 = .direct(targetLang)
            } else {
                s1 = .pivot(pivot: Locale.Language(identifier: "en-US"), target: targetLang)
            }
        }
        
        var s2: LanguageSelectionConfig.SubtitleTrackConfig? = nil
        if subtitle2Enabled, let targetID = selectedSubtitle2ID {
            if targetID == "transcript" {
                s2 = .transcript(audioLocale)
            } else if let option = subtitleTargets.first(where: { $0.id == targetID }) {
                let targetLang = Locale.Language(identifier: targetID)
                if option.mode == .direct {
                    s2 = .direct(targetLang)
                } else {
                    s2 = .pivot(pivot: Locale.Language(identifier: "en-US"), target: targetLang)
                }
            }
        }
        
        let config = LanguageSelectionConfig(
            audioLocale: audioLocale,
            translationProvider: translationProvider,
            fixTranscriptionWithAppleIntelligence: fixTranscriptionWithAppleIntelligence,
            subtitle1: s1,
            subtitle2: s2
        )
        assetManager.configure(with: config)
        assetCheckTask?.cancel()
        assetCheckTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            await assetManager.check()
        }
    }

    private func selectionFieldLabel(text: String) -> some View {
        HStack {
            Text(text)
                .foregroundStyle(AppColors.primaryText)
                .multilineTextAlignment(.leading)
            Spacer(minLength: AppSpacing.s)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(AppColors.secondaryText)
        }
        .padding(.horizontal, AppSpacing.m)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppSpacing.controlCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppSpacing.controlCornerRadius)
                .stroke(AppColors.cardBorder, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Safari View Helpers

private enum SetupSelectionSheet: String, Identifiable {
    case audioLanguage
    case subtitle1
    case subtitle2

    var id: String { rawValue }
}

private struct SetupSelectionSheetView: View {
    let sheet: SetupSelectionSheet
    let locale: Locale
    let supportedSpeechLocales: [Locale]
    let installedSpeechIDs: Set<String>
    let subtitleTargets: [TargetOption]
    @Binding var transcriptionLocaleIdentifier: String
    @Binding var selectedSubtitle1ID: String
    @Binding var selectedSubtitle2ID: String?

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            List {
                switch sheet {
                case .audioLanguage:
                    ForEach(filteredAudioLocales, id: \.identifier) { localeOption in
                        Button {
                            transcriptionLocaleIdentifier = localeOption.identifier
                            dismiss()
                        } label: {
                            selectorRow(
                                title: audioLocaleLabel(localeOption),
                                isSelected: localeOption.identifier == transcriptionLocaleIdentifier
                            )
                        }
                        .buttonStyle(.plain)
                    }

                case .subtitle1:
                    Button {
                        selectedSubtitle1ID = "transcript"
                        dismiss()
                    } label: {
                        selectorRow(
                            title: transcriptLabel,
                            isSelected: selectedSubtitle1ID == "transcript"
                        )
                    }
                    .buttonStyle(.plain)

                    ForEach(filteredSubtitleTargets) { target in
                        Button {
                            selectedSubtitle1ID = target.id
                            dismiss()
                        } label: {
                            selectorRow(
                                title: targetLabel(target),
                                isSelected: selectedSubtitle1ID == target.id
                            )
                        }
                        .buttonStyle(.plain)
                    }

                case .subtitle2:
                    Button {
                        selectedSubtitle2ID = nil
                        dismiss()
                    } label: {
                        selectorRow(
                            title: String(localized: "Select language", bundle: .forLocale(locale)),
                            isSelected: selectedSubtitle2ID == nil
                        )
                    }
                    .buttonStyle(.plain)

                    Button {
                        selectedSubtitle2ID = "transcript"
                        dismiss()
                    } label: {
                        selectorRow(
                            title: transcriptLabel,
                            isSelected: selectedSubtitle2ID == "transcript"
                        )
                    }
                    .buttonStyle(.plain)

                    ForEach(filteredSubtitleTargets) { target in
                        Button {
                            selectedSubtitle2ID = target.id
                            dismiss()
                        } label: {
                            selectorRow(
                                title: targetLabel(target),
                                isSelected: selectedSubtitle2ID == target.id
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $searchText, prompt: String(localized: "Search", bundle: .forLocale(locale)))
            .navigationTitle(sheetTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "Close", bundle: .forLocale(locale))) {
                        dismiss()
                    }
                }
            }
        }
    }

    private var sheetTitle: String {
        switch sheet {
        case .audioLanguage:
            return String(localized: "Choose Audio Language", bundle: .forLocale(locale))
        case .subtitle1:
            return String(localized: "Choose Subtitle 1", bundle: .forLocale(locale))
        case .subtitle2:
            return String(localized: "Choose Subtitle 2", bundle: .forLocale(locale))
        }
    }

    private var transcriptLabel: String {
        "\(flagPrefix(for: transcriptionLocaleIdentifier)) \(String(localized: "Transcript (Audio Language)", bundle: .forLocale(locale)))"
    }

    private var filteredAudioLocales: [Locale] {
        guard !searchText.isEmpty else { return supportedSpeechLocales }
        return supportedSpeechLocales.filter { localeOption in
            let label = audioLocaleLabel(localeOption)
            return label.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var filteredSubtitleTargets: [TargetOption] {
        guard !searchText.isEmpty else { return subtitleTargets }
        return subtitleTargets.filter { option in
            targetLabel(option).localizedCaseInsensitiveContains(searchText)
        }
    }

    private func selectorRow(title: String, isSelected: Bool) -> some View {
        HStack(spacing: AppSpacing.s) {
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(AppColors.accent)
            } else {
                Color.clear
                    .frame(width: 16, height: 16)
            }
            Text(title)
                .foregroundStyle(AppColors.primaryText)
            Spacer()
        }
        .contentShape(Rectangle())
    }

    private func audioLocaleLabel(_ localeOption: Locale) -> String {
        let name = localeOption.localizedString(forIdentifier: localeOption.identifier) ?? localeOption.identifier
        let flag = flagPrefix(for: localeOption.identifier(.bcp47))
        let installed = installedSpeechIDs.contains(localeOption.identifier(.bcp47))
        return "\(flag) \(name) (\(localeOption.identifier(.bcp47)))\(installed ? " ✓" : "")"
    }

    private func targetLabel(_ target: TargetOption) -> String {
        let flag = flagPrefix(for: target.id)
        var label = "\(flag) \(target.displayName) (\(target.id))"
        if target.mode == .pivot {
            label += " " + String(localized: "(via English)", bundle: .forLocale(locale))
        }
        return label
    }

    private func flagPrefix(for identifier: String) -> String {
        guard let region = regionCode(from: identifier) else { return "🌐" }
        if let flag = flagEmoji(forRegionCode: region) {
            return flag
        }
        if isNumericRegion(region) {
            return "🌎"
        }
        return "🏳️"
    }

    private func regionCode(from identifier: String) -> String? {
        let components = identifier
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .map(String.init)

        guard !components.isEmpty else { return nil }

        var candidateIndex = 1
        if components.count > 2, isScriptSubtag(components[1]) {
            candidateIndex = 2
        }

        if components.indices.contains(candidateIndex), isRegionSubtag(components[candidateIndex]) {
            return components[candidateIndex].uppercased()
        }

        for component in components.dropFirst() {
            if isRegionSubtag(component) {
                return component.uppercased()
            }
        }

        let locale = Locale(identifier: identifier)
        if let region = locale.region?.identifier ?? locale.regionCode?.uppercased() {
            return region
        }

        let languageCode = components[0].lowercased()
        return defaultRegion(forLanguageCode: languageCode)
    }

    private func flagEmoji(forRegionCode regionCode: String) -> String? {
        let code = regionCode.uppercased()
        guard code.count == 2 else { return nil }
        let scalars = code.unicodeScalars
        guard scalars.allSatisfy({ $0.value >= 65 && $0.value <= 90 }) else { return nil }

        let base: UInt32 = 0x1F1E6
        let first = base + (scalars[scalars.startIndex].value - 65)
        let second = base + (scalars[scalars.index(after: scalars.startIndex)].value - 65)
        guard let s1 = UnicodeScalar(first), let s2 = UnicodeScalar(second) else { return nil }
        return String(Character(s1)) + String(Character(s2))
    }

    private func isRegionSubtag(_ component: String) -> Bool {
        if component.count == 2 {
            return component.unicodeScalars.allSatisfy { scalar in
                let v = scalar.value
                return (v >= 65 && v <= 90) || (v >= 97 && v <= 122)
            }
        }
        if component.count == 3 {
            return component.unicodeScalars.allSatisfy { scalar in
                let v = scalar.value
                return v >= 48 && v <= 57
            }
        }
        return false
    }

    private func isScriptSubtag(_ component: String) -> Bool {
        guard component.count == 4 else { return false }
        return component.unicodeScalars.allSatisfy { scalar in
            let v = scalar.value
            return (v >= 65 && v <= 90) || (v >= 97 && v <= 122)
        }
    }

    private func isNumericRegion(_ regionCode: String) -> Bool {
        guard regionCode.count == 3 else { return false }
        return regionCode.unicodeScalars.allSatisfy { scalar in
            let v = scalar.value
            return v >= 48 && v <= 57
        }
    }

    private func defaultRegion(forLanguageCode languageCode: String) -> String? {
        let map: [String: String] = [
            "ar": "SA", "ca": "ES", "cs": "CZ", "da": "DK", "de": "DE",
            "el": "GR", "en": "US", "es": "ES", "fa": "IR", "fi": "FI",
            "fr": "FR", "he": "IL", "hi": "IN", "hr": "HR", "hu": "HU",
            "id": "ID", "it": "IT", "ja": "JP", "ko": "KR", "ms": "MY",
            "nb": "NO", "nl": "NL", "nn": "NO", "no": "NO", "pl": "PL",
            "pt": "BR", "ro": "RO", "ru": "RU", "sk": "SK", "sv": "SE",
            "th": "TH", "tr": "TR", "uk": "UA", "vi": "VN", "zh": "CN"
        ]
        return map[languageCode]
    }
}

struct SafariURLItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    
    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }
    
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {
        // No updates needed
    }
}
