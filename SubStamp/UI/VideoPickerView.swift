import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Used to load a video from PhotosPickerItem; `URL.self` does not work for library videos.
private struct ImportedVideo: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            try copyReceivedVideo(received)
        }
        FileRepresentation(importedContentType: .mpeg4Movie) { received in
            try copyReceivedVideo(received)
        }
    }

    private static func copyReceivedVideo(_ received: ReceivedTransferredFile) throws -> Self {
        let destDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SubStamp/uploads", isDirectory: true)
        if !FileManager.default.fileExists(atPath: destDir.path) {
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        }
        let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
        let dest = destDir
            .appendingPathComponent("video_\(UUID().uuidString)")
            .appendingPathExtension(ext)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: received.file, to: dest)
        return Self(url: dest)
    }
}

struct VideoPickerView: View {
    @Binding var selectedVideoURL: URL?
    @Binding var metadata: VideoMetadata?
    @Binding var isTestClip: Bool
    var onBack: () -> Void
    var onGenerate: () -> Void

    @State private var pickerItem: PhotosPickerItem?
    @State private var isLoading = false
    @State private var errorMessage: String?

    @Environment(\.locale) private var locale

    var body: some View {
        ScrollView {
            VStack(spacing: AppSpacing.l) {
                HStack {
                    Button {
                        onBack()
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                            .font(AppTypography.bodyEmphasis)
                            .foregroundStyle(AppColors.secondaryText)
                    }
                    Spacer()
                }

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
                        if metadata.duration > 60 {
                            Toggle("Test on first 1 minute", isOn: $isTestClip)
                                .font(AppTypography.caption)
                        }
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
            Task { @MainActor in
                do {
                    guard let imported = try await newValue.loadTransferable(type: ImportedVideo.self) else {
                        errorMessage = String(localized: "Could not load video. Try another clip.", locale: locale)
                        isLoading = false
                        return
                    }
                    selectedVideoURL = imported.url
                    metadata = await VideoMetadata.load(from: imported.url)
                } catch {
                    errorMessage = String(localized: "Could not load video. Try another clip.", locale: locale)
                }
                isLoading = false
            }
        }
    }
}
