import AVFoundation
import Foundation

final class ExportService {
    private let progressPollIntervalNS: UInt64 = 100_000_000

    func export(
        composition: AVMutableComposition,
        videoComposition: AVMutableVideoComposition,
        preset: ExportPreset,
        progressHandler: @escaping (Double) -> Void
    ) async throws -> URL {
        let presetName = selectPreset(for: composition, preference: preset)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: presetName) else {
            throw SubStampError.exportFailed(underlying: NSError(domain: "SubStamp", code: -10))
        }
        exporter.videoComposition = videoComposition
        exporter.shouldOptimizeForNetworkUse = true

        let outputURL = makeOutputURL(prefix: "substamp_export")
        configureOutput(for: exporter, outputURL: outputURL)

        let progressTask = makeProgressTask(exporter: exporter, progressHandler: progressHandler)

        do {
            try await export(exporter)
            progressTask.cancel()
            progressHandler(1.0)
            return outputURL
        } catch {
            exporter.cancelExport()
            progressTask.cancel()
            throw error
        }
    }

    func concatenate(
        segmentURLs: [URL],
        preference: ExportPreset,
        progressHandler: @escaping (Double) -> Void
    ) async throws -> URL {
        guard !segmentURLs.isEmpty else {
            throw SubStampError.exportFailed(underlying: NSError(
                domain: "SubStamp",
                code: -31,
                userInfo: [NSLocalizedDescriptionKey: "No segment files to concatenate."]
            ))
        }

        let composition = AVMutableComposition()
#if DEBUG
        AppLog.append("[EXPORT] concatenate start segments=\(segmentURLs.count)")
#endif
        let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )
        let audioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )

        var cursor = CMTime.zero
        for (index, url) in segmentURLs.enumerated() {
            let asset = AVAsset(url: url)
            let timeRange = CMTimeRange(start: .zero, duration: asset.duration)

            if let sourceVideo = asset.tracks(withMediaType: .video).first {
                try videoTrack?.insertTimeRange(timeRange, of: sourceVideo, at: cursor)
                if index == 0 {
                    videoTrack?.preferredTransform = sourceVideo.preferredTransform
                }
            }

            if let sourceAudio = asset.tracks(withMediaType: .audio).first {
                try audioTrack?.insertTimeRange(timeRange, of: sourceAudio, at: cursor)
            }

            cursor = cursor + asset.duration
            let ingestProgress = Double(index + 1) / Double(segmentURLs.count)
            progressHandler(ingestProgress * 0.2)
        }

        let presets = AVAssetExportSession.exportPresets(compatibleWith: composition)
        let presetName = presets.contains(AVAssetExportPresetPassthrough)
            ? AVAssetExportPresetPassthrough
            : selectPreset(for: composition, preference: preference)

        guard let exporter = AVAssetExportSession(asset: composition, presetName: presetName) else {
            throw SubStampError.exportFailed(underlying: NSError(domain: "SubStamp", code: -32))
        }
        exporter.shouldOptimizeForNetworkUse = true

        let outputURL = makeOutputURL(prefix: "substamp_merged")
        configureOutput(for: exporter, outputURL: outputURL)

        let progressTask = makeProgressTask(exporter: exporter) { progress in
            progressHandler(0.2 + progress * 0.8)
        }

        do {
            try await export(exporter)
            progressTask.cancel()
            progressHandler(1.0)
#if DEBUG
            AppLog.append("[EXPORT] concatenate done")
#endif
            return outputURL
        } catch {
            exporter.cancelExport()
            progressTask.cancel()
#if DEBUG
            AppLog.append("[EXPORT] concatenate failed: \(error.localizedDescription)")
#endif
            throw error
        }
    }

    private func selectPreset(for asset: AVAsset, preference: ExportPreset) -> String {
        let presets = AVAssetExportSession.exportPresets(compatibleWith: asset)
        switch preference {
        case .fast:
            if presets.contains(AVAssetExportPreset640x480) { return AVAssetExportPreset640x480 }
            if presets.contains(AVAssetExportPresetLowQuality) { return AVAssetExportPresetLowQuality }
        case .balanced:
            if presets.contains(AVAssetExportPreset1280x720) { return AVAssetExportPreset1280x720 }
            if presets.contains(AVAssetExportPresetMediumQuality) { return AVAssetExportPresetMediumQuality }
        case .best:
            if presets.contains(AVAssetExportPresetHEVCHighestQuality) { return AVAssetExportPresetHEVCHighestQuality }
            if presets.contains(AVAssetExportPresetHighestQuality) { return AVAssetExportPresetHighestQuality }
        }
        return AVAssetExportPresetHighestQuality
    }

    private func makeProgressTask(
        exporter: AVAssetExportSession,
        progressHandler: @escaping (Double) -> Void
    ) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                let status = exporter.status
                if status == .exporting || status == .waiting {
                    progressHandler(Double(exporter.progress))
                } else if status == .completed || status == .failed || status == .cancelled {
                    break
                }
                try? await Task.sleep(nanoseconds: progressPollIntervalNS)
            }
        }
    }

    private func makeOutputURL(prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)_\(UUID().uuidString)")
            .appendingPathExtension("mp4")
    }

    private func configureOutput(for exporter: AVAssetExportSession, outputURL: URL) {
        exporter.outputURL = outputURL

        // Prefer mp4 for better compatibility with social apps
        if exporter.supportedFileTypes.contains(.mp4) {
            exporter.outputFileType = .mp4
        } else if exporter.supportedFileTypes.contains(.mov) {
            exporter.outputFileType = .mov
        }
    }

    private func export(_ exporter: AVAssetExportSession) async throws {
        try await withCheckedThrowingContinuation { continuation in
            exporter.exportAsynchronously {
                switch exporter.status {
                case .completed:
                    continuation.resume()
                case .failed:
#if DEBUG
                    let details = exporter.error?.localizedDescription ?? "unknown"
                    AppLog.append("[EXPORT] failed status=failed error=\(details)")
#endif
                    continuation.resume(throwing: exporter.error ?? SubStampError.exportFailed(underlying: NSError(domain: "SubStamp", code: -11)))
                case .cancelled:
#if DEBUG
                    let details = exporter.error?.localizedDescription ?? "unknown"
                    AppLog.append("[EXPORT] failed status=cancelled error=\(details)")
#endif
                    continuation.resume(throwing: SubStampError.backgroundTaskCancelled)
                default:
#if DEBUG
                    let details = exporter.error?.localizedDescription ?? "unknown"
                    AppLog.append("[EXPORT] failed status=\(exporter.status.rawValue) error=\(details)")
#endif
                    continuation.resume(throwing: SubStampError.exportFailed(underlying: NSError(domain: "SubStamp", code: -12)))
                }
            }
        }
    }
}
