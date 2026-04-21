import SwiftUI
import Translation
import UIKit

struct ContentView: View {
    enum WizardStep {
        case setup
        case videoAndTranscribe
        case previewAndExport
        case result
    }

    @State private var step: WizardStep = .setup
    @StateObject private var assetManager = AssetReadinessManager()
    @StateObject private var orchestrator = PipelineOrchestrator()

    @State private var transcriptionLocaleIdentifier: String = Self.sanitizedCurrentLocaleIdentifier()
    @State private var language1Locale: String = Self.sanitizedCurrentLocaleIdentifier()
    @State private var subtitle1Mode: TranslationMode? = nil
    @State private var language2Locale: String?
    @State private var subtitle2Mode: TranslationMode?
    @State private var isTestClip = false

    @State private var selectedVideoURL: URL?
    @State private var metadata: VideoMetadata?
    @State private var activeJob: JobModel?
    @State private var outputURL: URL?

    @State private var resumeJob: JobModel?
    @State private var showResumeAlert = false
    @State private var showProjectsSheet = false
    @State private var previewOpenedFromProjects = false

    private let jobStore = JobStore()

    @Environment(\.locale) private var locale

    private var shouldKeepScreenAwake: Bool {
        guard orchestrator.isRunning else { return false }
        switch orchestrator.currentStage {
        case .transcribing, .translating, .rendering, .exporting:
            return true
        default:
            return false
        }
    }

