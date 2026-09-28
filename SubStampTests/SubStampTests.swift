//
//  SubStampTests.swift
//  SubStampTests
//
//  Created by Eason Smith on 2/1/26.
//

import AVFoundation
import Testing
@testable import SubStamp

struct SubStampTests {

    @Test func audioRecoveryRequiresReadableSamplesAndInvalidCursor() {
        let cursor = NSError(domain: AVFoundationErrorDomain, code: AVError.invalidSampleCursor.rawValue)
        #expect(AudioExtractionService.canRecover(error: cursor, frames: 16000))
        #expect(!AudioExtractionService.canRecover(error: cursor, frames: 0))
        #expect(!AudioExtractionService.canRecover(error: nil, frames: 16000))
        #expect(!AudioExtractionService.canRecover(error: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError), frames: 16000))
        #expect(!AudioExtractionService.canRecover(error: NSError(domain: AVFoundationErrorDomain, code: AVError.decoderNotFound.rawValue), frames: 16000))
    }

    @MainActor @Test func recoveredAudioWarningSurvivesSavingAndOldProjectsStillDecode() throws {
        var job = JobModel(videoURL: URL(fileURLWithPath: "/test.mp4"), transcriptionLocale: "en-US",
                           subtitleMode: .single, translationTargetLocale: nil)
        let oldData = try JSONEncoder().encode(job)
        #expect(try JSONDecoder().decode(JobModel.self, from: oldData).recoveredAudioEndSeconds == nil)
        job.recoveredAudioEndSeconds = 1620.4
        let data = try JSONEncoder().encode(job)
        #expect(try JSONDecoder().decode(JobModel.self, from: data).recoveredAudioEndSeconds == 1620.4)
    }

    @Test func sourceFrameDurationUsesNominalFPS() async throws {
        #expect(isFrameDuration(SubtitleRenderer.frameDuration(nominalFrameRate: 60, minFrameDuration: .invalid), fps: 60))
        #expect(isFrameDuration(SubtitleRenderer.frameDuration(nominalFrameRate: 59.94, minFrameDuration: .invalid), fps: 59.94))
        #expect(isFrameDuration(SubtitleRenderer.frameDuration(nominalFrameRate: 24, minFrameDuration: .invalid), fps: 24))
    }

    @Test func sourceFrameDurationFallsBackToMinimumFrameDuration() async throws {
        let minFrameDuration = CMTime(value: 1, timescale: 50)

        #expect(isFrameDuration(SubtitleRenderer.frameDuration(nominalFrameRate: 0, minFrameDuration: minFrameDuration), fps: 50))
    }

    @Test func sourceFrameDurationFallsBackToThirtyFPSForInvalidTiming() async throws {
        #expect(isFrameDuration(SubtitleRenderer.frameDuration(nominalFrameRate: 0, minFrameDuration: .invalid), fps: 30))
        #expect(isFrameDuration(SubtitleRenderer.frameDuration(nominalFrameRate: 500, minFrameDuration: .invalid), fps: 30))
    }

    private func isFrameDuration(_ duration: CMTime, fps: Double) -> Bool {
        abs(duration.seconds - (1 / fps)) < 0.0001
    }

}
