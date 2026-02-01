import Foundation
import Observation
import Speech
import Translation

@MainActor
@Observable
final class AssetReadinessManager {
    var transcriptionLocale: Locale = .current
    var subtitleMode: SubtitleMode = .single
    var translationTargetLocale: Locale.Language?

    var speechAssetsState: AssetState = .notInstalled
    var translationAssetsState: AssetState = .notInstalled
    var lastError: SubStampError?
    var lowStorageWarning: String?

    var isReadyToProceed: Bool {
        let speechReady = speechAssetsState == .ready
        let translationReady: Bool
        if subtitleMode == .bilingual {
            translationReady = translationAssetsState == .ready
        } else {
            translationReady = true
        }
        return speechReady && translationReady
    }

    func configure(
        transcriptionLocale: Locale,
        subtitleMode: SubtitleMode,
        translationTargetLocale: Locale.Language?
    ) {
        self.transcriptionLocale = transcriptionLocale
        self.subtitleMode = subtitleMode
        self.translationTargetLocale = translationTargetLocale
        reset()
    }

    func reset() {
        speechAssetsState = .notInstalled
        translationAssetsState = .notInstalled
        lastError = nil
    }

    func check() async {
        checkStorage()
        await checkSpeechAssets(for: transcriptionLocale)
        guard subtitleMode == .bilingual, let target = translationTargetLocale else {
            translationAssetsState = .ready
            return
        }
        await checkTranslationAssets(source: transcriptionLocale, target: target)
    }

    func downloadSpeechAssets() async {
        let transcriber = SpeechTranscriber(locale: transcriptionLocale, preset: .offlineTranscription)
        speechAssetsState = .downloading(progress: 0)
        do {
            if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await downloader.downloadAndInstall()
            }
            speechAssetsState = .ready
        } catch {
            lastError = .assetInstallFailed(locale: transcriptionLocale.identifier)
            speechAssetsState = .failed(message: error.localizedDescription)
        }
    }

    func downloadTranslationAssets(session: TranslationSession) async {
        guard subtitleMode == .bilingual, let target = translationTargetLocale else {
            translationAssetsState = .ready
            return
        }
        translationAssetsState = .downloading(progress: 0)
        do {
            try await session.prepareTranslation()
            translationAssetsState = .ready
        } catch {
            lastError = .translationError(underlying: error)
            translationAssetsState = .failed(message: error.localizedDescription)
        }
    }

    private func checkSpeechAssets(for locale: Locale) async {
        let supported = await SpeechTranscriber.supportedLocales
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

    private func checkTranslationAssets(source: Locale, target: Locale.Language) async {
        let sourceLanguage = Locale.Language(identifier: source.identifier)
        let availability = LanguageAvailability()
        let status = await availability.status(from: sourceLanguage, to: target)
        switch status {
        case .installed:
            translationAssetsState = .ready
        case .supported:
            translationAssetsState = .notInstalled
        case .unsupported:
            lastError = .unsupportedLanguagePair(from: source.identifier, to: target.identifier)
            translationAssetsState = .failed(message: "Language pair unsupported.")
        @unknown default:
            translationAssetsState = .failed(message: "Unknown translation availability.")
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
