import Foundation
import OSLog

/// In-memory log for the app so the user can copy and share from the Log viewer.
enum AppLog {
    private static let queue = DispatchQueue(label: "com.substamp.applog", qos: .utility)
    private static let maxLines = 500
    private static var lines: [(date: Date, message: String)] = []

    static func append(_ message: String) {
        queue.async {
            let entry = (Date(), message)
            lines.append(entry)
            if lines.count > maxLines {
                lines.removeFirst(lines.count - maxLines)
            }
            Logging.pipeline.info("\(message)")
        }
    }

    static func append(error: Error) {
        append("Error: \(error.localizedDescription)")
        if let subStamp = error as? SubStampError {
            append("  \(subStamp.recoverySuggestion ?? "")")
        }
    }

    /// Full log text for display and copy (call from main thread or ensure thread-safe read).
    static var fullText: String {
        queue.sync {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return lines.map { "\(formatter.string(from: $0.date)) \($0.message)" }.joined(separator: "\n")
        }
    }

    static func clear() {
        queue.async { lines.removeAll() }
    }
}
