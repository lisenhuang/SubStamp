import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Step 2: Pick a video and run transcription.
struct VideoTranscribeView: View {
    @ObservedObject var orchestrator: PipelineOrchestrator
    @Binding var selectedVideoURL: URL?
    @Binding var metadata: VideoMetadata?
    @Binding var isTestClip: Bool
    @Binding var activeJob: JobModel?

    let transcriptionLocale: String
    let language1Locale: String
    let subtitle1Mode: TranslationMode?
    let language2Locale: String?
    let subtitle2Mode: TranslationMode?

    var onBack: () -> Void
    var onNext: () -> Void

    @State private var pickerItem: PhotosPickerItem?
    @State private var isLoadingVideo = false
    @State private var isImportingFromFiles = false
    @State private var videoError: String?
    @State private var showBackToSetupConfirmation = false
    @State private var selectedVideoProjectName: String?

    @Environment(\.locale) private var locale

    private let jobStore = JobStore()
    private var isRunningOnMac: Bool { ProcessInfo.processInfo.isiOSAppOnMac }

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(spacing: AppSpacing.l) {
                    backButton

                    WizardHeaderView(
                        step: 2,
                        total: 4,
                        title: "Video & Transcribe",
                        subtitle: "Select a video, then transcribe the audio."
                    )

                    VideoPreviewView(url: selectedVideoURL)
                        .frame(height: 240)

                    videoPicker

                    if isLoadingVideo {
                        ProgressView("Loading video…")
                    }

                    if let metadata {
                        metadataCard(metadata)
                    }

                    if let videoError {
                        Text(videoError)
                            .font(AppTypography.caption)
                            .foregroundStyle(AppColors.error)
                    }

                    transcriptionSection
                    if let end = activeJob?.recoveredAudioEndSeconds {
                        RecoveredAudioNotice(endSeconds: end)
                    }

                    // Next button (shown when returning from Step 3 with transcription already done)
                    if orchestrator.transcriptionComplete && !orchestrator.isRunning {
                        PrimaryButton(title: "Next", systemImage: "arrow.right") {
                            onNext()
                        }
                    }

                    Color.clear.frame(height: 1).id("bottomAnchor")
                }
                .padding(AppSpacing.l)
            }
            .onChange(of: orchestrator.stageStates[.transcribing]) { _, newValue in
                if newValue == .active {
                    withAnimation { scrollProxy.scrollTo("bottomAnchor", anchor: .bottom) }
                }
            }
        }
        .background(AppColors.background)
        .onChange(of: pickerItem) { _, newValue in
            loadVideo(from: newValue)
        }
        .fileImporter(
            isPresented: $isImportingFromFiles,
            allowedContentTypes: [.movie, .mpeg4Movie],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                loadVideo(fromFileURL: url)
            case .failure:
                videoError = String(localized: "Could not load video. Try another clip.", bundle: .forLocale(locale))
            }
        }
        .onChange(of: orchestrator.transcriptionComplete) { _, complete in
            if complete { onNext() }
        }
        .confirmationDialog(
            Text(String(localized: "Start over?", bundle: .forLocale(locale))),
            isPresented: $showBackToSetupConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Start over", bundle: .forLocale(locale)), role: .destructive) {
                orchestrator.cancel()
                onBack()
            }
            Button(String(localized: "Cancel", bundle: .forLocale(locale)), role: .cancel) {}
        } message: {
            Text(String(localized: "All progress will be lost and you'll start fresh.", bundle: .forLocale(locale)))
        }
    }

    // MARK: - Back button

    private var backButton: some View {
        HStack {
            Button {
                showBackToSetupConfirmation = true
            } label: {
                Label("Back", systemImage: "chevron.left")
                    .font(AppTypography.bodyEmphasis)
                    .foregroundStyle(AppColors.secondaryText)
            }
            Spacer()
        }
    }

    // MARK: - Video picker

    @ViewBuilder
    private var videoPicker: some View {
        if isRunningOnMac {
            VStack(spacing: AppSpacing.s) {
                PhotosPicker(selection: $pickerItem, matching: .videos) {
                    HStack(spacing: AppSpacing.s) {
                        Image(systemName: "photo.on.rectangle")
                        Text(String(localized: "Choose from Photos", bundle: .forLocale(locale)))
                            .font(AppTypography.bodyEmphasis)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.m)
                    .foregroundStyle(Color.white)
                    .background(AppColors.accent)
                    .clipShape(RoundedRectangle(cornerRadius: AppSpacing.controlCornerRadius))
                }
                .buttonStyle(.plain)

                Button {
                    isImportingFromFiles = true
                } label: {
                    HStack(spacing: AppSpacing.s) {
                        Image(systemName: "folder")
                        Text(String(localized: "Choose from Files", bundle: .forLocale(locale)))
                            .font(AppTypography.bodyEmphasis)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.m)
                    .foregroundStyle(AppColors.primaryText)
                    .background(AppColors.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: AppSpacing.controlCornerRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppSpacing.controlCornerRadius)
                            .stroke(AppColors.cardBorder, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        } else {
            PhotosPicker(selection: $pickerItem, matching: .videos) {
                HStack(spacing: AppSpacing.s) {
                    Image(systemName: "photo.on.rectangle")
                    Text(String(localized: "Choose video", bundle: .forLocale(locale)))
                        .font(AppTypography.bodyEmphasis)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpacing.m)
                .foregroundStyle(Color.white)
                .background(AppColors.accent)
                .clipShape(RoundedRectangle(cornerRadius: AppSpacing.controlCornerRadius))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Metadata card

    private func metadataCard(_ metadata: VideoMetadata) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            Text("Video details")
                .font(AppTypography.bodyEmphasis)
            HStack {
                Text("Duration"); Spacer()
                Text(TimeFormatting.duration(metadata.duration))
            }
            HStack {
                Text("Resolution"); Spacer()
                Text("\(Int(metadata.resolution.width)) × \(Int(metadata.resolution.height))")
            }
            HStack {
                Text("Estimated size"); Spacer()
                Text(metadata.estimatedSize)
            }
            HStack {
                Text("Audio track"); Spacer()
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

    // MARK: - Transcription section

    @ViewBuilder
    private var transcriptionSection: some View {
        if orchestrator.transcriptionComplete {
            // Transcription done — show checkmark
            HStack(spacing: AppSpacing.s) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppColors.success)
                Text(String(format: String(localized: "Transcription complete (%lld cues)", bundle: .forLocale(locale)), orchestrator.cues.count))
                    .font(AppTypography.bodyEmphasis)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius)
                    .stroke(AppColors.cardBorder, lineWidth: 1)
            )
        } else if orchestrator.isRunning {
            // Transcription in progress
            VStack(spacing: AppSpacing.l) {
                PipelineStageRow(
                    title: "Transcribing",
                    state: orchestrator.stageStates[.transcribing] ?? .pending,
                    progress: orchestrator.stageProgress[.transcribing] ?? 0,
                    detail: "Generating time-coded subtitles."
                )

                VStack(alignment: .leading, spacing: AppSpacing.s) {
                    Text("Tips").font(AppTypography.bodyEmphasis)
                    Text("iOS may stop work in the background. The screen stays awake automatically during transcription.")
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.secondaryText)
                }
                .padding()
                .background(AppColors.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius)
                        .stroke(AppColors.cardBorder, lineWidth: 1)
                )
            }
        } else if let error = orchestrator.error {
            // Error state — show retry
            VStack(alignment: .leading, spacing: AppSpacing.s) {
                Text(LocalizedStringKey(error.errorDescription ?? "Transcription failed"))
                    .font(AppTypography.bodyEmphasis)
                    .foregroundStyle(AppColors.error)
                if let suggestion = error.recoverySuggestion {
                    Text(suggestion)
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.secondaryText)
                }
                PrimaryButton(title: "Retry", systemImage: "arrow.clockwise") {
                    startTranscription()
                }
            }
        } else {
            // Not started — show transcribe button
            PrimaryButton(
                title: "Transcribe",
                systemImage: "captions.bubble",
                isEnabled: selectedVideoURL != nil && (metadata?.hasAudio ?? false)
            ) {
                startTranscription()
            }
        }
    }

    // MARK: - Actions

    private func loadVideo(from item: PhotosPickerItem?) {
        guard let item else { return }
        isLoadingVideo = true
        videoError = nil
        // Reset transcription state when new video is picked
        orchestrator.cancel()
        orchestrator.resetStages()
        activeJob = nil
        Task { @MainActor in
            do {
                guard let imported = try await item.loadTransferable(type: ImportedVideo.self) else {
                    videoError = String(localized: "Could not load video. Try another clip.", bundle: .forLocale(locale))
                    isLoadingVideo = false
                    return
                }
                selectedVideoURL = imported.url
                selectedVideoProjectName = imported.projectName
                metadata = await VideoMetadata.load(from: imported.url)
            } catch {
                videoError = String(localized: "Could not load video. Try another clip.", bundle: .forLocale(locale))
            }
            isLoadingVideo = false
        }
    }

    private func loadVideo(fromFileURL url: URL) {
        isLoadingVideo = true
        videoError = nil
        orchestrator.cancel()
        orchestrator.resetStages()
        activeJob = nil

        Task { @MainActor in
            do {
                let imported = try ImportedVideo.importFromFileURL(url)
                selectedVideoURL = imported.url
                selectedVideoProjectName = imported.projectName
                metadata = await VideoMetadata.load(from: imported.url)
            } catch {
                videoError = String(localized: "Could not load video. Try another clip.", bundle: .forLocale(locale))
            }
            isLoadingVideo = false
        }
    }

    private func startTranscription() {
        guard let selectedVideoURL else { return }
        let savedStyle = SetupPreferences.loadSubtitleStyle()
        let job: JobModel = {
            if var existing = activeJob {
                existing.videoURL = selectedVideoURL
                if let projectName = selectedVideoProjectName?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !projectName.isEmpty,
                   (existing.projectName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
                    existing.projectName = projectName
                }
                existing.transcriptionLocale = transcriptionLocale
                existing.language1Locale = language1Locale
                existing.subtitle1Mode = subtitle1Mode
                existing.subtitleMode = language2Locale == nil ? .single : .bilingual
                existing.translationTargetLocale = language2Locale
                existing.subtitle2Mode = subtitle2Mode
                existing.subtitleLayout = language2Locale == nil ? .single : .stacked
                existing.subtitleStyle = savedStyle
                existing.exportPreset = .balanced
                existing.stage = .idle
                existing.shouldOfferResume = true
                existing.outputURL = nil
                existing.isTestClip = isTestClip
                existing.updatedAt = Date()
                return existing
            }

            return JobModel(
                projectName: selectedVideoProjectName,
                videoURL: selectedVideoURL,
                transcriptionLocale: transcriptionLocale,
                language1Locale: language1Locale,
                subtitle1Mode: subtitle1Mode,
                subtitleMode: language2Locale == nil ? .single : .bilingual,
                translationTargetLocale: language2Locale,
                subtitle2Mode: subtitle2Mode,
                subtitleLayout: language2Locale == nil ? .single : .stacked,
                subtitleStyle: savedStyle,
                exportPreset: .balanced,
                shouldOfferResume: true,
                isTestClip: isTestClip
            )
        }()
        activeJob = job
        jobStore.deleteCues(id: job.id, type: .transcribed)
        jobStore.deleteCues(id: job.id, type: .translated)
        try? jobStore.save(job: job)
        orchestrator.startTranscription(job: job)
    }
}

// MARK: - ImportedVideo Transferable

/// Used to load a video from PhotosPickerItem; `URL.self` does not work for library videos.
struct ImportedVideo: Transferable {
    let url: URL
    let projectName: String
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            try copyReceivedVideo(received)
        }
        FileRepresentation(importedContentType: .mpeg4Movie) { received in
            try copyReceivedVideo(received)
        }
    }

    private static func copyReceivedVideo(_ received: ReceivedTransferredFile) throws -> Self {
        try copyVideo(at: received.file)
    }

    static func importFromFileURL(_ sourceURL: URL) throws -> Self {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        return try copyVideo(at: sourceURL)
    }

    private static func copyVideo(at sourceURL: URL) throws -> Self {
        let destDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SubStamp/uploads", isDirectory: true)
        if !FileManager.default.fileExists(atPath: destDir.path) {
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        }
        let ext = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
        let dest = destDir
            .appendingPathComponent("video_\(UUID().uuidString)")
            .appendingPathExtension(ext)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: sourceURL, to: dest)
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let projectName = baseName.isEmpty ? sourceURL.lastPathComponent : baseName
        return Self(url: dest, projectName: projectName)
    }
}
