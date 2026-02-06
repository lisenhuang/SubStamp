import Foundation
import FoundationModels

@available(iOS 26.0, *)
final class AppleIntelligenceTranscriptionRepairService {
    @Generable
    struct CueRepairResponse {
        var original: String
        var cues: [CueRepair]
    }

    @Generable
    struct CueRepair {
        var id: String
        var index: Int
        var text: String
    }

    private struct RepairChunkRequest: Encodable {
        let original: String
        let cues: [CueInput]
    }

    private struct CueInput: Encodable {
        let id: String
        let index: Int
        let text: String
    }

    private let model: SystemLanguageModel
    private let baseMaxCuesPerChunk = 16
    private let baseMaxCharactersPerChunk = 2200

    init(model: SystemLanguageModel = .default) {
        self.model = model
    }

    func repair(
        cues: [SubtitleCue],
        locale: Locale,
        progressHandler: @escaping (Int, Int) -> Void
    ) async throws -> [SubtitleCue] {
        guard model.isAvailable else {
            throw SubStampError.translationError(underlying: NSError(
                domain: "SubStamp",
                code: -240,
                userInfo: [NSLocalizedDescriptionKey: "AI is not available."]
            ))
        }

        if cues.isEmpty {
            progressHandler(0, 0)
            return []
        }

        let sourceBCP47 = locale.identifier(.bcp47)
        let sourceLabel = Locale.current.localizedString(forIdentifier: sourceBCP47) ?? sourceBCP47

        let session = LanguageModelSession(model: model) {
            """
            You are a professional subtitle proofreader.
            Fix speech-to-text transcription mistakes while preserving meaning.
            Do not translate.
            Make minimal edits only (typos, homophones, obvious word mistakes). Do not add new words or phrases.
            Do not move text between cues and do not copy text from other cues.
            Never merge cues: each cue must stay distinct and should not include content from adjacent cues.
            If you are uncertain about a word, keep the original text rather than guessing.
            Do not add, remove, merge, split, or reorder cues.
            Always output ONLY valid JSON that matches the requested schema.
            """
        }

        let indexByID = Dictionary(uniqueKeysWithValues: cues.enumerated().map { ($0.element.id, $0.offset) })
        let chunks = makeChunks(from: cues, maxCuesPerChunk: baseMaxCuesPerChunk, maxCharactersPerChunk: baseMaxCharactersPerChunk)

        var output = cues
        var completed = Set<UUID>()
        progressHandler(0, cues.count)

        for (chunkIndex, chunk) in chunks.enumerated() {
            try Task.checkCancellation()

            let repaired = await repairChunkWithFallback(
                chunk,
                original: sourceBCP47,
                sourceLabel: sourceLabel,
                chunkIndex: chunkIndex,
                chunkCount: chunks.count,
                indexByID: indexByID,
                session: session
            )

            for (cueID, text) in repaired {
                guard let cueIndex = indexByID[cueID], output.indices.contains(cueIndex) else { continue }
                output[cueIndex].primaryText = SubtitleTextCleaner.clean(text)
                completed.insert(cueID)
            }

            progressHandler(completed.count, cues.count)
        }

        output = trimLikelyMergedCues(repaired: output, originals: cues)

        for index in output.indices {
            let originalText = cues[index].primaryText.trimmingCharacters(in: .whitespacesAndNewlines)
            if originalText.isEmpty {
                output[index].primaryText = ""
                continue
            }
            let repairedText = output[index].primaryText
            if isClearlyInvalidRepair(repairedText, original: originalText)
                || isExcessiveExpansion(repairedText, original: originalText)
                || isLikelyMergedWithNeighbor(index: index, repaired: output, originals: cues)
            {
                output[index].primaryText = cues[index].primaryText
            }
        }

        return output
    }

    // MARK: - Chunking

