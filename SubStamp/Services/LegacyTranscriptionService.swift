import AVFoundation
import Foundation
import Speech

/// SFSpeechRecognizer-based transcription service for iOS 18–25.
/// Used as a fallback when the iOS 26+ SpeechTranscriber/SpeechAnalyzer APIs are unavailable.
///
/// @MainActor: SFSpeechRecognizer requires initialization and recognitionTask to be called
/// on the main thread. extractAudioAsWav is marked nonisolated so its blocking I/O loop
/// runs on the cooperative thread pool instead of blocking the main thread.
@MainActor
final class LegacyTranscriptionService {

    struct Result {
        let cues: [SubtitleCue]
        let duration: CMTime
    }

    // SFSpeechRecognizer has an ~1 minute on-device limit per request.
    // We chunk audio to stay under this limit.
    private let chunkDurationSeconds: Double = 55.0

    func transcribe(
        asset: AVAsset,
        locale: Locale,
        timeRange: CMTimeRange? = nil,
        progressHandler: @escaping (Double, Int) -> Void
    ) async throws -> Result {

        // 1. Request speech recognition permission
        try await requestAuthorization()

        // 2. Create recognizer — fall back to English if the requested locale is not supported
        guard let recognizer = SFSpeechRecognizer(locale: locale)
                ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
            throw SubStampError.speechAnalyzerError(underlying: NSError(
                domain: "SubStamp",
                code: -301,
                userInfo: [NSLocalizedDescriptionKey: "Speech recognizer not available for this locale."]
            ))
        }

        // 3. Determine effective duration
        let assetDuration = try await asset.load(.duration)
        let effectiveRange: CMTimeRange
        if let requested = timeRange {
            effectiveRange = requested
        } else {
            effectiveRange = CMTimeRange(start: .zero, duration: assetDuration)
        }
        let totalSeconds = effectiveRange.duration.seconds
        let startOffset = effectiveRange.start.seconds

        // 4. Compute chunks
        let chunkCount = max(1, Int(ceil(totalSeconds / chunkDurationSeconds)))

        var allCues: [SubtitleCue] = []

        for chunkIndex in 0..<chunkCount {
            try Task.checkCancellation()

            let chunkStart = startOffset + Double(chunkIndex) * chunkDurationSeconds
            let chunkEnd = min(startOffset + totalSeconds, chunkStart + chunkDurationSeconds)
            let cmRange = CMTimeRange(
                start: CMTime(seconds: chunkStart, preferredTimescale: 600),
                duration: CMTime(seconds: chunkEnd - chunkStart, preferredTimescale: 600)
            )

            // Extract audio chunk as WAV
            let chunkURL = try await extractAudioAsWav(from: asset, timeRange: cmRange)
            defer { try? FileManager.default.removeItem(at: chunkURL) }

            let chunkCues = try await recognizeAudioFile(
                at: chunkURL,
                recognizer: recognizer,
                timeOffsetSeconds: chunkStart
            )
            allCues.append(contentsOf: chunkCues)

            let progress = Double(chunkIndex + 1) / Double(chunkCount)
            progressHandler(progress, allCues.count)
        }

        if allCues.isEmpty {
            throw SubStampError.speechAnalyzerError(underlying: NSError(
                domain: "SubStamp",
                code: -302,
                userInfo: [NSLocalizedDescriptionKey: "No subtitles were generated. Please check if the audio matches the selected language."]
            ))
        }

