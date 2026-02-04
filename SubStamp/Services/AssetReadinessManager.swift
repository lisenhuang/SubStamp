import Foundation
import Combine
import FoundationModels
import Speech
import Translation

@MainActor
final class AssetReadinessManager: ObservableObject {
    @Published var config: LanguageSelectionConfig?
    @Published var speechAssetsState: AssetState = .notInstalled
    @Published var translationAssetsState: AssetState = .notInstalled
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

    func configure(with config: LanguageSelectionConfig) {
        let changed = self.config?.audioLocale.identifier != config.audioLocale.identifier ||
                      self.config?.translationProvider != config.translationProvider ||
                      self.config?.selectedSubtitle1ID != config.selectedSubtitle1ID ||
                      self.config?.subtitle2Enabled != config.subtitle2Enabled ||
                      self.config?.selectedSubtitle2ID != config.selectedSubtitle2ID
        
        self.config = config
        if changed {
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
        guard let config = config else { return }
        checkStorage()
        
        await performCheck(for: config)
        
        // If we found something not installed, do a quick double-check after a tiny delay
        // This handles cases where the framework is still warming up its internal status cache
        // which often happens right after app launch or when returning to the view.
        if !isReadyToProceed {
            try? await Task.sleep(nanoseconds: 600_000_000) // 0.6s
            if !isReadyToProceed {
                await performCheck(for: config)
            }
        }
    }

    private func performCheck(for config: LanguageSelectionConfig) async {
        await checkSpeechAssets(for: config.audioLocale)
        
        var neededTargets: [Locale.Language] = []
        let tracks: [LanguageSelectionConfig.SubtitleTrackConfig] = [config.subtitle1, config.subtitle2].compactMap { $0 }
        
        for track in tracks {
            switch track {
            case .transcript: break
            case .direct(let target):
                neededTargets.append(target)
            case .pivot(let pivot, let target):
                neededTargets.append(pivot)
                neededTargets.append(target)
            }
        }
        
        if neededTargets.isEmpty {
            translationAssetsState = .ready
            return
        }

        switch config.translationProvider {
        case .translationFramework:
            await checkAllTranslationAssets(source: config.audioLocale, targets: neededTargets)
        case .appleIntelligence:
            await checkAppleIntelligenceAvailability(source: config.audioLocale, targets: neededTargets)
        }
    }

    private func checkAppleIntelligenceAvailability(source: Locale, targets: [Locale.Language]) async {
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            lastError = .translationError(underlying: NSError(
                domain: "SubStamp",
                code: -200,
                userInfo: [NSLocalizedDescriptionKey: "Apple Intelligence is not available on this device."]
            ))
            translationAssetsState = .failed(message: "Apple Intelligence unavailable.")
            return
        }

        let sourceLang = Locale.Language(identifier: source.identifier)
        let supported = model.supportedLanguages.map { $0.minimalIdentifier }
        guard supported.contains(sourceLang.minimalIdentifier) else {
            lastError = .translationError(underlying: NSError(
                domain: "SubStamp",
                code: -201,
                userInfo: [NSLocalizedDescriptionKey: "Apple Intelligence doesn't support the selected audio language."]
            ))
            translationAssetsState = .failed(message: "Audio language unsupported.")
            return
        }

        for target in targets {
            if !supported.contains(target.minimalIdentifier) {
                let label = target.languageCode?.identifier ?? target.minimalIdentifier
                lastError = .unsupportedLanguagePair(from: source.identifier, to: label)
                translationAssetsState = .failed(message: "Target language unsupported.")
                return
            }
        }

        translationAssetsState = .ready
    }

    func downloadSpeechAssets() async {
        guard let config = config else { return }
        let transcriber = SpeechTranscriber(
            locale: config.audioLocale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        speechAssetsState = .downloading(progress: 0)
        do {
            if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await downloader.downloadAndInstall()
            }
            await checkSpeechAssets(for: config.audioLocale)
        } catch {
            lastError = .assetInstallFailed(locale: config.audioLocale.identifier)
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
        let requestedBCP47 = locale.identifier(.bcp47)
        let installed = await SpeechTranscriber.installedLocales
        
        // 1. Check for exact BCP47 match in installed locales
        if installed.contains(where: { $0.identifier(.bcp47) == requestedBCP47 }) {
            speechAssetsState = .ready
            return
        }
        
        // 2. Fallback: check if the base language is installed (e.g., "en" matches "en-US")
        let requestedLang = locale.language.languageCode?.identifier ?? String(requestedBCP47.prefix(2))
        if installed.contains(where: { $0.language.languageCode?.identifier == requestedLang }) {
            speechAssetsState = .ready
            return
        }
        
        // 3. Not found in installed, check if it's at least supported/downloadable
        let supported = await SpeechTranscriber.supportedLocales
        if supported.contains(where: { 
            $0.identifier(.bcp47) == requestedBCP47 || 
            $0.language.languageCode?.identifier == requestedLang 
        }) {
            speechAssetsState = .notInstalled
        } else {
            speechAssetsState = .failed(message: "Language not supported on this device.")
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
