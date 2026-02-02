import Foundation

struct JobModel: Identifiable, Codable {
    var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var videoURL: URL
    var transcriptionLocale: String
    var language1Locale: String
    var subtitle1Mode: TranslationMode?
    var subtitleMode: SubtitleMode
    var translationTargetLocale: String?
    var subtitle2Mode: TranslationMode?
    var subtitleLayout: SubtitleLayout
    var subtitleStyle: SubtitleStyle
    var exportPreset: ExportPreset
    var stage: ProcessingStage
    var outputURL: URL?
    var isTestClip: Bool
    var testClipDuration: Double

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        videoURL: URL,
        transcriptionLocale: String,
        language1Locale: String? = nil,
        subtitle1Mode: TranslationMode? = nil,
        subtitleMode: SubtitleMode,
        translationTargetLocale: String?,
        subtitle2Mode: TranslationMode? = nil,
        subtitleLayout: SubtitleLayout = .stacked,
        subtitleStyle: SubtitleStyle = SubtitleStyle(),
        exportPreset: ExportPreset = .balanced,
        stage: ProcessingStage = .idle,
        outputURL: URL? = nil,
        isTestClip: Bool = false,
        testClipDuration: Double = 60
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.videoURL = videoURL
        self.transcriptionLocale = transcriptionLocale
        self.language1Locale = language1Locale ?? transcriptionLocale
        self.subtitle1Mode = subtitle1Mode
        self.subtitleMode = subtitleMode
        self.translationTargetLocale = translationTargetLocale
        self.subtitle2Mode = subtitle2Mode
        self.subtitleLayout = subtitleLayout
        self.subtitleStyle = subtitleStyle
        self.exportPreset = exportPreset
        self.stage = stage
        self.outputURL = outputURL
        self.isTestClip = isTestClip
        self.testClipDuration = testClipDuration
    }
}

private extension JobModel {
    enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case updatedAt
        case videoURL
        case transcriptionLocale
        case language1Locale
        case subtitle1Mode
        case subtitleMode
        case translationTargetLocale
        case subtitle2Mode
        case subtitleLayout
        case subtitleStyle
        case exportPreset
        case stage
        case outputURL
        case isTestClip
        case testClipDuration
    }
}

extension JobModel {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        videoURL = try container.decode(URL.self, forKey: .videoURL)
        transcriptionLocale = try container.decode(String.self, forKey: .transcriptionLocale)
        // Default language1 to transcription locale for backward compatibility
        language1Locale = try container.decodeIfPresent(String.self, forKey: .language1Locale) ?? transcriptionLocale
        subtitle1Mode = try container.decodeIfPresent(TranslationMode.self, forKey: .subtitle1Mode)
        subtitleMode = try container.decode(SubtitleMode.self, forKey: .subtitleMode)
        translationTargetLocale = try container.decodeIfPresent(String.self, forKey: .translationTargetLocale)
        subtitle2Mode = try container.decodeIfPresent(TranslationMode.self, forKey: .subtitle2Mode)
        subtitleLayout = try container.decodeIfPresent(SubtitleLayout.self, forKey: .subtitleLayout) ?? .stacked
        subtitleStyle = try container.decodeIfPresent(SubtitleStyle.self, forKey: .subtitleStyle) ?? SubtitleStyle()
        exportPreset = try container.decodeIfPresent(ExportPreset.self, forKey: .exportPreset) ?? .balanced
        stage = try container.decodeIfPresent(ProcessingStage.self, forKey: .stage) ?? .idle
        outputURL = try container.decodeIfPresent(URL.self, forKey: .outputURL)
        isTestClip = try container.decodeIfPresent(Bool.self, forKey: .isTestClip) ?? false
        testClipDuration = try container.decodeIfPresent(Double.self, forKey: .testClipDuration) ?? 60
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(videoURL, forKey: .videoURL)
        try container.encode(transcriptionLocale, forKey: .transcriptionLocale)
        try container.encode(language1Locale, forKey: .language1Locale)
        try container.encodeIfPresent(subtitle1Mode, forKey: .subtitle1Mode)
        try container.encode(subtitleMode, forKey: .subtitleMode)
        try container.encodeIfPresent(translationTargetLocale, forKey: .translationTargetLocale)
        try container.encodeIfPresent(subtitle2Mode, forKey: .subtitle2Mode)
        try container.encode(subtitleLayout, forKey: .subtitleLayout)
        try container.encode(subtitleStyle, forKey: .subtitleStyle)
        try container.encode(exportPreset, forKey: .exportPreset)
        try container.encode(stage, forKey: .stage)
        try container.encodeIfPresent(outputURL, forKey: .outputURL)
        try container.encode(isTestClip, forKey: .isTestClip)
        try container.encode(testClipDuration, forKey: .testClipDuration)
    }
}
