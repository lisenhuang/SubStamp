import Speech
import SwiftUI
@preconcurrency import Translation

struct SetupView: View {
    @ObservedObject var assetManager: AssetReadinessManager
    @Binding var transcriptionLocale: Locale
    @Binding var subtitleMode: SubtitleMode
    @Binding var translationTarget: Locale.Language?
    var onContinue: () -> Void

    @State private var supportedLocales: [Locale] = []
    @State private var translationLanguages: [Locale.Language] = []
    @State private var translationConfig: TranslationSession.Configuration?
    @State private var shouldPrepareTranslation = false

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
                subtitleModeCard
                readinessCard

                downloadAssetsButton
                continueButton
            }
            .padding(AppSpacing.l)
        }
        .background(AppColors.background)
        .task {
            supportedLocales = await SpeechTranscriber.supportedLocales.sorted { $0.identifier < $1.identifier }
            let availability = LanguageAvailability()
            let languages = await availability.supportedLanguages
            translationLanguages = languages.sorted { $0.minimalIdentifier < $1.minimalIdentifier }
            if translationTarget == nil {
                translationTarget = translationLanguages.first
            }
            assetManager.configure(
                transcriptionLocale: transcriptionLocale,
                subtitleMode: subtitleMode,
                translationTargetLocale: translationTarget
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
        .onChange(of: transcriptionLocale) { _, newValue in
            assetManager.configure(
                transcriptionLocale: newValue,
                subtitleMode: subtitleMode,
                translationTargetLocale: translationTarget
            )
            Task { await assetManager.check() }
        }
        .onChange(of: subtitleMode) { _, newValue in
            assetManager.configure(
                transcriptionLocale: transcriptionLocale,
                subtitleMode: newValue,
                translationTargetLocale: translationTarget
            )
            Task { await assetManager.check() }
        }
        .onChange(of: translationTarget) { _, newValue in
            assetManager.configure(
                transcriptionLocale: transcriptionLocale,
                subtitleMode: subtitleMode,
                translationTargetLocale: newValue
            )
            Task { await assetManager.check() }
        }
    }

    private var transcriptionLocaleCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            Text("Audio language")
                .font(AppTypography.bodyEmphasis)
            Picker("Transcription language", selection: $transcriptionLocale) {
                ForEach(supportedLocales, id: \.identifier) { locale in
                    Text(locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
                        .tag(locale)
                }
            }
            .pickerStyle(.menu)
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

    private var subtitleModeCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            Text("Subtitle mode")
                .font(AppTypography.bodyEmphasis)
            Picker("Subtitle mode", selection: $subtitleMode) {
                Text("Transcript only").tag(SubtitleMode.single)
                Text("Bilingual").tag(SubtitleMode.bilingual)
            }
            .pickerStyle(.segmented)

            if subtitleMode == .bilingual {
                Text("Translation language")
                    .font(AppTypography.bodyEmphasis)
                    .padding(.top, AppSpacing.s)
                Picker("Translation target", selection: translationSelection) {
                    ForEach(translationLanguages, id: \.minimalIdentifier) { language in
                        let languageCode = language.languageCode?.identifier ?? language.minimalIdentifier
                        Text(Locale.current.localizedString(forLanguageCode: languageCode) ?? language.minimalIdentifier)
                            .tag(language)
                    }
                }
                .pickerStyle(.menu)
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
                    transcriptionLocale: transcriptionLocale,
                    subtitleMode: subtitleMode,
                    translationTargetLocale: translationTarget
                )
                await assetManager.downloadSpeechAssets()
                if subtitleMode == .bilingual {
                    shouldPrepareTranslation = true
                    translationConfig = TranslationSession.Configuration(
                        source: Locale.Language(identifier: transcriptionLocale.identifier),
                        target: translationTarget ?? Locale.Language(identifier: "en")
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

    private var translationSelection: Binding<Locale.Language> {
        Binding(
            get: { translationTarget ?? translationLanguages.first ?? Locale.Language(identifier: "en") },
            set: { translationTarget = $0 }
        )
    }
}