    private func makeChunks(from cues: [SubtitleCue], maxCuesPerChunk: Int, maxCharactersPerChunk: Int) -> [[SubtitleCue]] {
        var chunks: [[SubtitleCue]] = []
        var current: [SubtitleCue] = []
        var currentChars = 0

        for cue in cues {
            let overhead = 90 + cue.id.uuidString.count
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

    // MARK: - Repair

    private func repairChunkWithFallback(
        _ cues: [SubtitleCue],
        original: String,
        sourceLabel: String,
        chunkIndex: Int,
        chunkCount: Int,
        indexByID: [UUID: Int],
        session: LanguageModelSession
    ) async -> [UUID: String] {
        do {
            return try await repairChunkOnce(
                cues,
                original: original,
                sourceLabel: sourceLabel,
                contextLabel: "chunk \(chunkIndex + 1)/\(chunkCount)",
                indexByID: indexByID,
                session: session
            )
        } catch {
#if DEBUG
            AppLog.append("[AI-TRANSCRIPT] chunk \(chunkIndex + 1)/\(chunkCount) failed (\(cues.count) cues): \(error.localizedDescription) — keeping original transcription")
#endif
            // AI failed — keep original transcription for all cues in this chunk (no retry)
            return [:]
        }
    }

    private func repairChunkOnce(
        _ cues: [SubtitleCue],
        original: String,
        sourceLabel: String,
        contextLabel: String,
        indexByID: [UUID: Int],
        session: LanguageModelSession
    ) async throws -> [UUID: String] {
        var repaired = try await repairChunkRaw(
            cues,
            original: original,
            sourceLabel: sourceLabel,
            contextLabel: contextLabel,
            isRepair: false,
            indexByID: indexByID,
            session: session
        )

        let repairCues = cuesNeedingRepair(cues, repaired: repaired)
        if !repairCues.isEmpty {
            do {
                let repairedAgain = try await repairChunkRaw(
                    repairCues,
                    original: original,
                    sourceLabel: sourceLabel,
                    contextLabel: "\(contextLabel) repair",
                    isRepair: true,
                    indexByID: indexByID,
                    session: session
                )
                repaired = mergeRepairs(repaired, repairedAgain)
            } catch {
#if DEBUG
                AppLog.append("[AI-TRANSCRIPT] \(contextLabel) repair failed (\(repairCues.count) cues): \(error.localizedDescription)")
#endif
            }
        }

        return repaired
    }

    private func repairChunkRaw(
        _ cues: [SubtitleCue],
        original: String,
        sourceLabel: String,
        contextLabel: String,
        isRepair: Bool,
        indexByID: [UUID: Int],
        session: LanguageModelSession
    ) async throws -> [UUID: String] {
        let request = RepairChunkRequest(
            original: original,
            cues: cues.enumerated().map { localIndex, cue in
                CueInput(
                    id: cue.id.uuidString,
                    index: indexByID[cue.id] ?? localIndex,
                    text: cue.primaryText
                )
            }
        )
        let requestJSON = try encodeJSON(request)
        let prompt = buildPrompt(
            requestJSON: requestJSON,
            contextLabel: contextLabel,
            isRepair: isRepair,
            sourceLabel: sourceLabel,
            cueCount: cues.count
        )

        let response = try await session.respond(to: prompt, generating: CueRepairResponse.self)
        return parseResponse(response.content, allowedCueIDs: Set(cues.map(\.id)))
    }

    // MARK: - Prompt / Parsing

    private func buildPrompt(
        requestJSON: String,
        contextLabel: String,
        isRepair: Bool,
        sourceLabel: String,
        cueCount: Int
    ) -> String {
        let header = isRepair
            ? "Some repaired cues were missing or invalid. Fix them again."
            : "Fix all cues."

        return """
        \(header)
        Context: \(contextLabel)
        Language: \(sourceLabel)

        Rules:
        - Treat all cues as a single transcript to understand context (语境).
        - Do NOT translate.
        - Make minimal edits only. Fix typos/homophones/obvious wrong words.
        - Do NOT add new words or phrases and do NOT try to make the transcript more complete.
        - Do NOT copy text from other cues. Do NOT move text between cues.
        - Never merge cues: a cue must not include content from adjacent cues.
        - Keep each cue close in length to the input cue. Do not significantly increase length.
        - Do NOT add, remove, merge, split, or reorder cues.
        - Return exactly \(cueCount) cue entries.
        - Keep each cue aligned by both id and index.
        - Preserve line breaks.
        - If an input cue text is empty, return an empty string for that cue.
        - Output ONLY JSON. Do not wrap in markdown. Do not add commentary.

        JSON schema (must match exactly):
        {
          "original": "bcp47-language-tag",
          "cues": [
            { "id": "uuid", "index": 0, "text": "corrected cue text" }
          ]
        }

        Input JSON:
        \(requestJSON)
        """
    }

    private func parseResponse(
        _ response: CueRepairResponse,
        allowedCueIDs: Set<UUID>
    ) -> [UUID: String] {
        var map: [UUID: String] = [:]
        for cue in response.cues {
            guard let id = UUID(uuidString: cue.id), allowedCueIDs.contains(id) else { continue }
            map[id] = cue.text
        }

#if DEBUG
        let allowedCount = allowedCueIDs.count
        if map.count != allowedCount {
            AppLog.append("[AI-TRANSCRIPT] Missing cues in response: expected=\(allowedCount) got=\(map.count)")
        }
#endif

        return map
    }

    // MARK: - Validation / Repair

    private func cuesNeedingRepair(_ cues: [SubtitleCue], repaired: [UUID: String]) -> [SubtitleCue] {
        var needsRepair = Set<UUID>()

        for cue in cues {
            let original = cue.primaryText.trimmingCharacters(in: .whitespacesAndNewlines)
            if original.isEmpty { continue }

            guard let text = repaired[cue.id] else {
                needsRepair.insert(cue.id)
                continue
            }

            if isClearlyInvalidRepair(text, original: original) {
                needsRepair.insert(cue.id)
            }
        }

        guard !needsRepair.isEmpty else { return [] }
        return cues.filter { needsRepair.contains($0.id) }
    }

    private func trimLikelyMergedCues(repaired: [SubtitleCue], originals: [SubtitleCue]) -> [SubtitleCue] {
        var output = repaired
        guard output.count == originals.count, output.count > 1 else { return output }

        for index in 0..<(output.count - 1) {
            let nextRepaired = output[index + 1].primaryText
            let nextOriginal = originals[index + 1].primaryText

            if let trimmed = trimTrailingDuplicate(from: output[index].primaryText, duplicate: nextRepaired) {
                output[index].primaryText = SubtitleTextCleaner.clean(trimmed)
#if DEBUG
                AppLog.append("[AI-TRANSCRIPT] trimmed duplicate from cue=\(index) using next repaired")
#endif
                continue
            }

            if let trimmed = trimTrailingDuplicate(from: output[index].primaryText, duplicate: nextOriginal) {
                output[index].primaryText = SubtitleTextCleaner.clean(trimmed)
#if DEBUG
                AppLog.append("[AI-TRANSCRIPT] trimmed duplicate from cue=\(index) using next original")
#endif
            }
        }

        return output
    }

    private func trimTrailingDuplicate(from text: String, duplicate: String) -> String? {
        let dup = duplicate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard dup.count >= 10 else { return nil }

        guard let range = text.range(of: dup, options: [.caseInsensitive, .backwards]) else { return nil }
        let suffix = text[range.upperBound...]
        guard suffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let prefix = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else { return nil }
        return prefix
    }

    private func isLikelyMergedWithNeighbor(index: Int, repaired: [SubtitleCue], originals: [SubtitleCue]) -> Bool {
        guard repaired.count == originals.count, repaired.indices.contains(index) else { return false }
        guard repaired.count > 1 else { return false }

        let current = repaired[index].primaryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else { return false }

        var neighborCandidates: [String] = []
        if index > 0 {
            neighborCandidates.append(repaired[index - 1].primaryText)
            neighborCandidates.append(originals[index - 1].primaryText)
        }
        if index + 1 < repaired.count {
            neighborCandidates.append(repaired[index + 1].primaryText)
            neighborCandidates.append(originals[index + 1].primaryText)
        }

        let normalizedCurrent = normalizeForOverlapComparison(current)
        for candidate in neighborCandidates {
            let neighbor = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard neighbor.count >= 10 else { continue }

            if current.range(of: neighbor, options: [.caseInsensitive]) != nil {
                // If this cue contains a whole neighbor cue, it's likely a merge/duplication.
                if neighbor.count > 10 && current.count > neighbor.count + 8 {
                    return true
                }
            }

            let normalizedNeighbor = normalizeForOverlapComparison(neighbor)
            if normalizedNeighbor.count >= 12, normalizedCurrent.contains(normalizedNeighbor) {
                let ratio = Double(normalizedNeighbor.count) / Double(max(1, normalizedCurrent.count))
                if ratio > 0.55 {
                    return true
                }
            }
        }

        return false
    }

    private func normalizeForOverlapComparison(_ text: String) -> String {
        let scalars = text.lowercased().unicodeScalars.filter { scalar in
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { return false }
            if CharacterSet.punctuationCharacters.contains(scalar) { return false }
            if CharacterSet.symbols.contains(scalar) { return false }
            return true
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private func isExcessiveExpansion(_ repaired: String, original: String) -> Bool {
        let orig = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let rep = repaired.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !orig.isEmpty else { return false }

        let origCount = orig.count
        let repCount = rep.count

        if origCount <= 6 {
            return repCount > origCount + 14
        }

        let ratio = Double(repCount) / Double(origCount)
        return ratio > 1.7 && (repCount - origCount) > 22
    }

    private func isClearlyInvalidRepair(_ text: String, original: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }

        let lower = trimmed.lowercased()
        if lower.contains("please provide the subtitles") && lower.contains("translated") { return true }
        if lower.hasPrefix("sure") && lower.contains("provide") { return true }

        if lower.hasPrefix("here are") && lower.contains("corrected") { return true }
        if lower.contains("i can help") && lower.contains("transcription") { return true }

        if normalizeForLooseComparison(trimmed) == normalizeForLooseComparison(original) {
            return false
        }

        return false
    }

    private func normalizeForLooseComparison(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    // MARK: - JSON / Merging

    private func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func mergeRepairs(_ a: [UUID: String], _ b: [UUID: String]) -> [UUID: String] {
        var out = a
        for (id, text) in b {
            out[id] = text
        }
        return out
    }
}
