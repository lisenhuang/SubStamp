import Foundation
import Translation

final class TranslationService {
    private struct CueChunk {
        let cueIDs: [UUID]
        let sourceText: String
    }

    private let maxCuesPerChunk = 8
    private let maxCharactersPerChunk = 1200

    func translate(
        cues: [SubtitleCue],
        session: TranslationSession,
        progressHandler: @escaping (Int, Int) -> Void
    ) async throws -> [SubtitleCue] {
        var output = cues
        progressHandler(0, cues.count)

        var completedCueIDs = Set<UUID>()

        var indexByCueID: [UUID: Int] = [:]
        for index in output.indices where indexByCueID[output[index].id] == nil {
            indexByCueID[output[index].id] = index
        }
        let chunks = makeChunks(from: cues)

        // Process chunk-by-chunk instead of submitting one giant batch.
        // This avoids memory spikes and framework instability on large jobs (1000+ cues).
        for chunk in chunks {
            try Task.checkCancellation()
            do {
                let response = try await session.translate(chunk.sourceText)
                let extracted = extractChunkTranslations(translatedText: response.targetText, cueIDs: chunk.cueIDs)
                for cueID in chunk.cueIDs {
                    guard let index = indexByCueID[cueID], output.indices.contains(index) else { continue }
                    if let translated = extracted[cueID] {
                        output[index].secondaryText = SubtitleTextCleaner.clean(translated)
                        output[index].hasTranslationError = false
                        completedCueIDs.insert(cueID)
                    }
                }
                progressHandler(completedCueIDs.count, cues.count)
            } catch {
                // Fall back to per-cue translation below for any missing cues in this chunk.
                continue
            }
        }

        // Fallback for cues that weren't filled by chunk translation (e.g., marker parsing failed).
        for index in output.indices {
            try Task.checkCancellation()
            if output[index].secondaryText != nil { continue }
            do {
                let response = try await session.translate(output[index].primaryText)
                output[index].secondaryText = SubtitleTextCleaner.clean(response.targetText)
                output[index].hasTranslationError = false
            } catch {
                output[index].hasTranslationError = true
                output[index].secondaryText = nil
            }
            completedCueIDs.insert(output[index].id)
            progressHandler(completedCueIDs.count, cues.count)
        }

        return output
    }

    private func makeChunks(from cues: [SubtitleCue]) -> [CueChunk] {
        var chunks: [CueChunk] = []
        var currentCues: [SubtitleCue] = []
        var currentChars = 0

        for cue in cues {
            let estimated = cue.primaryText.count + 2 * markerStart(for: cue.id).count + 8
            let wouldExceed = !currentCues.isEmpty && (
                currentCues.count >= maxCuesPerChunk || (currentChars + estimated) > maxCharactersPerChunk
            )
            if wouldExceed {
                chunks.append(buildChunk(from: currentCues))
                currentCues = []
                currentChars = 0
            }
            currentCues.append(cue)
            currentChars += estimated
        }

        if !currentCues.isEmpty {
            chunks.append(buildChunk(from: currentCues))
        }

        return chunks
    }

    private func buildChunk(from cues: [SubtitleCue]) -> CueChunk {
        let cueIDs = cues.map { $0.id }
        let sourceText = cues.map { cue in
            let start = markerStart(for: cue.id)
            let end = markerEnd(for: cue.id)
            return "\(start)\n\(cue.primaryText)\n\(end)"
        }.joined(separator: "\n")

        return CueChunk(cueIDs: cueIDs, sourceText: sourceText)
    }

    private func markerStart(for cueID: UUID) -> String {
        "[[[SUBSTAMP:\(cueID.uuidString)]]]"
    }

    private func markerEnd(for cueID: UUID) -> String {
        "[[[/SUBSTAMP:\(cueID.uuidString)]]]"
    }

    private func extractChunkTranslations(translatedText: String, cueIDs: [UUID]) -> [UUID: String] {
        var output: [UUID: String] = [:]
        for cueID in cueIDs {
            let startMarker = markerStart(for: cueID)
            let endMarker = markerEnd(for: cueID)
            guard let startRange = translatedText.range(of: startMarker) else { continue }
            guard let endRange = translatedText.range(of: endMarker, range: startRange.upperBound..<translatedText.endIndex) else { continue }
            let between = translatedText[startRange.upperBound..<endRange.lowerBound]
            output[cueID] = between.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return output
    }
}
