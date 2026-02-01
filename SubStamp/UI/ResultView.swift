import Photos
import SwiftUI

struct ResultView: View {
    let outputURL: URL
    let exportPreset: ExportPreset
    var onStartOver: () -> Void

    @State private var metadata: VideoMetadata?
    @State private var saveStatus: String?
    @State private var isSaving = false

    var body: some View {
        ScrollView {
            VStack(spacing: AppSpacing.l) {
                WizardHeaderView(
                    step: 4,
                    total: 4,
                    title: "Result",
                    subtitle: "Your subtitled video is ready."
                )

                VideoPreviewView(url: outputURL)
                    .frame(height: 240)

                if let metadata {
                    VStack(alignment: .leading, spacing: AppSpacing.s) {
                        Text("Export details")
                            .font(AppTypography.bodyEmphasis)
                        HStack {
                            Text("Preset")
                            Spacer()
                            Text(exportPreset.rawValue.capitalized)
                        }
                        HStack {
                            Text("Resolution")
                            Spacer()
                            Text("\(Int(metadata.resolution.width)) × \(Int(metadata.resolution.height))")
                        }
                        HStack {
                            Text("Duration")
                            Spacer()
                            Text(TimeFormatting.duration(metadata.duration))
                        }
                        HStack {
                            Text("Estimated size")
                            Spacer()
                            Text(metadata.estimatedSize)
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

                if let saveStatus {
                    Text(saveStatus)
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.secondaryText)
                }

                PrimaryButton(
                    title: isSaving ? "Saving..." : "Save to Photos",
                    systemImage: "square.and.arrow.down",
                    isEnabled: !isSaving
                ) {
                    saveToPhotos()
                }

                ShareLink(item: outputURL) {
                    HStack(spacing: AppSpacing.s) {
                        Image(systemName: "square.and.arrow.up")
                        Text("Share")
                            .font(AppTypography.bodyEmphasis)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.m)
                    .foregroundStyle(Color.white)
                    .background(AppColors.accent)
                    .clipShape(RoundedRectangle(cornerRadius: AppSpacing.controlCornerRadius))
                }

                PrimaryButton(title: "Start another", systemImage: "arrow.counterclockwise") {
                    onStartOver()
                }
            }
            .padding(AppSpacing.l)
        }
        .background(AppColors.background)
        .task {
            metadata = await VideoMetadata.load(from: outputURL)
        }
    }

    private func saveToPhotos() {
        print("[SAVE] saveToPhotos() called")
        print("[SAVE] outputURL: \(outputURL)")
        print("[SAVE] File exists: \(FileManager.default.fileExists(atPath: outputURL.path))")
        
        isSaving = true
        saveStatus = "Saving to Photos..."
        
        // Use a plain Task (not @MainActor) to avoid the Swift 6 libdispatch crash
        Task.detached { [outputURL] in
            print("[SAVE] Detached task started")
            
            do {
                try await PhotoSaver.saveVideoToPhotos(fileURL: outputURL)
                print("[SAVE] Save completed successfully")
                
                await MainActor.run {
                    self.isSaving = false
                    self.saveStatus = "Saved to Photos!"
                }
            } catch {
                print("[SAVE] Save failed: \(error)")
                
                await MainActor.run {
                    self.isSaving = false
                    self.saveStatus = "Failed: \(error.localizedDescription)"
                }
            }
        }
    }
}

/// Non-actor helper to avoid Swift 6 MainActor + PHPhotoLibrary crash
enum PhotoSaver {
    static func saveVideoToPhotos(fileURL: URL) async throws {
        print("[PhotoSaver] Starting save for: \(fileURL.lastPathComponent)")
        
        // Request authorization
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        print("[PhotoSaver] Authorization status: \(status.rawValue)")
        
        guard status == .authorized || status == .limited else {
            throw NSError(
                domain: "PhotoSaver",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Photo library access not authorized"]
            )
        }
        
        // Check file exists
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw NSError(
                domain: "PhotoSaver",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Video file not found"]
            )
        }
        
        print("[PhotoSaver] Calling performChanges...")
        
        // Perform the save
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = false
            request.addResource(with: .video, fileURL: fileURL, options: options)
            print("[PhotoSaver] Asset creation request added")
        }
        
        print("[PhotoSaver] performChanges completed")
    }
}
