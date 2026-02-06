//
//  SubStampApp.swift
//  SubStamp
//
//  Created by Eason Smith on 2/1/26.
//

import AVFoundation
import SwiftUI

@main
struct SubStampApp: App {
    @StateObject private var settingsManager = SettingsManager()

    init() {
        configureAudioSession()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settingsManager)
                .preferredColorScheme(settingsManager.appearanceMode)
                .environment(\.locale, settingsManager.overrideLocale ?? .current)
        }
    }

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .default,
                options: [.mixWithOthers]
            )
            // Don't activate eagerly — let AVPlayer activate on demand
            // so other audio apps (Spotify, Podcasts, etc.) keep playing.
        } catch {
            print("Failed to set audio session category: \(error.localizedDescription)")
        }
    }
}
