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
        let audioURL = try await extractAudio(from: asset, timeRange: timeRange)
        // Note: We defer file cleanup until AFTER all processing is complete
        // to ensure the audio file remains valid during SpeechAnalyzer processing
        
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let duration = timeRange?.duration ?? asset.duration

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: audioURL)
        } catch {
            // Clean up the audio file if we can't read it
            try? FileManager.default.removeItem(at: audioURL)
            AppLog.append("Failed to open audio file: \(error.localizedDescription)")
            throw SubStampError.speechAnalyzerError(underlying: error)
        }
        
        let frameCount = audioFile.length
        guard frameCount > 0 else {
            try? FileManager.default.removeItem(at: audioURL)
            throw SubStampError.speechAnalyzerError(underlying: NSError(domain: "SubStamp", code: -10, userInfo: [NSLocalizedDescriptionKey: "Extracted audio has no samples. The video may have no audible track or export failed."]))
        }
        
        // Log audio file details for debugging
        AppLog.append("Audio file ready: \(frameCount) frames, format: \(audioFile.processingFormat)")
        
        do {
            try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
        } catch {
            try? FileManager.default.removeItem(at: audioURL)
            AppLog.append("SpeechAnalyzer failed to start: \(error.localizedDescription)")
            AppLog.append(error: error)
            throw SubStampError.speechAnalyzerError(underlying: error)
        }

        var cues: [SubtitleCue] = []
        var processingError: Error?
        
        do {
            for try await result in transcriber.results {
                let rawText = String(result.text.characters)
                let cleaned = normalizeText(rawText)
                guard !cleaned.isEmpty else { continue }
                let timeRange = result.range
                let start = timeRange.start
                let end = timeRange.end
                let formattedText = cleaned
                let cue = SubtitleCue(start: start, end: end, primaryText: formattedText)
                cues.append(cue)

                let progress = duration.seconds > 0 ? min(1.0, end.seconds / duration.seconds) : 0
                progressHandler(progress, cues.count)
            }
        } catch {
            processingError = error
            // SpeechAnalyzer can fail with Foundation._GenericObjCError.nilError
            // when the speech services crash or are interrupted (XPC invalidation)
            AppLog.append("SpeechAnalyzer: Input loop ending with error: \(error.localizedDescription)")
            AppLog.append(error: error)
        }
        
        // Clean up the audio file now that processing is complete
        try? FileManager.default.removeItem(at: audioURL)
        
        // Handle any errors that occurred during processing
        if let error = processingError {
            if cues.isEmpty {
                throw SubStampError.speechAnalyzerError(underlying: error)
            }
            // Log but continue with partial results
            AppLog.append("Continuing with \(cues.count) partial cues after speech analyzer error")
        }

        let processed = postProcess(cues: cues)
        return Result(cues: processed, duration: duration)
    }

    private func extractAudio(from asset: AVAsset, timeRange: CMTimeRange?) async throws -> URL {
        guard asset.tracks(withMediaType: .audio).isEmpty == false else {
            throw SubStampError.noAudioTrack
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("substamp_audio_\(UUID().uuidString)")
            .appendingPathExtension("m4a")

        if let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) {
            exporter.outputURL = outputURL
            exporter.outputFileType = .m4a
            exporter.timeRange = timeRange ?? CMTimeRange(start: .zero, duration: asset.duration)
            try await export(exporter)
            return outputURL
        } else {
            throw SubStampError.exportFailed(underlying: NSError(domain: "SubStamp", code: -1))
        }
    }

    private func export(_ exporter: AVAssetExportSession) async throws {
        try await withCheckedThrowingContinuation { continuation in
            exporter.exportAsynchronously {
                switch exporter.status {
                case .completed:
                    continuation.resume()
                case .failed:
                    continuation.resume(throwing: exporter.error ?? SubStampError.exportFailed(underlying: NSError(domain: "SubStamp", code: -2)))
                case .cancelled:
                    continuation.resume(throwing: SubStampError.backgroundTaskCancelled)
                default:
                    continuation.resume(throwing: SubStampError.exportFailed(underlying: NSError(domain: "SubStamp", code: -3)))
                }
            }
        }
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
