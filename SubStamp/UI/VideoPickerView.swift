import PhotosUI
import SwiftUI

struct VideoPickerView: View {
    @Binding var selectedVideoURL: URL?
    @Binding var metadata: VideoMetadata?
    @Binding var isTestClip: Bool
    var onGenerate: () -> Void

    @State private var pickerItem: PhotosPickerItem?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(spacing: AppSpacing.l) {
                WizardHeaderView(
                    step: 2,
                    total: 4,
                    title: "Pick a video",
                    subtitle: "Choose a clip and confirm it has audio."
                )

                VideoPreviewView(url: selectedVideoURL)
                    .frame(height: 240)

                PhotosPicker(selection: $pickerItem, matching: .videos) {
                    HStack(spacing: AppSpacing.s) {
                        Image(systemName: "photo.on.rectangle")
                        Text("Choose video")
                            .font(AppTypography.bodyEmphasis)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.m)
                    .foregroundStyle(Color.white)
                    .background(AppColors.accent)
                    .clipShape(RoundedRectangle(cornerRadius: AppSpacing.controlCornerRadius))
                }
                .buttonStyle(.plain)

                if isLoading {
                    ProgressView("Loading video…")
                }

                if let metadata {
                    VStack(alignment: .leading, spacing: AppSpacing.s) {
                        Text("Video details")
                            .font(AppTypography.bodyEmphasis)
                        HStack {
                            Text("Duration")
                            Spacer()
                            Text(TimeFormatting.duration(metadata.duration))
                        }
                        HStack {
                            Text("Resolution")
                            Spacer()
                            Text("\(Int(metadata.resolution.width)) × \(Int(metadata.resolution.height))")
                        }
                        HStack {
                            Text("Estimated size")
                            Spacer()
                            Text(metadata.estimatedSize)
                        }
                        HStack {
                            Text("Audio track")
                            Spacer()
                            Text(metadata.hasAudio ? "Yes" : "No")
                                .foregroundStyle(metadata.hasAudio ? AppColors.success : AppColors.warning)
                        }
                        if metadata.duration > 300 {
                            Text("Long video detected. Consider running a 1-minute test first.")
                                .font(AppTypography.caption)
                                .foregroundStyle(AppColors.warning)
                        }
                        Toggle("Test on first 1 minute", isOn: $isTestClip)
                            .font(AppTypography.caption)
                    }
                    .font(AppTypography.body)
                    .padding()
                    .background(AppColors.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius)
                            .stroke(AppColors.cardBorder, lineWidth: 1)
                    )
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.error)
                }

                PrimaryButton(
                    title: "Generate subtitles",
                    systemImage: "captions.bubble",
                    isEnabled: selectedVideoURL != nil && (metadata?.hasAudio ?? false)
                ) {
                    onGenerate()
                }
            }
            .padding(AppSpacing.l)
        }
        .background(AppColors.background)
        .onChange(of: pickerItem) { _, newValue in
            guard let newValue else { return }
            isLoading = true
            errorMessage = nil
            Task {
                do {
                    let url = try await newValue.loadTransferable(type: URL.self)
                    guard let url else { throw SubStampError.exportFailed(underlying: NSError(domain: "SubStamp", code: -30)) }
                    let localURL = try copyToLocal(url: url)
                    selectedVideoURL = localURL
                    metadata = await VideoMetadata.load(from: localURL)
                } catch {
                    errorMessage = error.localizedDescription
                }
                isLoading = false
            }
        }
    }

    private func copyToLocal(url: URL) throws -> URL {
        let destinationDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SubStamp/uploads", isDirectory: true)
        if !FileManager.default.fileExists(atPath: destinationDirectory.path) {
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        }
        let destinationURL = destinationDirectory
            .appendingPathComponent("video_\(UUID().uuidString)")
            .appendingPathExtension(url.pathExtension.isEmpty ? "mov" : url.pathExtension)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: url, to: destinationURL)
        return destinationURL
    }
}
