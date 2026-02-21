import Foundation
import FoundationModels
@preconcurrency import Translation

@available(iOS 26.0, *)
final class AppleIntelligenceTranslationService {
    struct MultiTargetCueTranslationResponse: Decodable {
        var original: String
        var targets: [TargetTranslations]
    }

    struct TargetTranslations: Decodable {
        var target: String
        var cues: [CueTranslation]
    }

    struct CueTranslation: Decodable {
        var k: Int
        var text: String
    }

    private struct TranslationChunkRequest: Encodable {
        let original: String
        let cues: [CueInput]
        let targets: [String]
    }

    private struct CueInput: Encodable {
        /// Stable within a chunk (0..<chunk.count). Use this key for alignment instead of UUIDs.
        let k: Int
        let text: String
    }

    private let model: SystemLanguageModel
    private let baseMaxCuesPerChunk = 12
    private let baseMaxCharactersPerChunk = 1800

    init(model: SystemLanguageModel = .default) {
        self.model = model
    }
    
    /// Fallback translation using the built-in Translation Framework
    private func fallbackTranslate(
        text: String,
        source: Locale,
        target: Locale.Language
    ) async -> String? {
        guard #available(iOS 17.4, *) else { return nil }
        
        do {
            let session = TranslationSession(installedSource: source.language, target: target)
            let response = try await session.translate(text)
            return SubtitleTextCleaner.clean(response.targetText)
        } catch {
#if DEBUG
            AppLog.append("[FALLBACK-TRANSLATE] Failed: \(error.localizedDescription)")
#endif
            return nil
        }
    }

    func translate(
        cues: [SubtitleCue],
        source: Locale,
        target: Locale.Language,
        progressHandler: @escaping (Int, Int) -> Void
    ) async throws -> [SubtitleCue] {
        let results = try await translate(cues: cues, source: source, targets: [target], progressHandler: progressHandler)
        let key = target.minimalIdentifier
        if let output = results[key] {
            return output
        }

        return cues.map { cue in
            var next = cue
            next.secondaryText = nil
            next.hasTranslationError = true
            return next
        }
    }

