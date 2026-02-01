import AVFoundation
import Foundation

final class ExportService {
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

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("substamp_export_\(UUID().uuidString)")
            .appendingPathExtension("mp4")
        exporter.outputURL = outputURL

        // Prefer mp4 for better compatibility with social apps
        if exporter.supportedFileTypes.contains(.mp4) {
            exporter.outputFileType = .mp4
        } else if exporter.supportedFileTypes.contains(.mov) {
            exporter.outputFileType = .mov
        }

        let progressTask = Task {
            while !Task.isCancelled {
                let status = exporter.status
                if status == .exporting || status == .waiting {
                    progressHandler(Double(exporter.progress))
                } else if status == .completed || status == .failed || status == .cancelled {
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s update frequency
            }
        }

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

    private func export(_ exporter: AVAssetExportSession) async throws {
        try await withCheckedThrowingContinuation { continuation in
            exporter.exportAsynchronously {
                switch exporter.status {
                case .completed:
                    continuation.resume()
                case .failed:
                    continuation.resume(throwing: exporter.error ?? SubStampError.exportFailed(underlying: NSError(domain: "SubStamp", code: -11)))
                case .cancelled:
                    continuation.resume(throwing: SubStampError.backgroundTaskCancelled)
                default:
                    continuation.resume(throwing: SubStampError.exportFailed(underlying: NSError(domain: "SubStamp", code: -12)))
                }
            }
        }
    }
}
