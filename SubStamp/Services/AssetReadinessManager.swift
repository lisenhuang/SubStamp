import Foundation
import Combine
import Speech
import Translation

@MainActor
final class AssetReadinessManager: ObservableObject {
    @Published var transcriptionLocale: Locale = .current
    @Published var language1Locale: Locale.Language = Locale.Language(identifier: Locale.current.identifier)
    @Published var language2Locale: Locale.Language?
    @Published var subtitleMode: SubtitleMode = .single

    @Published var speechAssetsState: AssetState = .notInstalled
    @Published var translationAssetsState: AssetState = .notInstalled // Combined state for all needed translation models
    @Published var lastError: SubStampError?
    @Published var lowStorageWarning: String?

    var isReadyToProceed: Bool {
        let speechReady = speechAssetsState == .ready
        let translationReady = translationAssetsState == .ready
        return speechReady && translationReady
    }

    var isBusy: Bool {
        if case .downloading = speechAssetsState { return true }
        if case .downloading = translationAssetsState { return true }
        return false
    }

    func configure(
        transcriptionLocale: Locale,
        language1Locale: Locale.Language,
        language2Locale: Locale.Language?,
        subtitleMode: SubtitleMode
    ) {
        let transcriptionChanged = self.transcriptionLocale.identifier != transcriptionLocale.identifier
        let lang1Changed = self.language1Locale.minimalIdentifier != language1Locale.minimalIdentifier
        let lang2Changed = self.language2Locale?.minimalIdentifier != language2Locale?.minimalIdentifier
        
        self.transcriptionLocale = transcriptionLocale
        self.language1Locale = language1Locale
        self.language2Locale = language2Locale
        self.subtitleMode = subtitleMode
        
        if transcriptionChanged || lang1Changed || lang2Changed {
            reset()
        }
    }

    func reset() {
        speechAssetsState = .notInstalled
        translationAssetsState = .notInstalled
        lastError = nil
    }

    func setTranslationDownloading() {
        translationAssetsState = .downloading(progress: 0)
    }

    func check() async {
        checkStorage()
        await checkSpeechAssets(for: transcriptionLocale)
        
        // Find which translations are actually needed
        var neededTargets: [Locale.Language] = []
        let sourceLang = Locale.Language(identifier: transcriptionLocale.identifier)
        
        // If Lang 1 != Transcription Lang, we need Lang 1 assets
        if language1Locale.minimalIdentifier != sourceLang.minimalIdentifier {
            neededTargets.append(language1Locale)
        }
        
        // If Lang 2 exists and != Transcription Lang, we need Lang 2 assets
        if let l2 = language2Locale, l2.minimalIdentifier != sourceLang.minimalIdentifier {
            neededTargets.append(l2)
        }
        
        if neededTargets.isEmpty {
            translationAssetsState = .ready
            return
        }
        
        await checkAllTranslationAssets(source: transcriptionLocale, targets: neededTargets)
    }

    func downloadSpeechAssets() async {
        let transcriber = SpeechTranscriber(
            locale: transcriptionLocale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        speechAssetsState = .downloading(progress: 0)
        do {
            if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await downloader.downloadAndInstall()
            }
            // Verify the asset is actually installed after download
            await checkSpeechAssets(for: transcriptionLocale)
        } catch {
            lastError = .assetInstallFailed(locale: transcriptionLocale.identifier)
            speechAssetsState = .failed(message: error.localizedDescription)
        }
    }

    nonisolated func downloadTranslationAssets(session: TranslationSession) async {
        await MainActor.run {
            self.translationAssetsState = .downloading(progress: 0)
        }
        do {
            try await session.prepareTranslation()
            // Re-check everything
            await MainActor.run {
                Task {
                    await self.check()
                }
            }
        } catch {
            await MainActor.run {
                self.lastError = .translationError(underlying: error)
                self.translationAssetsState = .failed(message: error.localizedDescription)
            }
        }
    }

    private func checkSpeechAssets(for locale: Locale) async {
        let supported = await SpeechTranscriber.supportedLocales
        if supported.isEmpty {
            speechAssetsState = .failed(message: "Speech transcription isn't available.")
            return
        }
        let supportedIdentifiers = Set(supported.map { $0.identifier(.bcp47) })
        guard supportedIdentifiers.contains(locale.identifier(.bcp47)) else {
            speechAssetsState = .failed(message: "Language not supported.")
            return
        }

        let installed = await SpeechTranscriber.installedLocales
        let installedIdentifiers = Set(installed.map { $0.identifier(.bcp47) })
        if installedIdentifiers.contains(locale.identifier(.bcp47)) {
            speechAssetsState = .ready
        } else {
            speechAssetsState = .notInstalled
        }
    }

    private func checkAllTranslationAssets(source: Locale, targets: [Locale.Language]) async {
        let sourceLanguage = Locale.Language(identifier: source.identifier)
        let availability = LanguageAvailability()
        
        var allReady = true
        for target in targets {
            let status = await availability.status(from: sourceLanguage, to: target)
            if status != .installed {
                allReady = false
                if status == .supported {
                    translationAssetsState = .notInstalled
                } else {
                    let targetLabel = target.languageCode?.identifier ?? String(describing: target)
                    lastError = .unsupportedLanguagePair(from: source.identifier, to: targetLabel)
                    translationAssetsState = .failed(message: "Language pair unsupported.")
                    return
                }
            }
        }
        
        if allReady {
            translationAssetsState = .ready
        }
    }

    private func checkStorage() {
        let homeURL = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? homeURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values?.volumeAvailableCapacityForImportantUsage, available < 1_000_000_000 {
            lowStorageWarning = "Low storage detected. Downloads may fail."
        } else {
            lowStorageWarning = nil
        }
    }
}
