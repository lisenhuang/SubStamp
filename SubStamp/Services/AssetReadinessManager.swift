import Foundation
import Combine
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
        await checkAllTranslationAssets(source: config.audioLocale, targets: neededTargets)
    }

    func downloadSpeechAssets() async {
        guard let config = config else { return }
        let requestedLocale = config.audioLocale

        if #available(iOS 26.0, *), DevSettings.useModernAPIs {
            let requestedBCP47 = requestedLocale.identifier(.bcp47)
            let requestedLanguage = requestedLocale.language.languageCode?.identifier ?? String(requestedBCP47.prefix(2))
            let installedBefore = await SpeechTranscriber.installedLocales
            let supportedBefore = await SpeechTranscriber.supportedLocales

            AppLog.append("[ASSET][speech] download(start) locale=\(requestedLocale.identifier) bcp47=\(requestedBCP47) lang=\(requestedLanguage)")
            AppLog.append("[ASSET][speech] download(precheck) installedCount=\(installedBefore.count) supportedCount=\(supportedBefore.count)")
            AppLog.append("[ASSET][speech] download(precheck) installed=\(installedBefore.map { $0.identifier }.joined(separator: ", "))")

            let transcriber = SpeechTranscriber(
                locale: requestedLocale,
                transcriptionOptions: [],
                reportingOptions: [],
                attributeOptions: [.audioTimeRange]
            )
            speechAssetsState = .downloading(progress: 0)
            do {
                AppLog.append("[ASSET][speech] download(request) creating AssetInventory request for locale=\(requestedLocale.identifier)")
                if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    AppLog.append("[ASSET][speech] download(request) request-created locale=\(requestedLocale.identifier)")
                    AppLog.append("[ASSET][speech] download(install) begin locale=\(requestedLocale.identifier)")
                    try await downloader.downloadAndInstall()
                    AppLog.append("[ASSET][speech] download(install) success locale=\(requestedLocale.identifier)")
                } else {
                    AppLog.append("[ASSET][speech] download(request) no-install-request locale=\(requestedLocale.identifier) (already installed or unavailable)")
                }
                await checkSpeechAssets(for: requestedLocale)
                let installedAfter = await SpeechTranscriber.installedLocales
                AppLog.append("[ASSET][speech] download(postcheck) installedCount=\(installedAfter.count) state=\(speechAssetsState.logDescription)")
                AppLog.append("[ASSET][speech] download(postcheck) installed=\(installedAfter.map { $0.identifier }.joined(separator: ", "))")
            } catch {
                let nsError = error as NSError
                AppLog.append("[ASSET][speech] download(failed) locale=\(requestedLocale.identifier) domain=\(nsError.domain) code=\(nsError.code) desc=\(nsError.localizedDescription)")
                AppLog.append("[ASSET][speech] download(failed) reason=\(nsError.localizedFailureReason ?? "nil") suggestion=\(nsError.localizedRecoverySuggestion ?? "nil")")
                AppLog.append("[ASSET][speech] download(failed) userInfoKeys=\(nsError.userInfo.keys.map { String(describing: $0) }.sorted().joined(separator: ", "))")
                if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                    AppLog.append("[ASSET][speech] download(failed) underlying=\(underlying.domain)(\(underlying.code)) \(underlying.localizedDescription)")
                }
                lastError = .assetInstallFailed(locale: requestedLocale.identifier)
                speechAssetsState = .failed(message: error.localizedDescription)
            }
        } else {
            // iOS 18–25: SFSpeechRecognizer downloads models automatically on first use.
            // Just re-check the locale availability and mark as ready if supported.
            AppLog.append("[ASSET][speech] download(legacy) SFSpeechRecognizer path locale=\(requestedLocale.identifier)")
            speechAssetsState = .downloading(progress: 0.5)
            await checkSpeechAssets(for: requestedLocale)
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
        if #available(iOS 26.0, *), DevSettings.useModernAPIs {
            let requestedBCP47 = locale.identifier(.bcp47)
            let installed = await SpeechTranscriber.installedLocales
            AppLog.append("[ASSET][speech] check locale=\(locale.identifier) bcp47=\(requestedBCP47) installedCount=\(installed.count)")

            if installed.contains(where: { $0.identifier(.bcp47) == requestedBCP47 }) {
                speechAssetsState = .ready
                AppLog.append("[ASSET][speech] check result=ready exactMatch locale=\(locale.identifier)")
                return
            }

            let requestedLang = locale.language.languageCode?.identifier ?? String(requestedBCP47.prefix(2))
            if installed.contains(where: { $0.language.languageCode?.identifier == requestedLang }) {
                speechAssetsState = .ready
                AppLog.append("[ASSET][speech] check result=ready baseLanguageMatch locale=\(locale.identifier) lang=\(requestedLang)")
                return
            }

            let supported = await SpeechTranscriber.supportedLocales
            if supported.contains(where: {
                $0.identifier(.bcp47) == requestedBCP47 ||
                $0.language.languageCode?.identifier == requestedLang
            }) {
                speechAssetsState = .notInstalled
                AppLog.append("[ASSET][speech] check result=notInstalled locale=\(locale.identifier) lang=\(requestedLang)")
            } else {
                speechAssetsState = .failed(message: "Language not supported on this device.")
                AppLog.append("[ASSET][speech] check result=failed unsupported locale=\(locale.identifier) lang=\(requestedLang)")
            }
        } else {
            // iOS 18–25: use SFSpeechRecognizer to determine locale support.
            // SFSpeechRecognizer manages model downloads automatically on first use,
            // so if the locale is in supportedLocales we treat it as ready.
            let legacySupported = SFSpeechRecognizer.supportedLocales()
            let requestedBCP47 = locale.identifier(.bcp47)
            let requestedLang = locale.language.languageCode?.identifier ?? String(requestedBCP47.prefix(2))
            AppLog.append("[ASSET][speech] check(legacy) locale=\(locale.identifier) supportedCount=\(legacySupported.count)")

            let isSupported = legacySupported.contains(where: {
                $0.identifier == locale.identifier ||
                $0.identifier == requestedBCP47 ||
                ($0.language.languageCode?.identifier == requestedLang)
            })

            if isSupported {
                // Mark as ready — SFSpeechRecognizer on-demand downloads happen transparently
                speechAssetsState = .ready
                AppLog.append("[ASSET][speech] check(legacy) result=ready locale=\(locale.identifier)")
            } else {
                speechAssetsState = .failed(message: "Language not supported on this device.")
                AppLog.append("[ASSET][speech] check(legacy) result=failed unsupported locale=\(locale.identifier)")
            }
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

private extension AssetState {
    var logDescription: String {
        switch self {
        case .notInstalled:
            return "notInstalled"
        case .ready:
            return "ready"
        case .downloading(let progress):
            return "downloading(\(progress))"
        case .failed(let message):
            return "failed(\(message))"
        }
    }
}
