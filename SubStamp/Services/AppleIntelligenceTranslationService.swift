import Foundation
import FoundationModels

@available(iOS 26.0, *)
final class AppleIntelligenceTranslationService {
    @Generable
    struct CueTranslation {
        var id: String
        var text: String
    }

    @Generable
    struct CueTranslationResponse {
        var translations: [CueTranslation]
    }

    private let model: SystemLanguageModel
    private let maxCuesPerChunk = 12
    private let maxCharactersPerChunk = 1800

    init(model: SystemLanguageModel = .default) {
        self.model = model
    }

    func translate(
        cues: [SubtitleCue],
        source: Locale,
        target: Locale.Language,
        progressHandler: @escaping (Int, Int) -> Void
    ) async throws -> [SubtitleCue] {
        guard model.isAvailable else {
            throw SubStampError.translationError(underlying: NSError(
                domain: "SubStamp",
                code: -210,
                userInfo: [NSLocalizedDescriptionKey: "Apple Intelligence is not available."]
            ))
        }

        let sourceLabel = Locale.current.localizedString(forIdentifier: source.identifier) ?? source.identifier
        let targetLabel = Locale.current.localizedString(forIdentifier: target.minimalIdentifier) ?? target.minimalIdentifier

        var output = cues
        progressHandler(0, cues.count)

        var completed = Set<UUID>()
        let chunks = makeChunks(from: cues)

        for chunk in chunks {
            do {
                let translations = try await translateChunk(chunk, sourceLabel: sourceLabel, targetLabel: targetLabel)
                for (cueID, translated) in translations {
                    guard let index = output.firstIndex(where: { $0.id == cueID }) else { continue }
                    output[index].secondaryText = SubtitleTextCleaner.clean(translated)
                    output[index].hasTranslationError = false
                    completed.insert(cueID)
                }
                progressHandler(completed.count, cues.count)
            } catch {
                // We'll fall back per-cue below for anything missing.
                continue
            }
        }

        for index in output.indices {
            if output[index].secondaryText != nil { continue }
            do {
                let translated = try await translateSingle(text: output[index].primaryText, sourceLabel: sourceLabel, targetLabel: targetLabel)
                output[index].secondaryText = SubtitleTextCleaner.clean(translated)
                output[index].hasTranslationError = false
            } catch {
                output[index].secondaryText = nil
                output[index].hasTranslationError = true
            }
            completed.insert(output[index].id)
            progressHandler(completed.count, cues.count)
        }

        return output
    }

    private func makeChunks(from cues: [SubtitleCue]) -> [[SubtitleCue]] {
        var chunks: [[SubtitleCue]] = []
        var current: [SubtitleCue] = []
        var currentChars = 0

        for cue in cues {
            let overhead = 60 + cue.id.uuidString.count
            let estimated = cue.primaryText.count + overhead
            let wouldExceed = !current.isEmpty && (
                current.count >= maxCuesPerChunk || (currentChars + estimated) > maxCharactersPerChunk
            )
            if wouldExceed {
                chunks.append(current)
                current = []
                currentChars = 0
            }
            current.append(cue)
            currentChars += estimated
        }

        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    private func translateChunk(_ cues: [SubtitleCue], sourceLabel: String, targetLabel: String) async throws -> [UUID: String] {
        let session = LanguageModelSession(model: model) {
            """
            You are a subtitle translator.
            - Translate faithfully and naturally.
            - Keep translations concise for on-screen subtitles.
            - Do not merge cues and do not add commentary.
            - Keep each cue aligned by ID.
            """
        }

        let cueBlock = cues.map { cue in
            let text = cue.primaryText.replacingOccurrences(of: "\n", with: "\\n")
            return "- id: \(cue.id.uuidString)\n  text: \(text)"
        }.joined(separator: "\n")

        let prompt = """
        Translate the following subtitle cues from \(sourceLabel) to \(targetLabel).
        Return translations for every cue.

        CUES:
        \(cueBlock)
        """

        let response = try await session.respond(to: prompt, generating: CueTranslationResponse.self)

        var output: [UUID: String] = [:]
        for item in response.content.translations {
            guard let id = UUID(uuidString: item.id) else { continue }
            let restored = item.text.replacingOccurrences(of: "\\n", with: "\n")
            output[id] = restored
        }
        return output
    }

    private func translateSingle(text: String, sourceLabel: String, targetLabel: String) async throws -> String {
        let session = LanguageModelSession(model: model) {
            "Translate subtitles concisely and naturally."
        }
        let prompt = """
        Translate from \(sourceLabel) to \(targetLabel).
        Text:
        \(text)
        """
        let response = try await session.respond(to: prompt)
        return response.content
    }
}
