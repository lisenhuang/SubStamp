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
        isSaving = true
        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: outputURL)
        } completionHandler: { success, error in
            DispatchQueue.main.async {
                isSaving = false
                if success {
                    saveStatus = "Saved to Photos."
                } else {
                    saveStatus = error?.localizedDescription ?? "Unable to save."
                }
            }
        }
    }
}
