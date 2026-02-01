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
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let transcriber = SpeechTranscriber(locale: locale, preset: .offlineTranscription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let duration = timeRange?.duration ?? asset.duration

        try await analyzer.start(inputAudioFile: audioURL, finishAfterFile: true)

        var cues: [SubtitleCue] = []
        for try await result in transcriber.results {
            guard result.isFinal else { continue }
            guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let fallbackStart = cues.last?.end ?? .zero
            let fallbackRange = CMTimeRange(start: fallbackStart, duration: CMTime(seconds: 1, preferredTimescale: 600))
            let timeRange = result.audioTimeRange ?? fallbackRange
            let start = timeRange.start
            let end = timeRange.end
            let formattedText = normalizeText(result.text)
            let cue = SubtitleCue(start: start, end: end, primaryText: formattedText)
            cues.append(cue)

            let progress = duration.seconds > 0 ? min(1.0, end.seconds / duration.seconds) : 0
            progressHandler(progress, cues.count)
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
