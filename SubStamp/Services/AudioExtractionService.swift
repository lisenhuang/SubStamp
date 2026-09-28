import AVFoundation
import Foundation

/// Decodes a readable audio prefix even when an MP4's sample table extends past EOF.
nonisolated enum AudioExtractionService {
    struct Result: Sendable {
        let url: URL
        let duration: CMTime
        let recoveredAudio: Bool
    }

    static func canRecover(error: NSError?, frames: Int64) -> Bool {
        frames > 0 && isInvalidSampleCursor(error)
    }

    static func isInvalidSampleCursor(_ error: NSError?) -> Bool {
        guard let error else { return false }
        return error.domain == AVFoundationErrorDomain && error.code == AVError.invalidSampleCursor.rawValue
    }

    static func extract(from asset: AVAsset, timeRange: CMTimeRange? = nil) async throws -> Result {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw SubStampError.noAudioTrack
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("substamp_audio_\(UUID().uuidString).wav")
        var keepFile = false
        defer { if !keepFile { try? FileManager.default.removeItem(at: url) } }

        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
        let reader = try AVAssetReader(asset: asset)
        if let timeRange { reader.timeRange = timeRange }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: format.settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw SubStampError.exportFailed(underlying: NSError(domain: "SubStamp", code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Cannot configure audio reader"]))
        }
        reader.add(output)

        // Closing the file finalizes the WAV header before the speech engine opens it.
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings,
                                               commonFormat: .pcmFormatInt16, interleaved: true)
        defer { file = nil }
        guard reader.startReading() else {
            throw SubStampError.exportFailed(underlying: reader.error ?? NSError(domain: "SubStamp", code: -5))
        }
        defer { if reader.status == .reading { reader.cancelReading() } }

        var frames: Int64 = 0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let count = CMSampleBufferGetNumSamples(sample)
            guard CMSampleBufferDataIsReady(sample), count > 0,
                  let block = CMSampleBufferGetDataBuffer(sample),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let destination = buffer.int16ChannelData?[0] else {
                throw SubStampError.exportFailed(underlying: NSError(domain: "SubStamp", code: -9,
                    userInfo: [NSLocalizedDescriptionKey: "Could not read decoded audio samples"]))
            }
            let byteCount = count * MemoryLayout<Int16>.size
            guard CMBlockBufferGetDataLength(block) == byteCount,
                  CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: byteCount, destination: destination) == kCMBlockBufferNoErr else {
                throw SubStampError.exportFailed(underlying: NSError(domain: "SubStamp", code: -9,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid decoded audio buffer"]))
            }
            buffer.frameLength = AVAudioFrameCount(count)
            try file!.write(from: buffer)
            frames += Int64(count)
        }
        try Task.checkCancellation()
        let recovered = reader.status == .failed && canRecover(error: reader.error as NSError?, frames: frames)
        guard reader.status == .completed || recovered else {
            if reader.status == .cancelled { throw CancellationError() }
            throw SubStampError.exportFailed(underlying: reader.error ?? NSError(domain: "SubStamp", code: -6))
        }
        guard frames > 0 else {
            throw SubStampError.speechAnalyzerError(underlying: NSError(domain: "SubStamp", code: -7,
                userInfo: [NSLocalizedDescriptionKey: "No audio samples extracted from video"]))
        }
        file = nil
        let duration = CMTime(value: frames, timescale: 16000)
        if recovered {
            AppLog.append("[AUDIO RECOVERY] Kept \(duration.seconds)s of readable audio after \(String(describing: reader.error)); unreadable ending omitted")
        } else {
            AppLog.append("Audio extracted: \(frames) frames at 16kHz mono PCM")
        }
        keepFile = true
        return Result(url: url, duration: duration, recoveredAudio: recovered)
    }
}