    func translate(
        cues: [SubtitleCue],
        source: Locale,
        targets: [Locale.Language],
        progressHandler: @escaping (Int, Int) -> Void
    ) async throws -> [String: [SubtitleCue]] {
        guard model.isAvailable else {
            throw SubStampError.translationError(underlying: NSError(
                domain: "SubStamp",
                code: -210,
                userInfo: [NSLocalizedDescriptionKey: "AI is not available."]
            ))
        }

        let sourceBCP47 = source.identifier(.bcp47)
        let sourceMinimal = Locale.Language(identifier: sourceBCP47).minimalIdentifier

        let requestedTargets = uniqueTargetIdentifiers(from: targets)
        var outputByTarget: [String: [SubtitleCue]] = [:]

        if cues.isEmpty {
            progressHandler(0, 0)
            for id in requestedTargets {
                outputByTarget[id] = []
            }
            return outputByTarget
        }

        let (targetsNeedingTranslation, passthroughTargets) = partitionTargets(requestedTargets: requestedTargets, sourceMinimal: sourceMinimal)

        if !passthroughTargets.isEmpty {
            for id in passthroughTargets {
                outputByTarget[id] = cues.map { cue in
                    var next = cue
                    next.secondaryText = cue.primaryText
                    next.hasTranslationError = false
                    return next
                }
            }
        }

        for id in targetsNeedingTranslation {
            outputByTarget[id] = cues.map { cue in
                var next = cue
                next.secondaryText = nil
                next.hasTranslationError = false
                return next
            }
        }

        let totalWork = cues.count * targetsNeedingTranslation.count
        progressHandler(0, totalWork)

        guard !targetsNeedingTranslation.isEmpty else {
            return outputByTarget
        }

        let sourceLabel = Locale.current.localizedString(forIdentifier: sourceBCP47) ?? sourceBCP47
        let targetHints = buildTargetHints(for: targetsNeedingTranslation)

        let session = LanguageModelSession(model: model) {
            """
            You are a professional subtitle translator.
            Translate naturally and faithfully. You may use surrounding cues for context (语境), but each cue MUST stay aligned to its own input text.
            Keep each cue concise for on-screen subtitles.
            Do not add, remove, merge, split, or reorder cues.
            Do not add commentary or explanations.
            Always output ONLY valid JSON that matches the requested schema.
            """
        }

        let indexByID = Dictionary(uniqueKeysWithValues: cues.enumerated().map { ($0.element.id, $0.offset) })
        let chunkLimits = chunkLimits(forTargetCount: targetsNeedingTranslation.count)
        let chunks = makeChunks(from: cues, maxCuesPerChunk: chunkLimits.maxCues, maxCharactersPerChunk: chunkLimits.maxCharacters)

        var completedByTarget: [String: Set<UUID>] = Dictionary(uniqueKeysWithValues: targetsNeedingTranslation.map { ($0, Set<UUID>()) })
        var failuresByCueID: [UUID: String] = [:]

        for (chunkIndex, chunk) in chunks.enumerated() {
            try Task.checkCancellation()

            let context = buildAdjacentContext(
                allCues: cues,
                chunk: chunk,
                indexByID: indexByID,
                maxBefore: 2,
                maxAfter: 2,
                maxChars: 420
            )
            let chunkResult = await translateChunkWithFallback(
                chunk,
                original: sourceBCP47,
                sourceLabel: sourceLabel,
                targetIDs: targetsNeedingTranslation,
                targetHints: targetHints,
                chunkIndex: chunkIndex,
                chunkCount: chunks.count,
                contextBefore: context.before,
                contextAfter: context.after,
                indexByID: indexByID,
                session: session
            )
            failuresByCueID.merge(chunkResult.failures, uniquingKeysWith: { existing, _ in existing })

            for targetID in targetsNeedingTranslation {
                guard var output = outputByTarget[targetID] else { continue }
                let translations = chunkResult.translations[targetID] ?? [:]
                for (cueID, text) in translations {
                    guard let cueIndex = indexByID[cueID], output.indices.contains(cueIndex) else { continue }
                    output[cueIndex].secondaryText = SubtitleTextCleaner.clean(text)
                    output[cueIndex].hasTranslationError = false
                    completedByTarget[targetID, default: []].insert(cueID)
                }
                outputByTarget[targetID] = output
            }

            let completed = completedByTarget.values.reduce(0) { $0 + $1.count }
            progressHandler(completed, totalWork)
        }

        for targetID in targetsNeedingTranslation {
            guard var output = outputByTarget[targetID] else { continue }
#if DEBUG
            var missingCount = 0
            var invalidCount = 0
            var loggedSamples = 0
#endif
            for index in output.indices {
                let originalText = output[index].primaryText.trimmingCharacters(in: .whitespacesAndNewlines)
                if originalText.isEmpty {
                    output[index].secondaryText = ""
                    output[index].hasTranslationError = false
                    continue
                }
                guard let translated = output[index].secondaryText else {
                    // Try fallback translation using the Translation Framework
                    let targetLanguage = Locale.Language(identifier: targetID)
                    if let fallbackTranslation = await fallbackTranslate(
                        text: originalText,
                        source: source,
                        target: targetLanguage
                    ) {
                        output[index].secondaryText = fallbackTranslation
                        output[index].hasTranslationError = false
#if DEBUG
                        AppLog.append("[AI-TRANSLATE] fallback successful for target=\(targetID) cueIndex=\(index)")
#endif
                    } else {
                        // Both AI and fallback failed — keep original text as subtitle
                        output[index].secondaryText = originalText
                        output[index].hasTranslationError = true
#if DEBUG
                        missingCount += 1
                        if loggedSamples < 6 {
                            let preview = originalText.replacingOccurrences(of: "\n", with: " ").prefix(80)
                            AppLog.append("[AI-TRANSLATE] missing (fallback failed) target=\(targetID) cueIndex=\(index) id=\(output[index].id.uuidString) original='\(preview)'")
                            loggedSamples += 1
                        }
#endif
                    }
                    continue
                }
                if let reason = invalidTranslationReason(translated, original: originalText, targetID: targetID) {
                    if translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        // Empty translation — try fallback
                        let targetLanguage = Locale.Language(identifier: targetID)
                        if let fallbackTranslation = await fallbackTranslate(
                            text: originalText,
                            source: source,
                            target: targetLanguage
                        ) {
                            output[index].secondaryText = fallbackTranslation
                            output[index].hasTranslationError = false
#if DEBUG
                            AppLog.append("[AI-TRANSLATE] fallback successful for invalid translation target=\(targetID) cueIndex=\(index)")
#endif
                        } else {
                            // Both AI and fallback failed — keep original text
                            output[index].secondaryText = originalText
                            output[index].hasTranslationError = false
                        }
                    }
                    // Non-empty translation (possibly from Framework fallback) — accept as-is
#if DEBUG
                    invalidCount += 1
                    if loggedSamples < 6 {
                        let origPreview = originalText.replacingOccurrences(of: "\n", with: " ").prefix(60)
                        let transPreview = translated.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ").prefix(60)
                        AppLog.append("[AI-TRANSLATE] invalid(\(reason)) target=\(targetID) cueIndex=\(index) id=\(output[index].id.uuidString) original='\(origPreview)' translated='\(transPreview)'")
                        loggedSamples += 1
                    }
#endif
                }
            }
            outputByTarget[targetID] = output

#if DEBUG
            if missingCount > 0 || invalidCount > 0 {
                AppLog.append("[AI-TRANSLATE] summary target=\(targetID) missing=\(missingCount) invalid=\(invalidCount)")
            }
#endif
        }

