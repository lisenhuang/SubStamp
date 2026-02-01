import Speech
import SwiftUI
@preconcurrency import Translation

struct SetupView: View {
    @ObservedObject var assetManager: AssetReadinessManager
    @Binding var transcriptionLocaleIdentifier: String
    @Binding var language1Identifier: String
    @Binding var language2Identifier: String?
    var onContinue: () -> Void

    @State private var supportedLocales: [Locale] = []
    @State private var translationLanguages: [Locale.Language] = []
    @State private var translationConfig: TranslationSession.Configuration?
    @State private var shouldPrepareTranslation = false
    @State private var speechAvailable = true
    
    /// Derived subtitle mode based on whether language2 is selected
    private var subtitleMode: SubtitleMode {
        language2Identifier != nil ? .bilingual : .single
    }

    var body: some View {
        ScrollView {
            VStack(spacing: AppSpacing.l) {
                WizardHeaderView(
                    step: 1,
                    total: 4,
                    title: "Setup languages",
                    subtitle: "Select your transcription and subtitle options."
                )

                transcriptionLocaleCard
                languageSelectionCard
                readinessCard

                downloadAssetsButton
                continueButton
            }
            .padding(AppSpacing.l)
        }
        .background(AppColors.background)
        .task {
            speechAvailable = SpeechTranscriber.isAvailable
            supportedLocales = await SpeechTranscriber.supportedLocales.sorted { $0.identifier < $1.identifier }
            let availability = LanguageAvailability()
            let languages = await availability.supportedLanguages
            translationLanguages = languages.sorted { $0.minimalIdentifier < $1.minimalIdentifier }
            if supportedLocales.isEmpty {
                supportedLocales = [Locale(identifier: transcriptionLocaleIdentifier)]
            } else if !supportedLocales.contains(where: { $0.identifier == transcriptionLocaleIdentifier }) {
                transcriptionLocaleIdentifier = supportedLocales.first?.identifier ?? Locale.current.identifier
            }
            // Initialize language1 to audio language if not set
            if !supportedLocales.contains(where: { $0.identifier == language1Identifier }) {
                language1Identifier = transcriptionLocaleIdentifier
            }
            // Validate language2 if set
            if let lang2 = language2Identifier, !supportedLocales.contains(where: { $0.identifier == lang2 }) {
                language2Identifier = nil
            }
            assetManager.configure(
                transcriptionLocale: Locale(identifier: transcriptionLocaleIdentifier),
                subtitleMode: subtitleMode,
                translationTargetLocale: language2Identifier.map { Locale.Language(identifier: $0) }
            )
            await assetManager.check()
        }
        .translationTask(translationConfig) { session in
            guard shouldPrepareTranslation else { return }
            Task {
                await assetManager.downloadTranslationAssets(session: session)
                shouldPrepareTranslation = false
            }
        }
        .onChange(of: transcriptionLocaleIdentifier) { _, newValue in
            assetManager.configure(
                transcriptionLocale: Locale(identifier: newValue),
                subtitleMode: subtitleMode,
                translationTargetLocale: language2Identifier.map { Locale.Language(identifier: $0) }
            )
            Task { await assetManager.check() }
        }
        .onChange(of: language1Identifier) { _, _ in
            assetManager.configure(
                transcriptionLocale: Locale(identifier: transcriptionLocaleIdentifier),
                subtitleMode: subtitleMode,
                translationTargetLocale: language2Identifier.map { Locale.Language(identifier: $0) }
            )
            Task { await assetManager.check() }
        }
        .onChange(of: language2Identifier) { _, newValue in
            assetManager.configure(
                transcriptionLocale: Locale(identifier: transcriptionLocaleIdentifier),
                subtitleMode: subtitleMode,
                translationTargetLocale: newValue.map { Locale.Language(identifier: $0) }
            )
            Task { await assetManager.check() }
        }
    }

    private var transcriptionLocaleCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            Text("Audio language")
                .font(AppTypography.bodyEmphasis)
            Picker("Transcription language", selection: $transcriptionLocaleIdentifier) {
                ForEach(supportedLocales, id: \.identifier) { locale in
                    Text(localeLabel(locale))
                        .tag(locale.identifier)
                }
            }
            .pickerStyle(.menu)
            Text("Choose the language spoken in the video so the AI can produce accurate subtitles.")
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.secondaryText)
            if !speechAvailable {
                Text("Speech transcription isn't available on this device.")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.warning)
            } else if supportedLocales.isEmpty {
                Text("No language list available yet. Using device language.")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.secondaryText)
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

    private var languageSelectionCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            Text("Language 1")
                .font(AppTypography.bodyEmphasis)
            Picker("Language 1", selection: $language1Identifier) {
                ForEach(supportedLocales, id: \.identifier) { locale in
                    Text(localeLabel(locale))
                        .tag(locale.identifier)
                }
            }
            .pickerStyle(.menu)
            Text("Primary subtitle language")
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.secondaryText)

            Text("Language 2 (optional)")
                .font(AppTypography.bodyEmphasis)
                .padding(.top, AppSpacing.s)
            Picker("Language 2", selection: language2IdentifierBinding) {
                Text("None").tag("")
                ForEach(supportedLocales, id: \.identifier) { locale in
                    Text(localeLabel(locale))
                        .tag(locale.identifier)
                }
            }
            .pickerStyle(.menu)
            Text("Add a second language for bilingual subtitles")
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

    private var readinessCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            Text("Model readiness")
                .font(AppTypography.bodyEmphasis)
            AssetStatusCard(title: "Speech assets", state: assetManager.speechAssetsState)
            if subtitleMode == .bilingual {
                AssetStatusCard(title: "Translation model", state: assetManager.translationAssetsState)
            }
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
            systemImage: "arrow.down.circle"
        ) {
            Task {
                assetManager.configure(
                    transcriptionLocale: Locale(identifier: transcriptionLocaleIdentifier),
                    subtitleMode: subtitleMode,
                    translationTargetLocale: language2Identifier.map { Locale.Language(identifier: $0) }
                )
                await assetManager.downloadSpeechAssets()
                if subtitleMode == .bilingual, let lang2 = language2Identifier {
                    shouldPrepareTranslation = true
                    translationConfig = TranslationSession.Configuration(
                        source: Locale.Language(identifier: language1Identifier),
                        target: Locale.Language(identifier: lang2)
                    )
                }
            }
        }
    }

    private var continueButton: some View {
        PrimaryButton(
            title: "Continue",
            systemImage: "arrow.right.circle",
            isEnabled: assetManager.isReadyToProceed
        ) {
            onContinue()
        }
    }

    /// Binding for Language 2 picker - maps empty string to nil for the optional
    private var language2IdentifierBinding: Binding<String> {
        Binding(
            get: {
                language2Identifier ?? ""
            },
            set: { newValue in
                language2Identifier = newValue.isEmpty ? nil : newValue
            }
        )
    }

    private func localeLabel(_ locale: Locale) -> String {
        let label = locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
        if locale.identifier == Locale.current.identifier {
            return "Device language (\(label))"
        }
        return label
    }
}
