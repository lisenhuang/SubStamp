import AVFoundation

struct SubtitleCue: Identifiable, Codable, Hashable {
    var id: UUID
    var start: CMTime
    var end: CMTime
    var primaryText: String
    var secondaryText: String?
    var originalTranscription: String?
    var hasTranslationError: Bool

    init(
        id: UUID = UUID(),
        start: CMTime,
        end: CMTime,
        primaryText: String,
        secondaryText: String? = nil,
        originalTranscription: String? = nil,
        hasTranslationError: Bool = false
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.primaryText = primaryText
        self.secondaryText = secondaryText
        self.originalTranscription = originalTranscription
        self.hasTranslationError = hasTranslationError
    }

    var duration: CMTime {
        end - start
    }

    var durationSeconds: Double {
        max(0, end.seconds - start.seconds)
    }

    mutating func shift(by seconds: Double) {
        let newStart = max(0, start.seconds + seconds)
        let newEnd = max(newStart, end.seconds + seconds)
        start = CMTime(seconds: newStart, preferredTimescale: 600)
        end = CMTime(seconds: newEnd, preferredTimescale: 600)
    }
}

private extension SubtitleCue {
    enum CodingKeys: String, CodingKey {
        case id
        case startSeconds
        case endSeconds
        case primaryText
        case secondaryText
        case originalTranscription
        case hasTranslationError
    }
}

extension SubtitleCue {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        let startSeconds = try container.decode(Double.self, forKey: .startSeconds)
        let endSeconds = try container.decode(Double.self, forKey: .endSeconds)
        primaryText = try container.decode(String.self, forKey: .primaryText)
        secondaryText = try container.decodeIfPresent(String.self, forKey: .secondaryText)
        let decodedOriginal = try container.decodeIfPresent(String.self, forKey: .originalTranscription)
        originalTranscription = decodedOriginal ?? primaryText
        hasTranslationError = try container.decodeIfPresent(Bool.self, forKey: .hasTranslationError) ?? false
        start = CMTime(seconds: startSeconds, preferredTimescale: 600)
        end = CMTime(seconds: endSeconds, preferredTimescale: 600)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(start.seconds, forKey: .startSeconds)
        try container.encode(end.seconds, forKey: .endSeconds)
        try container.encode(primaryText, forKey: .primaryText)
        try container.encodeIfPresent(secondaryText, forKey: .secondaryText)
        try container.encodeIfPresent(originalTranscription, forKey: .originalTranscription)
        try container.encode(hasTranslationError, forKey: .hasTranslationError)
    }
}