        let processed = postProcess(cues: allCues)
        return Result(cues: processed, duration: effectiveRange.duration)
    }

    // MARK: - Permission

    private func requestAuthorization() async throws {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard status == .authorized else {
            throw SubStampError.speechAnalyzerError(underlying: NSError(
                domain: "SubStamp",
                code: -300,
                userInfo: [NSLocalizedDescriptionKey: "Speech recognition permission was denied. Please enable it in Settings > Privacy & Security > Speech Recognition."]
            ))
        }
    }

    // MARK: - Recognition

    private func recognizeAudioFile(
        at url: URL,
        recognizer: SFSpeechRecognizer,
        timeOffsetSeconds: Double
    ) async throws -> [SubtitleCue] {
        let request = SFSpeechURLRecognitionRequest(url: url)
        // Allow server-based recognition for broader language support on iOS 18–25.
        // SpeechTranscriber on iOS 26 is always on-device, but SFSpeechRecognizer
        // has limited on-device locale coverage on older OS versions.
        request.requiresOnDeviceRecognition = false
        request.addsPunctuation = true
        request.shouldReportPartialResults = false

        return try await withCheckedThrowingContinuation { continuation in
            var hasResumed = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !hasResumed else { return }
                if let error = error {
                    hasResumed = true
                    continuation.resume(throwing: error)
                    return
                }
                if let result = result, result.isFinal {
                    hasResumed = true
                    let cues = self.buildCues(
                        from: result.bestTranscription.segments,
                        timeOffsetSeconds: timeOffsetSeconds
                    )
                    continuation.resume(returning: cues)
                }
            }
        }
    }

    // MARK: - Cue Building

    private func buildCues(from segments: [SFTranscriptionSegment], timeOffsetSeconds: Double) -> [SubtitleCue] {
        let sentenceEnders: Set<Character> = [".", "!", "?", "。", "！", "？", "…"]
        var cues: [SubtitleCue] = []
        var buffer = ""
        var bufferStart: CMTime?
        var bufferEnd: CMTime?

        for segment in segments {
            let text = segment.substring
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let segStart = CMTime(seconds: timeOffsetSeconds + segment.timestamp, preferredTimescale: 600)
            let segEnd   = CMTime(seconds: timeOffsetSeconds + segment.timestamp + segment.duration, preferredTimescale: 600)

            if bufferStart == nil { bufferStart = segStart }
            bufferEnd = segEnd
            buffer = buffer.isEmpty ? trimmed : buffer + " " + trimmed

            // Flush buffer at sentence boundaries
            let lastChar = trimmed.last
            if lastChar.map({ sentenceEnders.contains($0) }) ?? false {
                flushBuffer(&buffer, start: &bufferStart, end: &bufferEnd, into: &cues)
            }
        }

        // Flush any remaining text
        flushBuffer(&buffer, start: &bufferStart, end: &bufferEnd, into: &cues)
        return cues
    }

    private func flushBuffer(
        _ buffer: inout String,
        start: inout CMTime?,
        end: inout CMTime?,
        into cues: inout [SubtitleCue]
    ) {
        guard !buffer.isEmpty, let s = start, let e = end else { return }
        let cleaned = SubtitleTextCleaner.clean(buffer)
        if !cleaned.isEmpty {
            cues.append(SubtitleCue(start: s, end: e, primaryText: cleaned))
        }
        buffer = ""
        start = nil
        end = nil
    }

    // MARK: - Audio Extraction
    // Extracted from asset as 16 kHz mono PCM WAV — identical to TranscriptionService's helper.

    private func extractAudioAsWav(from asset: AVAsset, timeRange: CMTimeRange?) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("substamp_legacy_\(UUID().uuidString)")
            .appendingPathExtension("wav")

        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw SubStampError.noAudioTrack
        }

        let sampleRate: Double = 16000
        let channelCount: AVAudioChannelCount = 1

        guard let audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: false
        ) else {
            throw SubStampError.exportFailed(underlying: NSError(
                domain: "SubStamp", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Could not create audio format"]
            ))
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw SubStampError.exportFailed(underlying: error)
        }

        if let range = timeRange {
            reader.timeRange = range
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channelCount),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw SubStampError.exportFailed(underlying: NSError(
                domain: "SubStamp", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Cannot add audio output to reader"]
            ))
        }
        reader.add(output)

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forWriting: outputURL, settings: audioFormat.settings)
        } catch {
            throw SubStampError.exportFailed(underlying: error)
        }

        guard reader.startReading() else {
            throw SubStampError.exportFailed(underlying: reader.error ?? NSError(domain: "SubStamp", code: -3))
        }

        var totalFrames: Int64 = 0
        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
            guard numSamples > 0 else { continue }

            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(
                blockBuffer, atOffset: 0,
                lengthAtOffsetOut: nil, totalLengthOut: &length,
                dataPointerOut: &dataPointer
            )
            guard status == kCMBlockBufferNoErr, let pointer = dataPointer else { continue }

            let frameCount = AVAudioFrameCount(numSamples)
            guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: frameCount) else { continue }
            pcmBuffer.frameLength = frameCount
            if let int16Data = pcmBuffer.int16ChannelData {
                memcpy(int16Data[0], pointer, length)
            }
            do {
                try audioFile.write(from: pcmBuffer)
                totalFrames += Int64(frameCount)
            } catch {
                AppLog.append("[Legacy] Error writing audio chunk: \(error.localizedDescription)")
            }
        }

        if reader.status == .failed {
            let error = reader.error ?? NSError(domain: "SubStamp", code: -6)
            try? FileManager.default.removeItem(at: outputURL)
            throw SubStampError.exportFailed(underlying: error)
        }

        guard totalFrames > 0 else {
            try? FileManager.default.removeItem(at: outputURL)
            throw SubStampError.speechAnalyzerError(underlying: NSError(
                domain: "SubStamp", code: -7,
                userInfo: [NSLocalizedDescriptionKey: "No audio samples extracted from video"]
            ))
        }

        return outputURL
    }

    // MARK: - Post-Processing
    // Mirrors the logic in TranscriptionService to ensure consistent output quality.

    private func postProcess(cues: [SubtitleCue]) -> [SubtitleCue] {
        let minDuration: Double = 0.8
        let mergeGapThreshold: Double = 0.25
        let overlapPadding: Double = 0.02
        let maxCharsPerLine = 42
        let maxLines = 2

        let sorted = cues.sorted { $0.start.seconds < $1.start.seconds }

        var merged: [SubtitleCue] = []
        var index = 0
        while index < sorted.count {
            var cue = sorted[index]
            cue.primaryText = SubtitleTextCleaner.clean(cue.primaryText)

            if cue.durationSeconds < minDuration, index + 1 < sorted.count {
                var next = sorted[index + 1]
                next.primaryText = SubtitleTextCleaner.clean(next.primaryText)
                let gap = max(0, next.start.seconds - cue.end.seconds)
                if gap <= mergeGapThreshold {
                    let mergedText = SubtitleTextCleaner.clean([cue.primaryText, next.primaryText].joined(separator: " "))
                    merged.append(SubtitleCue(id: cue.id, start: cue.start, end: next.end, primaryText: mergedText))
                    index += 2
                    continue
                }
            }

            if cue.durationSeconds < minDuration {
                var targetEndSeconds = cue.start.seconds + minDuration
                if index + 1 < sorted.count {
                    let nextStartSeconds = sorted[index + 1].start.seconds
                    targetEndSeconds = min(targetEndSeconds, max(cue.start.seconds, nextStartSeconds - overlapPadding))
                }
                if targetEndSeconds > cue.end.seconds {
                    cue.end = CMTime(seconds: targetEndSeconds, preferredTimescale: 600)
                }
            }

            merged.append(cue)
            index += 1
        }

        var output: [SubtitleCue] = []
        for cue in merged {
            output.append(contentsOf: splitCueIfNeeded(cue, maxCharsPerLine: maxCharsPerLine, maxLines: maxLines, minDuration: minDuration))
        }
        return output
    }

    private func splitCueIfNeeded(_ cue: SubtitleCue, maxCharsPerLine: Int, maxLines: Int, minDuration: Double) -> [SubtitleCue] {
        let cleaned = SubtitleTextCleaner.clean(cue.primaryText)
        let lines = wrapTextIntoLines(cleaned, maxCharsPerLine: maxCharsPerLine)
        if lines.isEmpty { return [] }

        var segments: [String] = stride(from: 0, to: lines.count, by: maxLines).map { start in
            let end = min(lines.count, start + maxLines)
            return lines[start..<end].joined(separator: " ")
        }

        let totalDuration = max(0, cue.end.seconds - cue.start.seconds)
        let maxSegmentsByTime = max(1, Int(floor(totalDuration / minDuration)))
        if segments.count > maxSegmentsByTime {
            segments = mergeSegmentsToFit(segments, targetCount: maxSegmentsByTime)
        }

        if segments.count <= 1 {
            var updated = cue
            updated.primaryText = segments.first ?? cleaned
            return [updated]
        }

        let weights = segments.map { max(1, $0.filter { !$0.isWhitespace && $0 != "\n" }.count) }
        let totalWeight = max(1, weights.reduce(0, +))
        var split: [SubtitleCue] = []
        var cursor = cue.start.seconds

        for i in segments.indices {
            let isLast = i == segments.count - 1
            let segmentEnd: Double
            if isLast {
                segmentEnd = cue.end.seconds
            } else {
                let delta = totalDuration * Double(weights[i]) / Double(totalWeight)
                segmentEnd = min(cue.end.seconds, cursor + delta)
            }
            split.append(SubtitleCue(
                id: i == 0 ? cue.id : UUID(),
                start: CMTime(seconds: cursor, preferredTimescale: 600),
                end: CMTime(seconds: segmentEnd, preferredTimescale: 600),
                primaryText: segments[i],
                secondaryText: cue.secondaryText,
                hasTranslationError: cue.hasTranslationError
            ))
            cursor = segmentEnd
        }

        return split.filter { $0.end.seconds > $0.start.seconds }
    }

    private func wrapTextIntoLines(_ text: String, maxCharsPerLine: Int) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        var lines: [String] = []
        var remaining = normalized
        while remaining.count > maxCharsPerLine {
            let splitIndex = remaining.index(remaining.startIndex, offsetBy: maxCharsPerLine)
            let candidate = String(remaining[..<splitIndex])
            if let lastSpace = candidate.lastIndex(of: " ") {
                let head = String(remaining[..<lastSpace]).trimmingCharacters(in: .whitespaces)
                if !head.isEmpty { lines.append(head) }
                remaining = String(remaining[remaining.index(after: lastSpace)...]).trimmingCharacters(in: .whitespaces)
            } else {
                let head = candidate.trimmingCharacters(in: .whitespaces)
                if !head.isEmpty { lines.append(head) }
                remaining = String(remaining[splitIndex...]).trimmingCharacters(in: .whitespaces)
            }
        }
        if !remaining.isEmpty { lines.append(remaining) }
        return lines
    }

    private func mergeSegmentsToFit(_ segments: [String], targetCount: Int) -> [String] {
        guard targetCount > 0 else { return segments }
        var segments = segments
        while segments.count > targetCount, segments.count >= 2 {
            var bestIndex = 0
            var bestLength = Int.max
            for i in 0..<(segments.count - 1) {
                let length = segments[i].count + segments[i + 1].count
                if length < bestLength {
                    bestLength = length
                    bestIndex = i
                }
            }
            segments[bestIndex] = [segments[bestIndex], segments[bestIndex + 1]].joined(separator: " ")
            segments.remove(at: bestIndex + 1)
        }
        return segments
    }
}
