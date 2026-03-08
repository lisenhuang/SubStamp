import Foundation

struct SubtitleTextCleaner {
    /// Cleans subtitle text by:
    /// 1. Converting embedded newlines into spaces so one cue stays one paragraph.
    /// 2. Collapsing repeated whitespace.
    /// 3. Removing trailing full stops (Western '.' and Chinese '。') while keeping question marks.
    static func clean(_ text: String) -> String {
        let flattened = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let collapsed = flattened.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )

        var cleaned = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasSuffix(".") || cleaned.hasSuffix("。") {
            cleaned.removeLast()
        }

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
