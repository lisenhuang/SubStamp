import SwiftUI
import Translation

struct ContentView: View {
    enum WizardStep {
        case setup
        case pickVideo
        case processing
        case review
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
    @State private var translationProvider: TranslationProvider = .translationFramework
    @State private var fixTranscriptionWithAppleIntelligence = false
    @State private var isTestClip = false

    @State private var selectedVideoURL: URL?
    @State private var metadata: VideoMetadata?
    @State private var activeJob: JobModel?
    @State private var outputURL: URL?

    @State private var resumeJob: JobModel?
    @State private var showResumeAlert = false
    @State private var resumeTranscribed: [SubtitleCue]?
    @State private var resumeTranslated: [SubtitleCue]?

    private let jobStore = JobStore()

    @Environment(\.locale) private var locale

    private var subtitleMode: SubtitleMode {
        if let lang2 = language2Locale, lang2 != language1Locale {
            return .bilingual
        }
        return .single
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
                    translationProvider: $translationProvider,
                    fixTranscriptionWithAppleIntelligence: $fixTranscriptionWithAppleIntelligence,
                    onContinue: {
                        saveSetupSelections()
                        step = .pickVideo
                    }
                )
            case .pickVideo:
                VideoPickerView(
                    selectedVideoURL: $selectedVideoURL,
                    metadata: $metadata,
                    isTestClip: $isTestClip,
                    onBack: { step = .setup }
                ) {
                    createJobAndStart()
                }
            case .processing:
                if let job = activeJob {
                    ProcessingView(
                        orchestrator: orchestrator,
                        job: job,
                        resumeTranscribed: resumeTranscribed,
                        resumeTranslated: resumeTranslated,
                        onBack: {
                            step = .pickVideo
                        },
                        onChangeSettings: { resetToSetup() },
                        onCompleted: { url in
                            outputURL = url
                            step = .result
                        },
                        onReview: {
                            step = .review
                        }
                    )
                }
            case .review:
                if activeJob != nil, let videoURL = selectedVideoURL {
                    let styleBinding = Binding<SubtitleStyle>(
                        get: { activeJob?.subtitleStyle ?? SubtitleStyle() },
                        set: { newValue in
                            guard var updated = activeJob else { return }
                            updated.subtitleStyle = newValue
                            activeJob = updated
                            orchestrator.job = updated
                            try? jobStore.save(job: updated)
                            SetupPreferences.saveSubtitleStyle(newValue)
                        }
                    )
                    SubtitleReviewView(
                        cues: $orchestrator.cues,
                        style: styleBinding,
                        videoURL: videoURL,
                        mode: subtitleMode,
                        onContinue: {
                            orchestrator.continueAfterReview()
                            step = .processing
                        },
                        onBack: {
                            step = .processing
                        },
                        onAbandon: {
                            resetToSetup()
                        }
                    )
                }
            case .result:
                if let outputURL, let job = activeJob {
                    ResultView(outputURL: outputURL, exportPreset: job.exportPreset) {
                        resetToSetup()
                    }
                }
            }
        }
        .onChange(of: orchestrator.readyForReview) { _, ready in
            if ready { step = .review }
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
        .task {
            loadSetupSelections()
            let jobs = jobStore.loadAllJobs().filter { $0.stage != .completed }
            if let job = jobs.first {
                resumeJob = job
                showResumeAlert = true
            }
        }
    }

    private func loadSetupSelections() {
        transcriptionLocaleIdentifier = SetupPreferences.loadTranscriptionLocale() ?? Self.sanitizedCurrentLocaleIdentifier()
        language1Locale = SetupPreferences.loadLanguage1() ?? transcriptionLocaleIdentifier
        language2Locale = SetupPreferences.loadLanguage2()
        translationProvider = SetupPreferences.loadTranslationProvider() ?? .translationFramework
        fixTranscriptionWithAppleIntelligence = SetupPreferences.loadFixTranscriptionWithAppleIntelligence()
        if translationProvider != .appleIntelligence {
            fixTranscriptionWithAppleIntelligence = false
        }
    }

    private func saveSetupSelections() {
        SetupPreferences.save(
            transcriptionLocale: transcriptionLocaleIdentifier,
            subtitleMode: subtitleMode,
            translationTarget: language2Locale,
            translationProvider: translationProvider,
            fixTranscriptionWithAppleIntelligence: fixTranscriptionWithAppleIntelligence
        )
        SetupPreferences.saveLanguages(language1: language1Locale, language2: language2Locale)
    }

    private func createJobAndStart() {
        guard let selectedVideoURL else { return }
        let savedStyle = SetupPreferences.loadSubtitleStyle()
        let job = JobModel(
            videoURL: selectedVideoURL,
            transcriptionLocale: transcriptionLocaleIdentifier,
            language1Locale: language1Locale,
            subtitle1Mode: subtitle1Mode,
            subtitleMode: language2Locale == nil ? .single : .bilingual,
            translationTargetLocale: language2Locale,
            subtitle2Mode: subtitle2Mode,
            subtitleLayout: (language2Locale == nil) ? .single : .stacked,
            subtitleStyle: savedStyle,
            exportPreset: .balanced,
            translationProvider: translationProvider,
            fixTranscriptionWithAppleIntelligence: fixTranscriptionWithAppleIntelligence,
            isTestClip: isTestClip
        )
        activeJob = job
        resumeTranscribed = nil
        resumeTranslated = nil
        try? jobStore.save(job: job)
        step = .processing
    }

    private func resetToSetup() {
        orchestrator.cancel()
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
        activeJob = job
        selectedVideoURL = job.videoURL
        transcriptionLocaleIdentifier = job.transcriptionLocale
        language1Locale = job.language1Locale
        subtitle1Mode = job.subtitle1Mode
        language2Locale = job.translationTargetLocale
        subtitle2Mode = job.subtitle2Mode
        translationProvider = job.translationProvider
        fixTranscriptionWithAppleIntelligence = job.fixTranscriptionWithAppleIntelligence

        resumeTranscribed = jobStore.loadCues(id: job.id, type: .transcribed) ?? []
        resumeTranslated = jobStore.loadCues(id: job.id, type: .translated)
        step = .processing
    }
}
