//
//  ContentView.swift
//  SubStamp
//
//  Created by Eason Smith on 2/1/26.
//

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

    @State private var transcriptionLocaleIdentifier: String = Locale.current.identifier
    @State private var language1Identifier: String = Locale.current.identifier
    @State private var language2Identifier: String?
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
    
    /// Derived subtitle mode based on whether language2 is selected
    private var subtitleMode: SubtitleMode {
        language2Identifier != nil ? .bilingual : .single
    }

    var body: some View {
        ZStack {
            AppColors.background.ignoresSafeArea()
            switch step {
            case .setup:
                SetupView(
                    assetManager: assetManager,
                    transcriptionLocaleIdentifier: $transcriptionLocaleIdentifier,
                    language1Identifier: $language1Identifier,
                    language2Identifier: $language2Identifier
                ) {
                    saveSetupSelections()
                    step = .pickVideo
                }
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
                            orchestrator.cancel()
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
                        translationTarget: translationTargetLocale,
                        sourceLocaleIdentifier: language1Identifier,
                        onContinue: {
                            orchestrator.continueAfterReview()
                            step = .processing
                        },
                        onBack: {
                            step = .processing
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
            if ready {
                step = .review
            }
        }
        .alert("Resume unfinished job?", isPresented: $showResumeAlert) {
            Button("Resume") {
                resumeIncompleteJob()
            }
            Button("Discard", role: .destructive) {
                if let job = resumeJob {
                    jobStore.deleteJob(id: job.id)
                }
                resumeJob = nil
            }
        } message: {
            Text("We found a previous job that didn't finish. Would you like to resume?")
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

    private var transcriptionLocale: Locale { Locale(identifier: transcriptionLocaleIdentifier) }
    private var translationTargetLocale: Locale.Language? {
        language2Identifier.map { Locale.Language(identifier: $0) }
    }

    private func loadSetupSelections() {
        transcriptionLocaleIdentifier = SetupPreferences.loadTranscriptionLocale() ?? Locale.current.identifier
        language1Identifier = SetupPreferences.loadLanguage1() ?? transcriptionLocaleIdentifier
        language2Identifier = SetupPreferences.loadLanguage2()
    }

    private func saveSetupSelections() {
        SetupPreferences.save(
            transcriptionLocale: transcriptionLocaleIdentifier,
            subtitleMode: subtitleMode,
            translationTarget: language2Identifier
        )
        SetupPreferences.saveLanguages(language1: language1Identifier, language2: language2Identifier)
    }

    private func createJobAndStart() {
        guard let selectedVideoURL else { return }
        let savedStyle = SetupPreferences.loadSubtitleStyle()
        let job = JobModel(
            videoURL: selectedVideoURL,
            transcriptionLocale: transcriptionLocaleIdentifier,
            language1Locale: language1Identifier,
            subtitleMode: subtitleMode,
            translationTargetLocale: language2Identifier,
            subtitleLayout: subtitleMode == .bilingual ? .stacked : .single,
            subtitleStyle: savedStyle,
            exportPreset: .balanced,
            isTestClip: isTestClip
        )
        activeJob = job
        resumeTranscribed = nil
        resumeTranslated = nil
        do {
            try jobStore.save(job: job)
        } catch {
            // ignore save failure for now
        }
        step = .processing
    }

    private func resetToSetup() {
        step = .setup
        selectedVideoURL = nil
        metadata = nil
        outputURL = nil
        activeJob = nil
        orchestrator.resetStages()
        isTestClip = false
    }

    private func resumeIncompleteJob() {
        guard let job = resumeJob else { return }
        activeJob = job
        selectedVideoURL = job.videoURL
        transcriptionLocaleIdentifier = job.transcriptionLocale
        language1Identifier = job.language1Locale
        language2Identifier = job.translationTargetLocale

        resumeTranscribed = jobStore.loadCues(id: job.id, type: .transcribed) ?? []
        resumeTranslated = jobStore.loadCues(id: job.id, type: .translated)
        step = .processing
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
