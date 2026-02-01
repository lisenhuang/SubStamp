import AVFoundation
import Foundation

struct VideoMetadata: Hashable {
    let duration: TimeInterval
    let resolution: CGSize
    let estimatedSize: String
    let hasAudio: Bool

    static func load(from url: URL) async -> VideoMetadata {
        let asset = AVAsset(url: url)
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        let resolution = (try? await videoTracks.first?.load(.naturalSize)) ?? .zero
        let hasAudio = !(asset.tracks(withMediaType: .audio).isEmpty)

        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let formattedSize = ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
        return VideoMetadata(duration: duration, resolution: resolution, estimatedSize: formattedSize, hasAudio: hasAudio)
    }
}
