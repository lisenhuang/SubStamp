import Speech
import SwiftUI
@preconcurrency import Translation

struct SetupView: View {
    @ObservedObject var assetManager: AssetReadinessManager
    @Binding var transcriptionLocaleIdentifier: String
    @Binding var subtitleMode: SubtitleMode
    @Binding var translationLocaleIdentifier: String?
    var onContinue: () -> Void

    @State private var supportedLocales: [Locale] = []
    @State private var translationLanguages: [Locale.Language] = []
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
            if translationLocaleIdentifier == nil, let first = supportedLocales.first {
                translationLocaleIdentifier = first.identifier
            } else if let tid = translationLocaleIdentifier, !supportedLocales.contains(where: { $0.identifier == tid }) {
                translationLocaleIdentifier = supportedLocales.first?.identifier
            }
            assetManager.configure(
                transcriptionLocale: Locale(identifier: transcriptionLocaleIdentifier),
                subtitleMode: subtitleMode,
                translationTargetLocale: translationLocaleIdentifier.map { Locale.Language(identifier: $0) }
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
                translationTargetLocale: translationLocaleIdentifier.map { Locale.Language(identifier: $0) }
            )
            Task { await assetManager.check() }
        }
        .onChange(of: subtitleMode) { _, newValue in
            assetManager.configure(
                transcriptionLocale: Locale(identifier: transcriptionLocaleIdentifier),
                subtitleMode: newValue,
                translationTargetLocale: translationLocaleIdentifier.map { Locale.Language(identifier: $0) }
            )
            Task { await assetManager.check() }
        }
        .onChange(of: translationLocaleIdentifier) { _, newValue in
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
                Picker("Translation target", selection: translationLocaleIdentifierBinding) {
                    ForEach(supportedLocales, id: \.identifier) { locale in
                        Text(localeLabel(locale))
                            .tag(locale.identifier)
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
                    transcriptionLocale: Locale(identifier: transcriptionLocaleIdentifier),
                    subtitleMode: subtitleMode,
                    translationTargetLocale: translationLocaleIdentifier.map { Locale.Language(identifier: $0) }
                )
                await assetManager.downloadSpeechAssets()
                if subtitleMode == .bilingual {
                    shouldPrepareTranslation = true
                    translationConfig = TranslationSession.Configuration(
                        source: Locale.Language(identifier: transcriptionLocaleIdentifier),
                        target: Locale.Language(identifier: translationLocaleIdentifier ?? "en")
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

    /// Non-optional binding for translation picker; uses first locale when nil.
    private var translationLocaleIdentifierBinding: Binding<String> {
        Binding(
            get: {
                translationLocaleIdentifier ?? supportedLocales.first?.identifier ?? Locale.current.identifier
            },
            set: { translationLocaleIdentifier = $0 }
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
