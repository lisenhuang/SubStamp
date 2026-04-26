import AVFoundation
import Foundation
import MachO

final class ExportService {
    private let progressPollIntervalNS: UInt64 = 100_000_000
    private let largeFileRiskThresholdBytes: Int64 = 3_800_000_000

    func export(
        composition: AVMutableComposition,
        videoComposition: AVMutableVideoComposition,
        preset: ExportPreset,
        label: String,
        preferQuickTimeMovie: Bool = true,
        progressHandler: @escaping (Double) -> Void
    ) async throws -> URL {
        let presetName = selectPreset(for: composition, preference: preset)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: presetName) else {
            throw SubStampError.exportFailed(underlying: NSError(domain: "SubStamp", code: -10))
        }
        exporter.videoComposition = videoComposition
        exporter.shouldOptimizeForNetworkUse = false
        exporter.directoryForTemporaryFiles = FileManager.default.temporaryDirectory

        let outputURL = configureOutput(
            for: exporter,
            prefix: "substamp_export",
            preferQuickTimeMovie: preferQuickTimeMovie
        )

        AppLog.append(
            "[EXPORT] \(label) session(start) preset=\(presetName) duration=\(String(format: "%.2f", composition.duration.seconds))s render=\(format(size: videoComposition.renderSize)) frame=\(String(format: "%.4f", videoComposition.frameDuration.seconds))s instructions=\(videoComposition.instructions.count) fileType=\(exporter.outputFileType?.rawValue ?? "nil") optimize=\(exporter.shouldOptimizeForNetworkUse) freeDisk=\(formattedAvailableDiskSpace()) output=\(outputURL.lastPathComponent)"
        )

        let progressTask = makeProgressTask(exporter: exporter, label: label, progressHandler: progressHandler)

        do {
            try await export(exporter)
            progressTask.cancel()
            progressHandler(1.0)
            AppLog.append("[EXPORT] \(label) session(done) file=\(outputURL.lastPathComponent) size=\(formattedFileSize(at: outputURL))")
            return outputURL
        } catch {
            exporter.cancelExport()
            progressTask.cancel()
            AppLog.append("[EXPORT] \(label) session(throw) \(describe(error: error))")
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
        AppLog.append("[EXPORT] merge(start) segments=\(segmentURLs.count)")
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
            let segmentVideoSize = asset.tracks(withMediaType: .video).first?.naturalSize ?? .zero
            AppLog.append(
                "[EXPORT] merge input \(index + 1)/\(segmentURLs.count) file=\(url.lastPathComponent) size=\(formattedFileSize(at: url)) duration=\(String(format: "%.2f", asset.duration.seconds))s video=\(format(size: segmentVideoSize))"
            )

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

        let estimatedMergedBytes = segmentURLs.reduce(into: Int64(0)) { partial, url in
            partial += fileSizeBytes(at: url)
        }
        let presetName = selectMergePreset(
            for: composition,
            preference: preference,
            estimatedMergedBytes: estimatedMergedBytes
        )

        guard let exporter = AVAssetExportSession(asset: composition, presetName: presetName) else {
            throw SubStampError.exportFailed(underlying: NSError(domain: "SubStamp", code: -32))
        }
        exporter.shouldOptimizeForNetworkUse = false
        exporter.directoryForTemporaryFiles = FileManager.default.temporaryDirectory

        let outputURL = configureOutput(
            for: exporter,
            prefix: "substamp_merged",
            preferQuickTimeMovie: true
        )

        AppLog.append(
            "[EXPORT] merge session(start) preset=\(presetName) duration=\(String(format: "%.2f", composition.duration.seconds))s estimatedInput=\(ByteCountFormatter.string(fromByteCount: estimatedMergedBytes, countStyle: .file)) fileType=\(exporter.outputFileType?.rawValue ?? "nil") optimize=\(exporter.shouldOptimizeForNetworkUse) freeDisk=\(formattedAvailableDiskSpace()) output=\(outputURL.lastPathComponent)"
        )

        let progressTask = makeProgressTask(exporter: exporter, label: "merge") { progress in
            progressHandler(0.2 + progress * 0.8)
        }

        do {
            try await export(exporter)
            progressTask.cancel()
            progressHandler(1.0)
            AppLog.append("[EXPORT] merge(done) file=\(outputURL.lastPathComponent) size=\(formattedFileSize(at: outputURL))")
            return outputURL
        } catch {
            exporter.cancelExport()
            progressTask.cancel()
            AppLog.append("[EXPORT] merge(failed) \(describe(error: error))")
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
            if presets.contains(AVAssetExportPresetHighestQuality) { return AVAssetExportPresetHighestQuality }
            if presets.contains(AVAssetExportPresetHEVCHighestQuality) { return AVAssetExportPresetHEVCHighestQuality }
        }
        return AVAssetExportPresetHighestQuality
    }

