# SubStamp

SubStamp is an iOS SwiftUI app for generating **burned-in subtitles** for videos. It:

- Imports a video from Photos
- Transcribes the audio into time-coded subtitle cues (Speech framework)
- Optionally translates subtitles into one or two tracks (Translation framework; direct or “via English” pivot)
- Lets you review/edit cues and tweak subtitle style
- Renders subtitles onto the video and exports an MP4
- Saves the result to Photos or shares the output file

## Requirements

- Xcode (this repo is an `.xcodeproj` project)
- iOS deployment target is currently set to `26.0` in `SubStamp.xcodeproj`
- Uses Apple’s `SpeechTranscriber` / `SpeechAnalyzer` and `Translation` frameworks (best tested on a real device)
- Free storage for language model downloads (the app warns when storage is low)

## Getting started

1. Open `SubStamp.xcodeproj` in Xcode
2. Select a device (recommended: physical iPhone/iPad)
3. Build & Run

## App flow

1. **Setup languages**: choose the audio language and subtitle track(s), then download required assets.
2. **Pick a video**: preview metadata and optionally run a 1-minute test clip for long videos.
3. **Processing**: transcribe → translate → (optional review) → render → export.
4. **Review**: edit text, split/merge cues, nudge timing, and adjust subtitle style.
5. **Result**: preview, save to Photos, or share.

## Project structure

- `SubStamp/SubStampApp.swift`: app entry + audio session configuration
- `SubStamp/ContentView.swift`: wizard navigation + resume support for unfinished jobs
- `SubStamp/Services/AssetReadinessManager.swift`: checks/downloads Speech + Translation assets
- `SubStamp/Services/PipelineOrchestrator.swift`: runs the pipeline and publishes stage/progress
- `SubStamp/Services/TranscriptionService.swift`: extracts audio and generates subtitle cues
- `SubStamp/Services/TranslationService.swift`: translates cues (batch + per-cue fallback)
- `SubStamp/Services/SubtitleRenderer.swift`: burns subtitles using `AVVideoComposition` + Core Animation
- `SubStamp/Services/ExportService.swift`: exports MP4 via `AVAssetExportSession`
- `SubStamp/Services/JobStore.swift`: persists jobs/cues under Application Support for resume
- `SubStamp/UI/*`: SwiftUI screens and components
- `SubStamp/Domain/*`: core models and enums

## Permissions / background processing

Info.plist keys are configured via Xcode build settings (`INFOPLIST_KEY_*`), including:

- Speech recognition (`NSSpeechRecognitionUsageDescription`)
- Microphone (`NSMicrophoneUsageDescription`)
- Save-to-Photos (`NSPhotoLibraryAddUsageDescription`)
- Background processing (`UIBackgroundModes = processing`)
- Continued processing identifiers (`BGTaskSchedulerPermittedIdentifiers`)

## Testing

- Unit tests: `SubStampTests` (Swift Testing)
- UI tests: `SubStampUITests` (XCTest)

Run tests from Xcode, or with `xcodebuild test` using the `SubStamp` scheme and a suitable destination.

## Notes / troubleshooting

- If transcription/translation downloads fail, check free space and retry.
- Some language pairs may route “via English” pivot translation; quality may vary.
- iOS can pause background work; keeping the screen awake is usually fastest.
