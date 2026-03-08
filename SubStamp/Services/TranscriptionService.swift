import AVFoundation
import Foundation
import Speech

final class TranscriptionService {
    struct Result {
        let cues: [SubtitleCue]
        let duration: CMTime
    }

    func transcribe(
        asset: AVAsset,
        locale: Locale,
        timeRange: CMTimeRange? = nil,
        progressHandler: @escaping (Double, Int) -> Void
    ) async throws -> Result {
        // Step 1: Validate SpeechTranscriber availability and locale
        guard SpeechTranscriber.isAvailable else {
            AppLog.append("SpeechTranscriber is not available on this device")
            throw SubStampError.speechAnalyzerError(underlying: NSError(
                domain: "SubStamp",
                code: -100,
                userInfo: [NSLocalizedDescriptionKey: "Speech transcription is not available on this device."]
            ))
        }
        
        // Get supported locales and find a matching one
        let supportedLocales = await SpeechTranscriber.supportedLocales
        let installedLocales = await SpeechTranscriber.installedLocales
        AppLog.append("[LOCALE] Supported: \(supportedLocales.count), Installed: \(installedLocales.count)")
        AppLog.append("[LOCALE] Installed locale IDs: \(installedLocales.map { $0.identifier }.joined(separator: ", "))")
        
        // Find the best matching locale from supported locales
        let selectedLocale = findBestMatchingLocale(desired: locale, from: supportedLocales)
        let isInstalled = installedLocales.contains { $0.identifier == selectedLocale.identifier }
        AppLog.append("[LOCALE] Requested: \(locale.identifier), Selected: \(selectedLocale.identifier), Installed: \(isInstalled)")
        
        // Step 2: Create transcriber with validated locale
        let transcriber = SpeechTranscriber(
            locale: selectedLocale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        
        // Step 3: Ensure speech assets are installed via AssetInventory
        AppLog.append("Checking speech asset installation...")
        if isInstalled {
            AppLog.append("Speech assets already confirmed installed for locale: \(selectedLocale.identifier). Skipping AssetInventory check to avoid OS limits.")
        } else {
            do {
                if let installRequest = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    AppLog.append("Installing speech assets for locale: \(selectedLocale.identifier)")
                    try await installRequest.downloadAndInstall()
                    AppLog.append("Speech assets installed successfully")
                } else {
                    AppLog.append("Speech assets already installed for locale: \(selectedLocale.identifier) (per AssetInventory)")
                }
            } catch {
                AppLog.append("Speech asset installation failed: \(error.localizedDescription)")
                // If we get the "Too many allocated locales" error but the locale is allegedly in installedLocales, we try to proceed anyway
                if error.localizedDescription.contains("Too many allocated locales") {
                    AppLog.append("[WARNING] Hit OS locale limit, but proceeding as locale may already be available.")
                } else {
                    throw SubStampError.assetInstallFailed(locale: selectedLocale.identifier)
                }
            }
        }
        
        // Step 4: Extract audio from video
        let rawAudioURL = try await extractAudioAsWav(from: asset, timeRange: timeRange)
        
        // Step 5: Convert audio to format compatible with SpeechAnalyzer
        // SpeechAnalyzer works best with specific formats - let's query what it wants
        let requiredFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber],
            considering: nil
        )
        if let fmt = requiredFormat {
            AppLog.append("[FORMAT] Required: \(fmt.sampleRate) Hz, \(fmt.channelCount) ch, \(fmt.commonFormat.rawValue)")
        } else {
            AppLog.append("[FORMAT] Required: nil (will use source format)")
        }
        
        // Convert audio to compatible format if needed
        let audioURL: URL
        if let format = requiredFormat {
            AppLog.append("[CONVERT] Starting audio format conversion...")
            audioURL = try await convertAudioFile(from: rawAudioURL, to: format)
            try? FileManager.default.removeItem(at: rawAudioURL)
            AppLog.append("[CONVERT] Conversion complete")
        } else {
            audioURL = rawAudioURL
            AppLog.append("[CONVERT] No conversion needed, using source format")
        }
        defer { try? FileManager.default.removeItem(at: audioURL) }
        
        let duration = timeRange?.duration ?? asset.duration
        
        // Step 6: Open audio file and verify
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: audioURL)
        } catch {
            AppLog.append("Failed to open audio file: \(error.localizedDescription)")
            throw SubStampError.speechAnalyzerError(underlying: error)
        }
        
        let frameCount = audioFile.length
        guard frameCount > 0 else {
            throw SubStampError.speechAnalyzerError(underlying: NSError(
                domain: "SubStamp",
                code: -10,
                userInfo: [NSLocalizedDescriptionKey: "Extracted audio has no samples."]
            ))
        }
        
        let format = audioFile.processingFormat
        let durationSecs = Double(frameCount) / format.sampleRate
        AppLog.append("[AUDIO] Final file: \(frameCount) frames, \(format.sampleRate) Hz, \(format.channelCount) ch")
        AppLog.append("[AUDIO] Duration: \(String(format: "%.2f", durationSecs))s, Format: \(format.commonFormat.rawValue), Interleaved: \(format.isInterleaved)")
        AppLog.append("[AUDIO] File URL: \(audioURL.lastPathComponent)")
        
        // Step 7: Create analyzer and start with audio file
        AppLog.append("[ANALYZER] Creating SpeechAnalyzer with SpeechTranscriber module...")
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        
        do {
            AppLog.append("[ANALYZER] Calling start(inputAudioFile:finishAfterFile:true)...")
            try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
            AppLog.append("[ANALYZER] start() returned successfully, waiting for results...")
        } catch {
            AppLog.append("[ANALYZER] start() FAILED: \(error.localizedDescription)")
            AppLog.append("[ANALYZER] Error type: \(type(of: error)), Full error: \(error)")
            throw SubStampError.speechAnalyzerError(underlying: error)
        }

        // Step 7: Process transcription results
        var cues: [SubtitleCue] = []
        var processingError: Error?
        
        AppLog.append("[RESULTS] Starting to iterate transcriber.results...")
        var resultCount = 0
        let resultLogInterval = 50
        do {
            for try await result in transcriber.results {
                resultCount += 1
                let rawText = String(result.text.characters)
                let cleaned = SubtitleTextCleaner.clean(rawText)
                if resultCount <= 5 || resultCount.isMultiple(of: resultLogInterval) {
                    AppLog.append("[RESULT #\(resultCount)] Raw: '\(rawText.prefix(50))...' at \(result.range.start.seconds)s-\(result.range.end.seconds)s")
                }
                guard !cleaned.isEmpty else {
                    continue
                }
                let timeRange = result.range
                let start = timeRange.start
                let end = timeRange.end
                let formattedText = cleaned
                let cue = SubtitleCue(start: start, end: end, primaryText: formattedText)
                cues.append(cue)

                let progress = duration.seconds > 0 ? min(1.0, end.seconds / duration.seconds) : 0
                progressHandler(progress, cues.count)
            }
            AppLog.append("[RESULTS] Iteration completed normally, got \(resultCount) results, \(cues.count) cues")
        } catch {
            processingError = error
            AppLog.append("[RESULTS] Iteration FAILED after \(resultCount) results: \(error.localizedDescription)")
            AppLog.append("[RESULTS] Error type: \(type(of: error)), Full: \(error)")
        }
        
        // Clean up the audio file now that processing is complete
        try? FileManager.default.removeItem(at: audioURL)
        
        // Handle any errors that occurred during processing
        if let error = processingError {
            if cues.isEmpty {
                AppLog.append("[ERROR] No cues captured, throwing error")
                throw SubStampError.speechAnalyzerError(underlying: error)
            }
            AppLog.append("[RECOVERY] Continuing with \(cues.count) partial cues despite error")
        } else if cues.isEmpty {
            AppLog.append("[ERROR] No error thrown, but 0 cues generated. Likely silent audio or model mismatch.")
            throw SubStampError.speechAnalyzerError(underlying: NSError(
                domain: "SubStamp",
                code: -11,
                userInfo: [NSLocalizedDescriptionKey: "No subtitles were generated. Please check if the audio matches the selected language."]
            ))
        }

        AppLog.append("Transcription completed: \(cues.count) cues")
        let processed = postProcess(cues: cues)
        return Result(cues: processed, duration: duration)
    }
    
    /// Find the best matching locale from supported locales
    private func findBestMatchingLocale(desired: Locale, from supported: [Locale]) -> Locale {
        // First, try exact match or BCP47 match
        if let match = supported.first(where: { 
            $0.identifier == desired.identifier || 
            $0.identifier(.bcp47) == desired.identifier(.bcp47) 
        }) {
            return match
        }
        
        // Try matching with BCP47 identifier
        let desiredBCP47 = desired.identifier(.bcp47)
        if let match = supported.first(where: { $0.identifier(.bcp47) == desiredBCP47 }) {
            return match
        }
        
        // Try matching just the language code (e.g., "en" from "en_US" or "en-US")
        let desiredLanguage = desired.language.languageCode?.identifier ?? String(desired.identifier.prefix(2))
        if let match = supported.first(where: { 
            $0.language.languageCode?.identifier == desiredLanguage
        }) {
            AppLog.append("Using fallback locale: \(match.identifier) for requested: \(desired.identifier)")
            return match
        }
        
        // Last resort: use English if available, otherwise first supported locale
        if let english = supported.first(where: { $0.identifier.hasPrefix("en") }) {
            AppLog.append("No matching locale found, falling back to English: \(english.identifier)")
            return english
        }
        
        if let first = supported.first {
            AppLog.append("No matching locale found, falling back to first supported: \(first.identifier)")
            return first
        }
        
        // If nothing is available, return the original (will likely fail)
        AppLog.append("WARNING: No supported locales found, using original: \(desired.identifier)")
        return desired
    }

    private func extractAudioAsWav(from asset: AVAsset, timeRange: CMTimeRange?) async throws -> URL {
        guard let audioTrack = asset.tracks(withMediaType: .audio).first else {
            throw SubStampError.noAudioTrack
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("substamp_audio_\(UUID().uuidString)")
            .appendingPathExtension("wav")
        
        // Configure reader with time range
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            AppLog.append("Failed to create AVAssetReader: \(error.localizedDescription)")
            throw SubStampError.exportFailed(underlying: error)
        }
        
        if let range = timeRange {
            reader.timeRange = range
        }
        
        // Output settings: Mono, 16kHz, 16-bit Linear PCM (optimal for speech recognition)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        
        let trackOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        trackOutput.alwaysCopiesSampleData = false
        
        guard reader.canAdd(trackOutput) else {
            AppLog.append("Cannot add track output to reader")
            throw SubStampError.exportFailed(underlying: NSError(
                domain: "SubStamp",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Cannot configure audio reader"]
            ))
        }
        reader.add(trackOutput)
        
        // Start reading
        guard reader.startReading() else {
            let error = reader.error ?? NSError(domain: "SubStamp", code: -5)
            AppLog.append("Failed to start reading: \(error.localizedDescription)")
            throw SubStampError.exportFailed(underlying: error)
        }
        
        // Create WAV file with proper header
        let audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        )!
        
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(
                forWriting: outputURL,
                settings: audioFormat.settings,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
        } catch {
            AppLog.append("Failed to create output audio file: \(error.localizedDescription)")
            throw SubStampError.exportFailed(underlying: error)
        }
        
        // Read and write samples
        var totalFrames: Int64 = 0
        while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
            guard CMSampleBufferDataIsReady(sampleBuffer) else { continue }
            
            let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
            guard numSamples > 0, let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                continue
            }
            
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &length,
                dataPointerOut: &dataPointer
            )
            
            guard status == kCMBlockBufferNoErr, let pointer = dataPointer else {
                continue
            }
            
            // Create PCM buffer and write to file
            let frameCount = AVAudioFrameCount(numSamples)
            guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: frameCount) else {
                continue
            }
            
            pcmBuffer.frameLength = frameCount
            if let int16Data = pcmBuffer.int16ChannelData {
                memcpy(int16Data[0], pointer, length)
            }
            
            do {
                try audioFile.write(from: pcmBuffer)
                totalFrames += Int64(frameCount)
            } catch {
                AppLog.append("Error writing audio buffer: \(error.localizedDescription)")
            }
        }
        
        // Check if reading completed successfully
        if reader.status == .failed {
            let error = reader.error ?? NSError(domain: "SubStamp", code: -6)
            try? FileManager.default.removeItem(at: outputURL)
            AppLog.append("Audio reading failed: \(error.localizedDescription)")
            throw SubStampError.exportFailed(underlying: error)
        }
        
        AppLog.append("Audio extracted: \(totalFrames) frames at 16kHz mono PCM")
        
        guard totalFrames > 0 else {
            try? FileManager.default.removeItem(at: outputURL)
            throw SubStampError.speechAnalyzerError(underlying: NSError(
                domain: "SubStamp",
                code: -7,
                userInfo: [NSLocalizedDescriptionKey: "No audio samples extracted from video"]
            ))
        }
        
        return outputURL
    }
    
    /// Convert audio file to the format required by SpeechAnalyzer
    private func convertAudioFile(from sourceURL: URL, to targetFormat: AVAudioFormat) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("substamp_converted_\(UUID().uuidString)")
            .appendingPathExtension("caf")
        
        // Open source file
        let sourceFile: AVAudioFile
        do {
            sourceFile = try AVAudioFile(forReading: sourceURL)
        } catch {
            AppLog.append("Failed to open source audio for conversion: \(error.localizedDescription)")
            throw SubStampError.exportFailed(underlying: error)
        }
        
        let sourceFormat = sourceFile.processingFormat
        AppLog.append("Converting audio: \(sourceFormat.sampleRate) Hz \(sourceFormat.channelCount)ch -> \(targetFormat.sampleRate) Hz \(targetFormat.channelCount)ch")
        
        // Create converter
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            AppLog.append("Could not create audio converter - using source format")
            return sourceURL
        }
        
        // Create output file
        let outputFile: AVAudioFile
        do {
            outputFile = try AVAudioFile(
                forWriting: outputURL,
                settings: targetFormat.settings,
                commonFormat: targetFormat.commonFormat,
                interleaved: targetFormat.isInterleaved
            )
        } catch {
            AppLog.append("Failed to create output audio file: \(error.localizedDescription)")
            throw SubStampError.exportFailed(underlying: error)
        }
        
        // Convert in chunks
        let bufferSize: AVAudioFrameCount = 4096
        var totalFrames: Int64 = 0
        
        while sourceFile.framePosition < sourceFile.length {
            let remainingFrames = AVAudioFrameCount(sourceFile.length - sourceFile.framePosition)
            let framesToRead = min(bufferSize, remainingFrames)
            
            guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: framesToRead) else {
                continue
            }
            
            do {
                try sourceFile.read(into: sourceBuffer, frameCount: framesToRead)
            } catch {
                AppLog.append("Error reading source audio: \(error.localizedDescription)")
                continue
            }
            
            // Calculate output buffer size based on sample rate ratio
            let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
            let outputCapacity = AVAudioFrameCount(Double(framesToRead) * ratio * 1.2) // 20% buffer
            
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
                continue
            }
            
            // Use simple convert method
            do {
                try converter.convert(to: outputBuffer, from: sourceBuffer)
            } catch {
                AppLog.append("Conversion error: \(error.localizedDescription)")
                continue
            }
            
            if outputBuffer.frameLength > 0 {
                do {
                    try outputFile.write(from: outputBuffer)
                    totalFrames += Int64(outputBuffer.frameLength)
                } catch {
                    AppLog.append("Error writing converted audio: \(error.localizedDescription)")
                }
            }
        }
        
        AppLog.append("Audio conversion complete: \(totalFrames) frames at \(targetFormat.sampleRate) Hz")
        
        guard totalFrames > 0 else {
            try? FileManager.default.removeItem(at: outputURL)
            throw SubStampError.exportFailed(underlying: NSError(
                domain: "SubStamp",
                code: -8,
                userInfo: [NSLocalizedDescriptionKey: "Audio conversion produced no output"]
            ))
        }
        
        return outputURL
    }

    private func postProcess(cues: [SubtitleCue]) -> [SubtitleCue] {
        // Keep cues readable, but avoid showing future text early.
        // In particular, do not merge across real pauses, otherwise the later cue's text
        // will appear during silence (sometimes seconds early).
        let minDuration: Double = 0.8
        let mergeGapThreshold: Double = 0.25
        let overlapPadding: Double = 0.02
        let maxCharsPerLine = 42
        let maxLines = 2

        // Ensure stable ordering before we do any timing-based operations.
        let cues = cues.sorted { $0.start.seconds < $1.start.seconds }

        // 1) Clean text and merge very short cues to avoid rapid flashes.
        var merged: [SubtitleCue] = []
        var index = 0
        while index < cues.count {
            var cue = cues[index]
            cue.primaryText = SubtitleTextCleaner.clean(cue.primaryText)

            if cue.durationSeconds < minDuration, index + 1 < cues.count {
                var next = cues[index + 1]
                next.primaryText = SubtitleTextCleaner.clean(next.primaryText)
                let gap = max(0, next.start.seconds - cue.end.seconds)

                // Only merge if the cues are essentially continuous in time.
                // Otherwise we'd show the next cue's text early during a pause.
                if gap <= mergeGapThreshold {
                    let mergedText = SubtitleTextCleaner.clean([cue.primaryText, next.primaryText].joined(separator: " "))
                    merged.append(SubtitleCue(id: cue.id, start: cue.start, end: next.end, primaryText: mergedText))
                    index += 2
                    continue
                }
            }

            if cue.durationSeconds < minDuration {
                var targetEndSeconds = cue.start.seconds + minDuration
                if index + 1 < cues.count {
                    let nextStartSeconds = cues[index + 1].start.seconds
                    // Never extend into the next cue's start.
                    targetEndSeconds = min(targetEndSeconds, max(cue.start.seconds, nextStartSeconds - overlapPadding))
                }
                if targetEndSeconds > cue.end.seconds {
                    cue.end = CMTime(seconds: targetEndSeconds, preferredTimescale: 600)
                }
            }

            merged.append(cue)
            index += 1
        }

        // 2) Split long cues into multiple cues instead of truncating the text.
        var output: [SubtitleCue] = []
        for cue in merged {
            output.append(contentsOf: splitCueIfNeeded(cue, maxCharsPerLine: maxCharsPerLine, maxLines: maxLines, minDuration: minDuration))
        }
        return output
    }

    private func splitCueIfNeeded(_ cue: SubtitleCue, maxCharsPerLine: Int, maxLines: Int, minDuration: Double) -> [SubtitleCue] {
        let cleaned = SubtitleTextCleaner.clean(cue.primaryText)
        let lines = wrapTextIntoLines(cleaned, maxCharsPerLine: maxCharsPerLine)
        if lines.isEmpty {
            return []
        }

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
        let endSeconds = cue.end.seconds

        for i in segments.indices {
            let isLast = i == segments.count - 1
            let segmentEnd: Double
            if isLast {
                segmentEnd = endSeconds
            } else {
                let delta = totalDuration * Double(weights[i]) / Double(totalWeight)
                segmentEnd = min(endSeconds, cursor + delta)
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

        if !remaining.isEmpty {
            lines.append(remaining)
        }

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
            let merged = [segments[bestIndex], segments[bestIndex + 1]].joined(separator: " ")
            segments[bestIndex] = merged
            segments.remove(at: bestIndex + 1)
        }
        return segments
    }
}
