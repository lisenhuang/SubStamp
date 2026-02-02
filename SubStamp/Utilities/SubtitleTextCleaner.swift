import Foundation

struct SubtitleTextCleaner {
    /// Cleans subtitle text by:
    /// 1. Collapsing multiple newlines into single newlines.
    /// 2. Trimming whitespace from each line.
    /// 3. Removing trailing full stops (Western '.' and Chinese '。') while keeping question marks.
    /// 4. Removing empty lines.
    static func clean(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        
        let cleanedLines = lines.map { line in
            var cleaned = line
            // Remove trailing periods (Western and Chinese)
            while cleaned.hasSuffix(".") || cleaned.hasSuffix("。") {
                cleaned.removeLast()
            }
            return cleaned.trimmingCharacters(in: .whitespaces)
        }
        
        return cleanedLines.joined(separator: "\n")
    }
}
