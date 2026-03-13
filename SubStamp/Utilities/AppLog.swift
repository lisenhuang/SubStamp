import Foundation
import OSLog

/// In-memory log for the app so the user can copy and share from the Log viewer.
enum AppLog {
    nonisolated private static let queue = DispatchQueue(label: "com.substamp.applog", qos: .utility)
    nonisolated private static let maxLines = 2000
    nonisolated(unsafe) private static var lines: [(date: Date, message: String)] = []
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated static var fileURL: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("SubStamp").appendingPathComponent("app.log")
    }

    nonisolated static func append(_ message: String) {
        queue.async {
            let entry = (Date(), message)
            lines.append(entry)
            if lines.count > maxLines {
                lines.removeFirst(lines.count - maxLines)
            }
            appendToDisk(entry)
            Logging.pipeline.info("\(message)")
        }
    }

    nonisolated static func append(error: Error) {
        append("Error: \(error.localizedDescription)")
        if let subStamp = error as? SubStampError {
            append("  \(subStamp.recoverySuggestion ?? "")")
        }
    }

    /// Full log text for display and copy (call from main thread or ensure thread-safe read).
    nonisolated static var fullText: String {
        queue.sync {
            if let diskText = try? String(contentsOf: fileURL, encoding: .utf8), !diskText.isEmpty {
                return diskText
            }
            return lines.map { "\(formatter.string(from: $0.date)) \($0.message)" }.joined(separator: "\n")
        }
    }

    nonisolated static func clear() {
        queue.async {
            lines.removeAll()
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    nonisolated private static func appendToDisk(_ entry: (date: Date, message: String)) {
        let line = "\(formatter.string(from: entry.date)) \(entry.message)\n"
        let fileURL = self.fileURL
        let directory = fileURL.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                if let data = line.data(using: .utf8) {
                    try handle.write(contentsOf: data)
                }
            } else {
                try line.write(to: fileURL, atomically: true, encoding: .utf8)
            }
        } catch {
            Logging.pipeline.error("Failed to persist app log: \(error.localizedDescription)")
        }
    }
}
