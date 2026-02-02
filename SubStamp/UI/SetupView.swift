import Speech
import SwiftUI
@preconcurrency import Translation

struct SetupView: View {
    @ObservedObject var assetManager: AssetReadinessManager
    @Binding var transcriptionLocaleIdentifier: String
    @Binding var language1Identifier: String
    @Binding var language2Identifier: String?
    @Binding var subtitle1Mode: TranslationMode?
    @Binding var subtitle2Mode: TranslationMode?
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

    var body: some View {
        ScrollView {
            VStack(spacing: AppSpacing.l) {
                WizardHeaderView(
                    step: 1,
                    total: 4,
                    title: "Setup languages",
                    subtitle: "Select your transcription and subtitle options."
                )

                audioLanguageCard
                subtitleSelectionCard
                readinessCard

                if !assetManager.isReadyToProceed {
                    downloadAssetsButton
                }
                continueButton
            }
            .padding(AppSpacing.l)
        }
        .background(AppColors.background)
        .task {
            speechAvailable = SpeechTranscriber.isAvailable
            
            // 1. Fetch Speech locales
            let speechLocales = await SpeechTranscriber.supportedLocales.sorted { 
                let name1 = $0.localizedString(forIdentifier: $0.identifier) ?? $0.identifier
                let name2 = $1.localizedString(forIdentifier: $1.identifier) ?? $1.identifier
                return name1 < name2
            }
            self.supportedSpeechLocales = speechLocales
            
            let installed = await SpeechTranscriber.installedLocales
            self.installedSpeechIDs = Set(installed.map { $0.identifier(.bcp47) })
            
            // 2. Initialize from existing bindings
            if language1Identifier == transcriptionLocaleIdentifier {
                selectedSubtitle1ID = "transcript"
            } else {
                selectedSubtitle1ID = language1Identifier
            }
            
            if let lang2 = language2Identifier {
                subtitle2Enabled = true
                selectedSubtitle2ID = lang2
            } else {
                subtitle2Enabled = false
            }
            
            await updateSubtitleTargets()
            updateAssetManager()
        }
        .translationTask(translationConfig) { session in
            guard shouldPrepareTranslation else { return }
            Task {
                await assetManager.downloadTranslationAssets(session: session)
                shouldPrepareTranslation = false
            }
        }
        .onChange(of: transcriptionLocaleIdentifier) { _, _ in
            Task {
                await updateSubtitleTargets()
                updateAssetManager()
            }
        }
        .onChange(of: selectedSubtitle1ID) { _, _ in
            updateAssetManager()
        }
        .onChange(of: subtitle2Enabled) { _, _ in
            updateAssetManager()
        }
        .onChange(of: selectedSubtitle2ID) { _, _ in
            updateAssetManager()
        }
    }

    private var audioLanguageCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            Text("Audio language")
                .font(AppTypography.bodyEmphasis)
            
            Picker("Audio language", selection: $transcriptionLocaleIdentifier) {
                ForEach(supportedSpeechLocales, id: \.identifier) { locale in
                    HStack {
                        Text(audioLocaleLabel(locale))
                        Spacer()
                        if installedSpeechIDs.contains(locale.identifier(.bcp47)) {
                            Text("Installed")
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(AppColors.success.opacity(0.2))
                                .foregroundStyle(AppColors.success)
                                .clipShape(Capsule())
                        } else {
                            Text("Downloadable")
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(AppColors.warning.opacity(0.2))
                                .foregroundStyle(AppColors.warning)
                                .clipShape(Capsule())
                        }
                    }
                    .tag(locale.identifier)
                }
            }
            .pickerStyle(.menu)
            
            Text("Select the language spoken in the video to produce accurate subtitles.")
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

    private var subtitleSelectionCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.l) {
            // Subtitle 1 (Required)
            VStack(alignment: .leading, spacing: AppSpacing.s) {
                Text("Subtitle 1")
                    .font(AppTypography.bodyEmphasis)
                
                Picker("Target language", selection: $selectedSubtitle1ID) {
                    Text("Transcript (Audio Language)").tag("transcript")
                    ForEach(subtitleTargets) { target in
                        Text(targetLabel(target))
                            .tag(target.id)
                    }
                }
                .pickerStyle(.menu)
                
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
                        Picker("Target language", selection: $selectedSubtitle2ID) {
                            Text("Select language").tag(nil as String?)
                            ForEach(subtitleTargets) { target in
                                Text(targetLabel(target))
                                    .tag(target.id as String?)
                            }
                        }
                        .pickerStyle(.menu)
                        
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
            AssetStatusCard(title: "Speech assets", state: assetManager.speechAssetsState)
            AssetStatusCard(title: "Translation model", state: assetManager.translationAssetsState)
            
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

    private var downloadAssetsButton: some View {
        PrimaryButton(
            title: "Download required assets",
            systemImage: "arrow.down.circle",
            isEnabled: !assetManager.isBusy
        ) {
            Task {
                await assetManager.downloadSpeechAssets()
                
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
        PrimaryButton(
            title: "Continue",
            systemImage: "arrow.right.circle",
            isEnabled: assetManager.isReadyToProceed && (selectedSubtitle1ID != "") && (!subtitle2Enabled || (selectedSubtitle2ID != nil && selectedSubtitle2ID != ""))
        ) {
            // Update bindings
            language1Identifier = (selectedSubtitle1ID == "transcript") ? transcriptionLocaleIdentifier : selectedSubtitle1ID
            language2Identifier = subtitle2Enabled ? selectedSubtitle2ID : nil
            
            // Mode 1
            if selectedSubtitle1ID == "transcript" {
                subtitle1Mode = nil
            } else if let option = subtitleTargets.first(where: { $0.id == selectedSubtitle1ID }) {
                subtitle1Mode = option.mode
            }
            
            // Mode 2
            if subtitle2Enabled, let targetID = selectedSubtitle2ID,
               let option = subtitleTargets.first(where: { $0.id == targetID }) {
                subtitle2Mode = option.mode
            } else {
                subtitle2Mode = nil
            }
            
            onContinue()
        }
    }

    // MARK: - Helpers

    private func audioLocaleLabel(_ locale: Locale) -> String {
        let name = locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
        return "\(name) (\(locale.identifier(.bcp47)))"
    }

    private func targetLabel(_ target: TargetOption) -> String {
        var label = target.displayName
        if target.mode == .pivot {
            label += " (via English)"
        }
        return label
    }

    private func updateSubtitleTargets() async {
        let audioLocale = Locale(identifier: transcriptionLocaleIdentifier)
        subtitleTargets = await selectionLogic.computeTargets(for: audioLocale)
        
        // Validation
        if selectedSubtitle1ID != "transcript" && !subtitleTargets.contains(where: { $0.id == selectedSubtitle1ID }) {
            selectedSubtitle1ID = "transcript"
        }
        if let current = selectedSubtitle2ID, !subtitleTargets.contains(where: { $0.id == current }) {
            selectedSubtitle2ID = nil
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
        if subtitle2Enabled, let targetID = selectedSubtitle2ID,
           let option = subtitleTargets.first(where: { $0.id == targetID }) {
            let targetLang = Locale.Language(identifier: targetID)
            if option.mode == .direct {
                s2 = .direct(targetLang)
            } else {
                s2 = .pivot(pivot: Locale.Language(identifier: "en-US"), target: targetLang)
            }
        }
        
        let config = LanguageSelectionConfig(
            audioLocale: audioLocale,
            subtitle1: s1,
            subtitle2: s2
        )
        assetManager.configure(with: config)
        Task { await assetManager.check() }
    }
}
