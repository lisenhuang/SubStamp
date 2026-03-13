import OSLog

enum Logging {
    nonisolated static let pipeline = Logger(subsystem: "com.huanglisen.SubStamp", category: "pipeline")
    nonisolated static let ui = Logger(subsystem: "com.huanglisen.SubStamp", category: "ui")
}
