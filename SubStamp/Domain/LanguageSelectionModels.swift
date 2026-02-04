import Foundation
@preconcurrency import Translation
import FoundationModels
import Speech

enum TranslationMode: String, Codable {
    case direct
    case pivot
}

struct TargetOption: Identifiable, Equatable {
    let id: String // Minimal identifier (BCP-47)
    let displayName: String
    let mode: TranslationMode
}

struct SelectionModel {
    var audioLocale: Locale
    var selectedTarget1Option: TargetOption? // nil means Transcript
    var subtitle2Enabled: Bool
    var selectedTarget2Option: TargetOption?
}

/// Final selection config object for the pipeline
struct LanguageSelectionConfig {
    let audioLocale: Locale
    let translationProvider: TranslationProvider
    let fixTranscriptionWithAppleIntelligence: Bool
    let subtitle1: SubtitleTrackConfig
    let subtitle2: SubtitleTrackConfig?
    
    var subtitle2Enabled: Bool {
        subtitle2 != nil
    }
    
    var selectedSubtitle1ID: String {
        switch subtitle1 {
        case .transcript: return "transcript"
        case .direct(let lang): return lang.minimalIdentifier
        case .pivot(_, let lang): return lang.minimalIdentifier
        }
    }
    
    var selectedSubtitle2ID: String? {
        guard let s2 = subtitle2 else { return nil }
        switch s2 {
        case .transcript: return "transcript"
        case .direct(let lang): return lang.minimalIdentifier
        case .pivot(_, let lang): return lang.minimalIdentifier
        }
    }
    
    enum SubtitleTrackConfig {
        case transcript(Locale)
        case direct(Locale.Language)
        case pivot(pivot: Locale.Language, target: Locale.Language)
    }
}

/// Helper to compute valid translation targets including pivots via English.
@MainActor
final class LanguageSelectionLogic {
    private var targetsCache: [String: [TargetOption]] = [:]
    
    /// Computes valid translation targets for a given source audio locale.
    func computeTargets(for source: Locale, provider: TranslationProvider) async -> [TargetOption] {
        let sourceID = "\(provider.rawValue)|\(source.identifier(.bcp47))"
        if let cached = targetsCache[sourceID] {
            return cached
        }
        
        if provider == .appleIntelligence {
            let options = computeAppleIntelligenceTargets(for: source)
            targetsCache[sourceID] = options
            return options
        }

        let supportedLanguages = await fetchSupportedLanguages()
        let sourceLang = Locale.Language(identifier: source.identifier)
        let englishLang = Locale.Language(identifier: "en-US")
        
        var options: [TargetOption] = []
        var seenIDs = Set<String>()
        
        for target in supportedLanguages {
            let targetID = target.minimalIdentifier
            
            if targetID == sourceLang.minimalIdentifier { continue }
            
            let directStatus = await checkStatus(from: sourceLang, to: target)
            if directStatus == .installed || directStatus == .supported {
                let option = TargetOption(
                    id: targetID,
                    displayName: Locale.current.localizedString(forIdentifier: targetID) ?? targetID,
                    mode: .direct
                )
                options.append(option)
                seenIDs.insert(targetID)
                continue
            }
            
            if targetID != englishLang.minimalIdentifier {
                let leg1 = await checkStatus(from: sourceLang, to: englishLang)
                let leg2 = await checkStatus(from: englishLang, to: target)
                
                if (leg1 == .installed || leg1 == .supported) && (leg2 == .installed || leg2 == .supported) {
                    let option = TargetOption(
                        id: targetID,
                        displayName: Locale.current.localizedString(forIdentifier: targetID) ?? targetID,
                        mode: .pivot
                    )
                    if !seenIDs.contains(targetID) {
                        options.append(option)
                        seenIDs.insert(targetID)
                    }
                }
            }
        }
        
        let sortedOptions = options.sorted { $0.displayName < $1.displayName }
        targetsCache[sourceID] = sortedOptions
        return sortedOptions
    }

    private func computeAppleIntelligenceTargets(for source: Locale) -> [TargetOption] {
        // Apple Intelligence uses the system language model; only show supported languages (direct mode only).
        // If Apple Intelligence is unavailable, we return an empty list and SetupView will fall back.
        guard let model = appleIntelligenceModelIfAvailable() else {
#if DEBUG
            let prefix = "[AI-DETECT]"
            let defaultModel = SystemLanguageModel.default
            AppLog.append("\(prefix) computeTargets(provider=appleIntelligence) unavailable isAvailable=\(defaultModel.isAvailable) availability=\(defaultModel.availability) source=\(source.identifier(.bcp47)) supportsLocale(source)=\(defaultModel.supportsLocale(source))")
#endif
            return []
        }
        let sourceLang = Locale.Language(identifier: source.identifier)

        let options: [TargetOption] = model.supportedLanguages
            .filter { $0.minimalIdentifier != sourceLang.minimalIdentifier }
            .map { language in
                let id = language.minimalIdentifier
                return TargetOption(
                    id: id,
                    displayName: Locale.current.localizedString(forIdentifier: id) ?? id,
                    mode: .direct
                )
            }
            .sorted { $0.displayName < $1.displayName }

#if DEBUG
        let prefix = "[AI-DETECT]"
        let supportedCount = model.supportedLanguages.count
        let sample = model.supportedLanguages.map { $0.minimalIdentifier }.prefix(12).joined(separator: ", ")
        AppLog.append("\(prefix) computeTargets(provider=appleIntelligence) isAvailable=true availability=\(model.availability) source=\(source.identifier(.bcp47)) supportsLocale(source)=\(model.supportsLocale(source)) supportedCount=\(supportedCount) options=\(options.count) sample=\(sample)")
#endif
        return options
    }

    private func appleIntelligenceModelIfAvailable() -> SystemLanguageModel? {
        let model = SystemLanguageModel.default
        return model.isAvailable ? model : nil
    }

    private nonisolated func fetchSupportedLanguages() async -> [Locale.Language] {
        let availability = LanguageAvailability()
        return await availability.supportedLanguages
    }
    
    private nonisolated func checkStatus(from source: Locale.Language, to target: Locale.Language) async -> LanguageAvailability.Status {
        let availability = LanguageAvailability()
        return await availability.status(from: source, to: target)
    }
}
