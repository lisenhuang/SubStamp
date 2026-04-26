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