        return outputByTarget
    }

    // MARK: - Chunking

    private func chunkLimits(forTargetCount targetCount: Int) -> (maxCues: Int, maxCharacters: Int) {
        let divisor = max(1, targetCount)
        let maxCues = max(3, baseMaxCuesPerChunk / divisor)
        let maxChars = max(400, baseMaxCharactersPerChunk / divisor)
        return (maxCues, maxChars)
    }

    private func makeChunks(from cues: [SubtitleCue], maxCuesPerChunk: Int, maxCharactersPerChunk: Int) -> [[SubtitleCue]] {
        var chunks: [[SubtitleCue]] = []
        var current: [SubtitleCue] = []
        var currentChars = 0

        for cue in cues {
            let overhead = 110 + cue.id.uuidString.count
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

    // MARK: - Translation

    private struct ChunkTranslationResult {
        var translations: [String: [UUID: String]]
        var failures: [UUID: String]
    }

    private func mergeChunkResults(_ left: ChunkTranslationResult, _ right: ChunkTranslationResult) -> ChunkTranslationResult {
        ChunkTranslationResult(
            translations: mergeTranslations(left.translations, right.translations),
            failures: left.failures.merging(right.failures, uniquingKeysWith: { existing, _ in existing })
        )
    }

    private func translateChunkWithFallback(
        _ cues: [SubtitleCue],
        original: String,
        sourceLabel: String,
        targetIDs: [String],
        targetHints: String,
        chunkIndex: Int,
        chunkCount: Int,
        contextBefore: [String],
        contextAfter: [String],
        indexByID: [UUID: Int],
        session: LanguageModelSession
    ) async -> ChunkTranslationResult {
        do {
            let translations = try await translateChunkOnce(
                cues,
                original: original,
                sourceLabel: sourceLabel,
                targetIDs: targetIDs,
                targetHints: targetHints,
                contextLabel: "chunk \(chunkIndex + 1)/\(chunkCount)",
                contextBefore: contextBefore,
                contextAfter: contextAfter,
                indexByID: indexByID,
                session: session
            )
            return ChunkTranslationResult(translations: translations, failures: [:])
        } catch {
#if DEBUG
            let reason = isSafetyGuardrailsError(error) ? "safety" : "error"
            AppLog.append("[AI-TRANSLATE] chunk \(chunkIndex + 1)/\(chunkCount) failed (\(cues.count) cues) reason=\(reason): \(error.localizedDescription) — falling back to Translation Framework")
#endif
            // AI failed for this chunk — fallback to Translation Framework per cue
            let sourceLocale = Locale(identifier: original)
            var translations: [String: [UUID: String]] = [:]
            var failures: [UUID: String] = [:]

            for cue in cues {
                let text = cue.primaryText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }

                for targetID in targetIDs {
                    let targetLang = Locale.Language(identifier: targetID)
                    if let translated = await fallbackTranslate(text: text, source: sourceLocale, target: targetLang) {
                        translations[targetID, default: [:]][cue.id] = translated
                    } else {
                        failures[cue.id] = error.localizedDescription
                    }
                }
            }

            return ChunkTranslationResult(translations: translations, failures: failures)
        }
    }

    private func translateChunkOnce(
        _ cues: [SubtitleCue],
        original: String,
        sourceLabel: String,
        targetIDs: [String],
        targetHints: String,
        contextLabel: String,
        contextBefore: [String],
        contextAfter: [String],
        indexByID: [UUID: Int],
        session: LanguageModelSession
    ) async throws -> [String: [UUID: String]] {
        var translations = try await translateChunkRaw(
            cues,
            original: original,
            sourceLabel: sourceLabel,
            targetIDs: targetIDs,
            targetHints: targetHints,
            contextLabel: contextLabel,
            contextBefore: contextBefore,
            contextAfter: contextAfter,
            isRepair: false,
            indexByID: indexByID,
            session: session
        )

        let repairCues = cuesNeedingRepair(cues, targetIDs: targetIDs, translations: translations)
        if !repairCues.isEmpty {
            do {
                let repaired = try await translateChunkRaw(
                    repairCues,
                    original: original,
                    sourceLabel: sourceLabel,
                    targetIDs: targetIDs,
                    targetHints: targetHints,
                    contextLabel: "\(contextLabel) repair",
                    contextBefore: contextBefore,
                    contextAfter: contextAfter,
                    isRepair: true,
                    indexByID: indexByID,
                    session: session
                )
                translations = mergeTranslations(translations, repaired)
            } catch {
#if DEBUG
                AppLog.append("[AI-TRANSLATE] \(contextLabel) repair failed (\(repairCues.count) cues): \(error.localizedDescription)")
#endif
            }
        }

        return translations
    }

    private func translateChunkRaw(
        _ cues: [SubtitleCue],
        original: String,
        sourceLabel: String,
        targetIDs: [String],
        targetHints: String,
        contextLabel: String,
        contextBefore: [String],
        contextAfter: [String],
        isRepair: Bool,
        indexByID: [UUID: Int],
        session: LanguageModelSession
    ) async throws -> [String: [UUID: String]] {
        // Map a compact per-chunk key to cue IDs (prevents misalignment caused by UUID copying mistakes).
        let keyToCueID: [Int: UUID] = Dictionary(uniqueKeysWithValues: cues.enumerated().map { ($0.offset, $0.element.id) })
        let request = TranslationChunkRequest(
            original: original,
            cues: cues.enumerated().map { localIndex, cue in
                CueInput(
                    k: localIndex,
                    text: cue.primaryText
                )
            },
            targets: targetIDs
        )
        let requestJSON = try encodeJSON(request)
        let prompt = buildPrompt(
            requestJSON: requestJSON,
            contextLabel: contextLabel,
            isRepair: isRepair,
            sourceLabel: sourceLabel,
            targetIDs: targetIDs,
            targetHints: targetHints,
            cueCount: cues.count,
            contextBefore: contextBefore,
            contextAfter: contextAfter
        )

        let response = try await session.respond(to: prompt)
        let decoded = try decodeModelJSON(MultiTargetCueTranslationResponse.self, from: response.content)
        return parseResponse(decoded, requestedTargetIDs: targetIDs, keyToCueID: keyToCueID)
    }

    // MARK: - Prompt / Parsing

    private func buildPrompt(
        requestJSON: String,
        contextLabel: String,
        isRepair: Bool,
        sourceLabel: String,
        targetIDs: [String],
        targetHints: String,
        cueCount: Int,
        contextBefore: [String],
        contextAfter: [String]
    ) -> String {
        let header = isRepair
            ? "Some cue translations were missing or invalid. Translate them again."
            : "Translate all cues."

        let beforeBlock = formatContextBlock(label: "Context before (reference only)", lines: contextBefore)
        let afterBlock = formatContextBlock(label: "Context after (reference only)", lines: contextAfter)

        return """
        \(header)
        Context: \(contextLabel)
        Source: \(sourceLabel)
        Targets: \(targetIDs.joined(separator: ", "))

        \(targetHints)
        \(beforeBlock)
        \(afterBlock)

        Rules:
        - Use context for natural phrasing, but translate each cue text ONLY. Do not move content between cues.
        - Do NOT add, remove, merge, split, or reorder cues.
        - For every target, return exactly \(cueCount) cue entries.
        - Keep each cue aligned by its key `k` (0..\(max(0, cueCount - 1))).
        - Copy each `k` from INPUT_JSON exactly. Do not invent new keys.
        - Preserve line breaks.
        - If an input cue text is empty, return an empty string for that cue.
        - Output ONLY JSON. Do not wrap in markdown. Do not add commentary.

        JSON schema (must match exactly):
        {
          "original": "…",
          "targets": [
            {
              "target": "…",
              "cues": [
                { "k": 0, "text": "…" }
              ]
            }
          ]
        }

        INPUT_JSON:
        \(requestJSON)
        """
    }

    private func parseResponse(
        _ response: MultiTargetCueTranslationResponse,
        requestedTargetIDs: [String],
        keyToCueID: [Int: UUID]
    ) -> [String: [UUID: String]] {
        let requestedByNormalized = Dictionary(
            uniqueKeysWithValues: requestedTargetIDs.map { (normalizeIdentifier($0), $0) }
        )

        var output: [String: [UUID: String]] = [:]
        for targetEntry in response.targets {
            let normalized = normalizeIdentifier(targetEntry.target)
            guard let canonicalTarget = requestedByNormalized[normalized] else { continue }

            var map = output[canonicalTarget] ?? [:]
            for cue in targetEntry.cues {
                guard let cueID = keyToCueID[cue.k] else { continue }
                map[cueID] = cue.text
            }
            output[canonicalTarget] = map
        }

#if DEBUG
        let missingTargets = requestedTargetIDs.filter { output[$0] == nil }
        if !missingTargets.isEmpty {
            AppLog.append("[AI-TRANSLATE] Missing target entries in response: \(missingTargets.joined(separator: ", "))")
        }
#endif

        return output
    }

    // MARK: - Context helpers

    private func buildAdjacentContext(
        allCues: [SubtitleCue],
        chunk: [SubtitleCue],
        indexByID: [UUID: Int],
        maxBefore: Int,
        maxAfter: Int,
        maxChars: Int
    ) -> (before: [String], after: [String]) {
        guard let first = chunk.first, let last = chunk.last else { return ([], []) }
        let startIndex = indexByID[first.id] ?? 0
        let endIndex = indexByID[last.id] ?? startIndex

        var before: [String] = []
        var after: [String] = []

        if startIndex > 0, maxBefore > 0 {
            let beforeStart = max(0, startIndex - maxBefore)
            for i in beforeStart..<startIndex {
                let text = allCues[i].primaryText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { before.append(text) }
            }
        }
        if endIndex + 1 < allCues.count, maxAfter > 0 {
            let afterEnd = min(allCues.count, endIndex + 1 + maxAfter)
            for i in (endIndex + 1)..<afterEnd {
                let text = allCues[i].primaryText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { after.append(text) }
            }
        }

        // Bound total context size.
        func trimToBudget(_ lines: [String], budget: Int) -> [String] {
            guard budget > 0 else { return [] }
            var out: [String] = []
            var used = 0
            for line in lines {
                if used >= budget { break }
                let remaining = budget - used
                if line.count <= remaining {
                    out.append(line)
                    used += line.count
                } else if remaining >= 16 {
                    out.append(String(line.prefix(remaining)))
                    used += remaining
                    break
                } else {
                    break
                }
            }
            return out
        }

        let half = max(0, maxChars / 2)
        before = trimToBudget(before, budget: half)
        after = trimToBudget(after, budget: maxChars - before.reduce(0, { $0 + $1.count }))
        return (before, after)
    }

    private func formatContextBlock(label: String, lines: [String]) -> String {
        let trimmed = lines
            .map { $0.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !trimmed.isEmpty else { return "" }
        let bullets = trimmed.map { "- \($0)" }.joined(separator: "\n")
        return """

        \(label):
        \(bullets)
        """
    }

    // MARK: - Validation / Repair

    private func cuesNeedingRepair(
        _ cues: [SubtitleCue],
        targetIDs: [String],
        translations: [String: [UUID: String]]
    ) -> [SubtitleCue] {
        var needsRepair = Set<UUID>()
        for cue in cues {
            let original = cue.primaryText.trimmingCharacters(in: .whitespacesAndNewlines)
            if original.isEmpty { continue }

            for targetID in targetIDs {
                guard let text = translations[targetID]?[cue.id] else {
                    needsRepair.insert(cue.id)
                    break
                }
                if isClearlyInvalidTranslation(text, original: original, targetID: targetID) {
                    needsRepair.insert(cue.id)
                    break
                }
            }
        }

        guard !needsRepair.isEmpty else { return [] }
        return cues.filter { needsRepair.contains($0.id) }
    }

    private func isClearlyInvalidTranslation(_ text: String, original: String, targetID: String) -> Bool {
        invalidTranslationReason(text, original: original, targetID: targetID) != nil
    }

    private func invalidTranslationReason(_ text: String, original: String, targetID: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "empty" }

        let lower = trimmed.lowercased()
        if lower.contains("please provide the subtitles") && lower.contains("translated") { return "promptLeak" }
        if lower.hasPrefix("sure") && lower.contains("provide") { return "promptLeak" }

        if normalizeForLooseComparison(trimmed) == normalizeForLooseComparison(original) {
            if normalizeIdentifier(targetID).hasPrefix("zh") && containsASCIIAlpha(original) && original.count > 12 {
                return "sameAsOriginal"
            }
        }

        return nil
    }

    private func containsASCIIAlpha(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            scalar.isASCII && CharacterSet.letters.contains(scalar)
        }
    }

    private func isSafetyGuardrailsError(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("unsafe")
            || message.contains("safety guardrails")
            || message.contains("guardrails were triggered")
    }

    private func normalizeForLooseComparison(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    // MARK: - Identifiers / Hints

    private func uniqueTargetIdentifiers(from targets: [Locale.Language]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        for target in targets {
            let canonical = target.minimalIdentifier
            let normalized = normalizeIdentifier(canonical)
            if seen.insert(normalized).inserted {
                ordered.append(canonical)
            }
        }

        return ordered
    }

    private func partitionTargets(requestedTargets: [String], sourceMinimal: String) -> ([String], [String]) {
        let normalizedSource = normalizeIdentifier(sourceMinimal)
        var needs: [String] = []
        var passthrough: [String] = []

        for target in requestedTargets {
            if normalizeIdentifier(target) == normalizedSource {
                passthrough.append(target)
            } else {
                needs.append(target)
            }
        }

        return (needs, passthrough)
    }

    private func buildTargetHints(for targets: [String]) -> String {
        var lines: [String] = []
        for target in targets {
            guard let hint = hint(for: target) else { continue }
            lines.append("- \(target): \(hint)")
        }

        if lines.isEmpty { return "" }
        return "Target style notes:\n" + lines.joined(separator: "\n")
    }

    private func hint(for targetID: String) -> String? {
        let normalized = normalizeIdentifier(targetID)
        guard normalized.hasPrefix("zh") else { return nil }

        if normalized.contains("-hant") || normalized.contains("-tw") || normalized.contains("-hk") || normalized.contains("-mo") {
            return "Use Traditional Chinese (繁體中文)."
        }
        return "Use Simplified Chinese (简体中文)."
    }

    private func normalizeIdentifier(_ identifier: String) -> String {
        identifier
            .replacingOccurrences(of: "_", with: "-")
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

    private func decodeModelJSON<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}") else {
            throw SubStampError.translationError(underlying: NSError(
                domain: "SubStamp",
                code: -211,
                userInfo: [NSLocalizedDescriptionKey: "Model response did not contain valid JSON."]
            ))
        }

        let json = String(trimmed[start...end])
        let data = Data(json.utf8)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw SubStampError.translationError(underlying: NSError(
                domain: "SubStamp",
                code: -212,
                userInfo: [NSLocalizedDescriptionKey: "Unable to decode model JSON response: \(error.localizedDescription)"]
            ))
        }
    }

    private func mergeTranslations(_ a: [String: [UUID: String]], _ b: [String: [UUID: String]]) -> [String: [UUID: String]] {
        var out = a
        for (target, map) in b {
            var existing = out[target] ?? [:]
            for (id, text) in map {
                existing[id] = text
            }
            out[target] = existing
        }
        return out
    }
}
