import Foundation
import Translation

final class TranslationService {
    func translate(
        cues: [SubtitleCue],
        session: TranslationSession,
        progressHandler: @escaping (Int, Int) -> Void
    ) async throws -> [SubtitleCue] {
        var output = cues
        progressHandler(0, cues.count)

        do {
            let requests = cues.map { cue in
                TranslationSession.Request(sourceText: cue.primaryText, clientIdentifier: cue.id.uuidString)
            }
            let stream = session.translate(batch: requests)
            var completed = 0
            for try await response in stream {
                if let clientIdentifier = response.clientIdentifier,
                   let id = UUID(uuidString: clientIdentifier),
                   let index = output.firstIndex(where: { $0.id == id }) {
                    output[index].secondaryText = SubtitleTextCleaner.clean(response.targetText)
                    output[index].hasTranslationError = false
                }
                completed += 1
                progressHandler(completed, cues.count)
            }
            return output
        } catch {
            var completed = 0
            for index in output.indices {
                do {
                    let response = try await session.translate(output[index].primaryText)
                    output[index].secondaryText = SubtitleTextCleaner.clean(response.targetText)
                    output[index].hasTranslationError = false
                } catch {
                    output[index].hasTranslationError = true
                    output[index].secondaryText = nil
                }
                completed += 1
                progressHandler(completed, cues.count)
            }
            return output
        }
    }
}