    var body: some View {
        ZStack {
            AppColors.background.ignoresSafeArea()
            switch step {
            case .setup:
                SetupView(
                    assetManager: assetManager,
                    transcriptionLocaleIdentifier: $transcriptionLocaleIdentifier,
                    language1Identifier: $language1Locale,
                    language2Identifier: $language2Locale,
                    subtitle1Mode: $subtitle1Mode,
                    subtitle2Mode: $subtitle2Mode,
                    onOpenProjects: { showProjectsSheet = true },
                    onContinue: {
                        previewOpenedFromProjects = false
                        saveSetupSelections()
                        step = .videoAndTranscribe
                    }
                )
            case .videoAndTranscribe:
                VideoTranscribeView(
                    orchestrator: orchestrator,
                    selectedVideoURL: $selectedVideoURL,
                    metadata: $metadata,
                    isTestClip: $isTestClip,
                    activeJob: $activeJob,
                    transcriptionLocale: transcriptionLocaleIdentifier,
                    language1Locale: language1Locale,
                    subtitle1Mode: subtitle1Mode,
                    language2Locale: language2Locale,
                    subtitle2Mode: subtitle2Mode,
                    onBack: { resetToSetup() },
                    onNext: { step = .previewAndExport }
                )
            case .previewAndExport:
                if let videoURL = selectedVideoURL {
                    PreviewExportView(
                        orchestrator: orchestrator,
                        activeJob: $activeJob,
                        videoURL: videoURL,
                        onBack: {
                            if previewOpenedFromProjects {
                                returnToProjects()
                            } else {
                                step = .videoAndTranscribe
                            }
                        },
                        onExportComplete: { url in
                            outputURL = url
                            step = .result
                        }
                    )
                }
            case .result:
                if let outputURL, let job = activeJob {
                    ResultView(
                        outputURL: outputURL,
                        sourceVideoURL: job.videoURL,
                        exportPreset: job.exportPreset,
                        onBackToEdit: { step = .previewAndExport },
                        onStartOver: { resetToSetup() }
                    )
                }
            }
        }
        .alert(Text(String(localized: "Resume unfinished job?", bundle: .forLocale(locale))), isPresented: $showResumeAlert) {
            Button(String(localized: "Resume", bundle: .forLocale(locale))) { resumeIncompleteJob() }
            Button(String(localized: "Discard", bundle: .forLocale(locale)), role: .destructive) {
                if let job = resumeJob { jobStore.deleteJob(id: job.id) }
                resumeJob = nil
            }
            Button(String(localized: "Cancel", bundle: .forLocale(locale)), role: .cancel) { }
        } message: {
            Text(String(localized: "We found a previous job that didn't finish. Would you like to resume?", bundle: .forLocale(locale)))
        }
        .sheet(isPresented: $showProjectsSheet) {
            ProjectListView { job in
                openProject(job, openedFromProjects: true)
            }
        }
        .task {
            loadSetupSelections()
            let jobs = jobStore.loadAllJobs().filter { $0.stage != .completed && $0.shouldOfferResume }
            if let job = jobs.first {
                resumeJob = job
                showResumeAlert = true
            }
        }
        .onChange(of: orchestrator.isRunning) { _, _ in
            updateIdleTimerPolicy()
        }
        .onChange(of: orchestrator.currentStage) { _, _ in
            updateIdleTimerPolicy()
        }
        .onAppear {
            updateIdleTimerPolicy()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private func loadSetupSelections() {
        transcriptionLocaleIdentifier = SetupPreferences.loadTranscriptionLocale() ?? Self.sanitizedCurrentLocaleIdentifier()
        language1Locale = SetupPreferences.loadLanguage1() ?? transcriptionLocaleIdentifier
        language2Locale = SetupPreferences.loadLanguage2()
    }

    private func saveSetupSelections() {
        SetupPreferences.save(
            transcriptionLocale: transcriptionLocaleIdentifier,
            subtitleMode: language2Locale == nil ? .single : .bilingual,
            translationTarget: language2Locale
        )
        SetupPreferences.saveLanguages(language1: language1Locale, language2: language2Locale)
    }

    private func resetToSetup() {
        orchestrator.cancel()
        previewOpenedFromProjects = false
        step = .setup
        selectedVideoURL = nil
        metadata = nil
        outputURL = nil
        activeJob = nil
        orchestrator.resetStages()
        isTestClip = false
    }

    /// Strips region-override suffixes (e.g. "en_US@rg=nzzzzz" → "en_US") so the
    /// identifier matches SpeechTranscriber locale identifiers used as Picker tags.
    private static func sanitizedCurrentLocaleIdentifier() -> String {
        let raw = Locale.current.identifier
        // Remove everything after "@" which contains region overrides
        return raw.components(separatedBy: "@").first ?? raw
    }

    private func resumeIncompleteJob() {
        guard let job = resumeJob else { return }
        openProject(job, openedFromProjects: false)
    }

    private func openProject(_ job: JobModel, openedFromProjects: Bool) {
        let existingOutputURL = job.outputURL.flatMap { url in
            FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        previewOpenedFromProjects = openedFromProjects
        showResumeAlert = false
        resumeJob = nil
        activeJob = job
        selectedVideoURL = job.videoURL
        transcriptionLocaleIdentifier = job.transcriptionLocale
        language1Locale = job.language1Locale
        subtitle1Mode = job.subtitle1Mode
        language2Locale = job.translationTargetLocale
        subtitle2Mode = job.subtitle2Mode
        outputURL = existingOutputURL
        orchestrator.cancel()
        orchestrator.resetStages()
        orchestrator.job = job
        orchestrator.outputURL = existingOutputURL
        metadata = nil

        Task { @MainActor in
            metadata = await VideoMetadata.load(from: job.videoURL)
        }

        if let saved = jobStore.loadBestSavedProjectCues(id: job.id) {
            orchestrator.cues = saved.cues
            orchestrator.transcriptionComplete = true
            orchestrator.translationComplete = (saved.type == .translated)
            step = .previewAndExport
        } else {
            step = .videoAndTranscribe
        }
    }

    private func returnToProjects() {
        previewOpenedFromProjects = false
        step = .setup
        showProjectsSheet = true
    }

    private func updateIdleTimerPolicy() {
        UIApplication.shared.isIdleTimerDisabled = shouldKeepScreenAwake
    }
}