    private func selectMergePreset(
        for asset: AVAsset,
        preference: ExportPreset,
        estimatedMergedBytes: Int64
    ) -> String {
        let presets = AVAssetExportSession.exportPresets(compatibleWith: asset)

        if preference != .best, estimatedMergedBytes >= largeFileRiskThresholdBytes {
            if presets.contains(AVAssetExportPresetHEVCHighestQuality) {
                AppLog.append("[EXPORT] merge preset-adjusted reason=large-estimate estimated=\(ByteCountFormatter.string(fromByteCount: estimatedMergedBytes, countStyle: .file)) chosen=\(AVAssetExportPresetHEVCHighestQuality)")
                return AVAssetExportPresetHEVCHighestQuality
            }
            if presets.contains(AVAssetExportPresetMediumQuality) {
                AppLog.append("[EXPORT] merge preset-adjusted reason=large-estimate estimated=\(ByteCountFormatter.string(fromByteCount: estimatedMergedBytes, countStyle: .file)) chosen=\(AVAssetExportPresetMediumQuality)")
                return AVAssetExportPresetMediumQuality
            }
            if presets.contains(AVAssetExportPreset640x480) {
                AppLog.append("[EXPORT] merge preset-adjusted reason=large-estimate estimated=\(ByteCountFormatter.string(fromByteCount: estimatedMergedBytes, countStyle: .file)) chosen=\(AVAssetExportPreset640x480)")
                return AVAssetExportPreset640x480
            }
        }

        if presets.contains(AVAssetExportPresetPassthrough) {
            return AVAssetExportPresetPassthrough
        }

        return selectPreset(for: asset, preference: preference)
    }

    private func makeProgressTask(
        exporter: AVAssetExportSession,
        label: String,
        progressHandler: @escaping (Double) -> Void
    ) -> Task<Void, Never> {
        Task {
            var lastStatusRaw = -1
            var lastProgressBucket = -1
            while !Task.isCancelled {
                let status = exporter.status
                let progress = Double(exporter.progress)

                if status.rawValue != lastStatusRaw {
                    lastStatusRaw = status.rawValue
                    AppLog.append("[EXPORT] \(label) session(status=\(statusDescription(status))) progress=\(String(format: "%.3f", progress))")
                }

                if status == .exporting || status == .waiting {
                    progressHandler(progress)
                }

                if status == .exporting {
                    let bucket = Int(progress * 10)
                    if bucket > lastProgressBucket {
                        lastProgressBucket = bucket
                        AppLog.append(
                            "[EXPORT] \(label) session(progress=\(bucket * 10)%) rss=\(formattedResidentMemory()) freeDisk=\(formattedAvailableDiskSpace())"
                        )
                    }
                } else if status == .completed || status == .failed || status == .cancelled {
                    break
                }
                try? await Task.sleep(nanoseconds: progressPollIntervalNS)
            }
        }
    }

