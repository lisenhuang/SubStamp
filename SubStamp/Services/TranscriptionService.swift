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
        do {
            if let installRequest = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                AppLog.append("Installing speech assets for locale: \(selectedLocale.identifier)")
                try await installRequest.downloadAndInstall()
                AppLog.append("Speech assets installed successfully")
            } else {
                AppLog.append("Speech assets already installed for locale: \(selectedLocale.identifier)")
            }
        } catch {
            AppLog.append("Speech asset installation failed: \(error.localizedDescription)")
            throw SubStampError.assetInstallFailed(locale: selectedLocale.identifier)
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
        do {
            for try await result in transcriber.results {
                resultCount += 1
                let rawText = String(result.text.characters)
                let cleaned = normalizeText(rawText)
                AppLog.append("[RESULT #\(resultCount)] Raw: '\(rawText.prefix(50))...' at \(result.range.start.seconds)s-\(result.range.end.seconds)s")
                guard !cleaned.isEmpty else { 
                    AppLog.append("[RESULT #\(resultCount)] Skipped (empty after cleaning)")
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
        }

        AppLog.append("Transcription completed: \(cues.count) cues")
        let processed = postProcess(cues: cues)
        return Result(cues: processed, duration: duration)
    }
    
    /// Find the best matching locale from supported locales
    private func findBestMatchingLocale(desired: Locale, from supported: [Locale]) -> Locale {
        // First, try exact match
        if supported.contains(where: { $0.identifier == desired.identifier }) {
            return desired
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
        var output: [SubtitleCue] = []
        var index = 0
        while index < cues.count {
            var cue = cues[index]
            let minDuration: Double = 0.8
            let maxCharsPerLine = 42
            let maxLines = 2

            cue.primaryText = normalizeText(cue.primaryText)
            cue.primaryText = clampText(cue.primaryText, maxCharsPerLine: maxCharsPerLine, maxLines: maxLines)

            if cue.durationSeconds < minDuration, index + 1 < cues.count {
                let next = cues[index + 1]
                let mergedText = [cue.primaryText, next.primaryText].joined(separator: " ")
                let merged = SubtitleCue(
                    start: cue.start,
                    end: next.end,
                    primaryText: clampText(mergedText, maxCharsPerLine: maxCharsPerLine, maxLines: maxLines)
                )
                output.append(merged)
                index += 2
                continue
            }

            if cue.durationSeconds < minDuration {
                cue.end = CMTime(seconds: cue.start.seconds + minDuration, preferredTimescale: 600)
            }

            output.append(cue)
            index += 1
        }
        return output
    }

    private func normalizeText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = trimmed.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return collapsed
    }

    private func clampText(_ text: String, maxCharsPerLine: Int, maxLines: Int) -> String {
        guard text.count > maxCharsPerLine else { return text }
        var lines: [String] = []
        var current = text
        for _ in 0..<maxLines {
            if current.count <= maxCharsPerLine {
                lines.append(current)
                current = ""
                break
            }
            let splitIndex = current.index(current.startIndex, offsetBy: maxCharsPerLine)
            let line = String(current[..<splitIndex])
            if let lastSpace = line.lastIndex(of: " ") {
                let head = String(current[..<lastSpace])
                lines.append(head)
                current = String(current[current.index(after: lastSpace)...])
            } else {
                lines.append(line)
                current = String(current[splitIndex...])
            }
        }
        if !current.isEmpty {
            lines[lines.count - 1] += "…"
        }
        return lines.joined(separator: "\n")
    }
}
