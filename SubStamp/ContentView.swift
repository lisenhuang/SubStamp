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
        case result
    }

    @State private var step: WizardStep = .setup
    @State private var assetManager = AssetReadinessManager()
    @State private var orchestrator = PipelineOrchestrator()

    @State private var transcriptionLocale: Locale = .current
    @State private var subtitleMode: SubtitleMode = .single
    @State private var translationTarget: Locale.Language?
    @State private var isTestClip = false

    @State private var selectedVideoURL: URL?
    @State private var metadata: VideoMetadata?
    @State private var activeJob: JobModel?
    @State private var outputURL: URL?
    @State private var showReview = false

    @State private var resumeJob: JobModel?
    @State private var showResumeAlert = false
    @State private var resumeTranscribed: [SubtitleCue]?
    @State private var resumeTranslated: [SubtitleCue]?

    private let jobStore = JobStore()

    var body: some View {
        ZStack {
            AppColors.background.ignoresSafeArea()
            switch step {
            case .setup:
                SetupView(
                    assetManager: assetManager,
                    transcriptionLocale: $transcriptionLocale,
                    subtitleMode: $subtitleMode,
                    translationTarget: $translationTarget
                ) {
                    step = .pickVideo
                }
            case .pickVideo:
                VideoPickerView(
                    selectedVideoURL: $selectedVideoURL,
                    metadata: $metadata,
                    isTestClip: $isTestClip
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
                        onChangeSettings: { resetToSetup() },
                        onCompleted: { url in
                            outputURL = url
                            step = .result
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
        .sheet(isPresented: $showReview) {
            if let job = activeJob, let videoURL = selectedVideoURL {
                let styleBinding = Binding<SubtitleStyle>(
                    get: { activeJob?.subtitleStyle ?? SubtitleStyle() },
                    set: { newValue in
                        guard var updated = activeJob else { return }
                        updated.subtitleStyle = newValue
                        activeJob = updated
                        orchestrator.job = updated
                        try? jobStore.save(job: updated)
                    }
                )
                SubtitleReviewView(
                    cues: $orchestrator.cues,
                    style: styleBinding,
                    videoURL: videoURL,
                    translationTarget: translationTarget,
                    sourceLocaleIdentifier: transcriptionLocale.identifier,
                    onContinue: {
                        showReview = false
                        orchestrator.continueAfterReview()
                    },
                    onDismiss: {
                        showReview = false
                    }
                )
            }
        }
        .onChange(of: orchestrator.readyForReview) { _, ready in
            if ready {
                showReview = true
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
            let jobs = jobStore.loadAllJobs().filter { $0.stage != .completed }
            if let job = jobs.first {
                resumeJob = job
                showResumeAlert = true
            }
        }
    }

    private func createJobAndStart() {
        guard let selectedVideoURL else { return }
        let job = JobModel(
            videoURL: selectedVideoURL,
            transcriptionLocale: transcriptionLocale.identifier,
            subtitleMode: subtitleMode,
            translationTargetLocale: translationTarget?.identifier,
            subtitleLayout: subtitleMode == .bilingual ? .stacked : .single,
            subtitleStyle: SubtitleStyle(),
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
        transcriptionLocale = Locale(identifier: job.transcriptionLocale)
        subtitleMode = job.subtitleMode
        translationTarget = job.translationTargetLocale.map { Locale.Language(identifier: $0) }

        resumeTranscribed = jobStore.loadCues(id: job.id, type: .transcribed) ?? []
        resumeTranslated = jobStore.loadCues(id: job.id, type: .translated)
        step = .processing
    }
}

#Preview {
    ContentView()
}