    private func makeOutputURL(prefix: String, fileExtension: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)_\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
    }

    @discardableResult
    private func configureOutput(
        for exporter: AVAssetExportSession,
        prefix: String,
        preferQuickTimeMovie: Bool
    ) -> URL {
        let selectedType: AVFileType

        if preferQuickTimeMovie, exporter.supportedFileTypes.contains(.mov) {
            selectedType = .mov
        } else if exporter.supportedFileTypes.contains(.mp4) {
            selectedType = .mp4
        } else if exporter.supportedFileTypes.contains(.mov) {
            selectedType = .mov
        } else {
            selectedType = exporter.supportedFileTypes.first ?? .mp4
        }

        let fileExtension = selectedType == .mov ? "mov" : "mp4"
        let outputURL = makeOutputURL(prefix: prefix, fileExtension: fileExtension)
        exporter.outputURL = outputURL
        exporter.outputFileType = selectedType
        return outputURL
    }

    private func formattedAvailableDiskSpace() -> String {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey]
        let available = try? FileManager.default.temporaryDirectory.resourceValues(forKeys: keys)
        let bytes = Int64(available?.volumeAvailableCapacityForImportantUsage ?? 0)
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func formattedResidentMemory() -> String {
        let bytes = currentResidentMemoryBytes()
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }

    private func currentResidentMemoryBytes() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4

        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPointer in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPointer, &count)
            }
        }

        guard result == KERN_SUCCESS else { return 0 }
        return Int64(info.resident_size)
    }

    private func export(_ exporter: AVAssetExportSession) async throws {
        try await withCheckedThrowingContinuation { continuation in
            exporter.exportAsynchronously {
                let status = exporter.status
                let error = exporter.error

                Task { @MainActor in
                    switch status {
                    case .completed:
                        continuation.resume()
                    case .failed:
                        AppLog.append("[EXPORT] session(failed) \(self.describe(error: error))")
                        continuation.resume(throwing: error ?? SubStampError.exportFailed(underlying: NSError(domain: "SubStamp", code: -11)))
                    case .cancelled:
                        AppLog.append("[EXPORT] session(cancelled) \(self.describe(error: error))")
                        continuation.resume(throwing: SubStampError.backgroundTaskCancelled)
                    default:
                        AppLog.append("[EXPORT] session(unexpected-status=\(self.statusDescription(status))) \(self.describe(error: error))")
                        continuation.resume(throwing: SubStampError.exportFailed(underlying: NSError(domain: "SubStamp", code: -12)))
                    }
                }
            }
        }
    }

    private func statusDescription(_ status: AVAssetExportSession.Status) -> String {
        switch status {
        case .unknown: return "unknown"
        case .waiting: return "waiting"
        case .exporting: return "exporting"
        case .completed: return "completed"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        @unknown default: return "other(\(status.rawValue))"
        }
    }

    private func describe(error: Error?) -> String {
        guard let error else { return "error=nil" }
        let nsError = error as NSError
        let underlying = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError).map {
            "\($0.domain)(\($0.code)): \($0.localizedDescription)"
        } ?? "nil"
        let keys = nsError.userInfo.keys.map { String(describing: $0) }.sorted().joined(separator: ",")
        return "domain=\(nsError.domain) code=\(nsError.code) desc=\(nsError.localizedDescription) reason=\(nsError.localizedFailureReason ?? "nil") suggestion=\(nsError.localizedRecoverySuggestion ?? "nil") underlying=\(underlying) userInfoKeys=[\(keys)]"
    }

    private func formattedFileSize(at url: URL) -> String {
        ByteCountFormatter.string(fromByteCount: fileSizeBytes(at: url), countStyle: .file)
    }

    private func fileSizeBytes(at url: URL) -> Int64 {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return Int64(size)
    }

    private func format(size: CGSize) -> String {
        "\(Int(round(size.width)))x\(Int(round(size.height)))"
    }
}
