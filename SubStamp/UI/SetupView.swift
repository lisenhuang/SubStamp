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
    @State private var speechAvailable = true
    @State private var showLog = false

    var body: some View {
        ScrollView {
            VStack(spacing: AppSpacing.l) {
                HStack {
                    Spacer()
                    Button {
                        showLog = true
                    } label: {
                        Image(systemName: "doc.text")
                            .font(AppTypography.bodyEmphasis)
                            .foregroundStyle(AppColors.secondaryText)
                    }
                }
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
                supportedLocales = [transcriptionLocale]
            } else if !supportedLocales.contains(where: { $0.identifier == transcriptionLocale.identifier }) {
                transcriptionLocale = supportedLocales.first ?? transcriptionLocale
            }
            if translationTarget == nil, let first = supportedLocales.first {
                translationTarget = Locale.Language(identifier: first.identifier)
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
        .sheet(isPresented: $showLog) {
            LogView()
        }
    }

    private var transcriptionLocaleCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            Text("Audio language")
                .font(AppTypography.bodyEmphasis)
            Picker("Transcription language", selection: $transcriptionLocale) {
                ForEach(supportedLocales, id: \.identifier) { locale in
                    Text(localeLabel(locale))
                        .tag(locale)
                }
            }
            .pickerStyle(.menu)
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
                Picker("Translation target", selection: translationLocaleSelection) {
                    ForEach(supportedLocales, id: \.identifier) { locale in
                        Text(localeLabel(locale))
                            .tag(locale)
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

    /// Translation target as a Locale so we can use the same list and labels as Audio language.
    private var translationLocaleSelection: Binding<Locale> {
        Binding(
            get: {
                guard let target = translationTarget else {
                    return supportedLocales.first ?? Locale.current
                }
                return supportedLocales.first { Locale.Language(identifier: $0.identifier) == target }
                    ?? supportedLocales.first ?? Locale.current
            },
            set: { translationTarget = Locale.Language(identifier: $0.identifier) }
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
