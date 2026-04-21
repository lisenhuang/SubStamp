import Foundation
@preconcurrency import Translation
import Speech

enum TranslationMode: String, Codable, Sendable {
    case direct
    case pivot
}

struct TargetOption: Identifiable, Equatable, Codable, Sendable {
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
    func computeTargets(for source: Locale) async -> [TargetOption] {
        let sourceID = source.identifier(.bcp47)
        if let cached = targetsCache[sourceID] {
            return cached
        }
        if let persisted = SetupPreferences.loadCachedSubtitleTargets(
            for: source.identifier
        ) {
            targetsCache[sourceID] = persisted
            return persisted
        }

        let sortedOptions = await Self.computeFrameworkTargets(
            sourceIdentifier: source.identifier,
            displayLocaleIdentifier: Locale.current.identifier
        )
        targetsCache[sourceID] = sortedOptions
        SetupPreferences.saveCachedSubtitleTargets(sortedOptions, for: source.identifier)
        return sortedOptions
    }

    nonisolated private static func computeFrameworkTargets(
        sourceIdentifier: String,
        displayLocaleIdentifier: String
    ) async -> [TargetOption] {
        await Task.detached(priority: .userInitiated) {
            let availability = LanguageAvailability()
            let supportedLanguages = await availability.supportedLanguages
            let sourceLang = Locale.Language(identifier: sourceIdentifier)
            let englishLang = Locale.Language(identifier: "en-US")
            let displayLocale = Locale(identifier: displayLocaleIdentifier)

            var options: [TargetOption] = []
            var seenIDs = Set<String>()

            for target in supportedLanguages {
                let targetID = target.minimalIdentifier
                if targetID == sourceLang.minimalIdentifier { continue }

                let directStatus = await availability.status(from: sourceLang, to: target)
                if directStatus == .installed || directStatus == .supported {
                    let option = TargetOption(
                        id: targetID,
                        displayName: displayLocale.localizedString(forIdentifier: targetID) ?? targetID,
                        mode: .direct
                    )
                    options.append(option)
                    seenIDs.insert(targetID)
                    continue
                }

                if targetID != englishLang.minimalIdentifier {
                    let leg1 = await availability.status(from: sourceLang, to: englishLang)
                    let leg2 = await availability.status(from: englishLang, to: target)

                    if (leg1 == .installed || leg1 == .supported) && (leg2 == .installed || leg2 == .supported) {
                        let option = TargetOption(
                            id: targetID,
                            displayName: displayLocale.localizedString(forIdentifier: targetID) ?? targetID,
                            mode: .pivot
                        )
                        if !seenIDs.contains(targetID) {
                            options.append(option)
                            seenIDs.insert(targetID)
                        }
                    }
                }
            }

            return options.sorted { $0.displayName < $1.displayName }
        }.value
    }
}
