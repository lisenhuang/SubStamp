import OSLog

enum Logging {
    static let pipeline = Logger(subsystem: "com.huanglisen.SubStamp", category: "pipeline")
    static let ui = Logger(subsystem: "com.huanglisen.SubStamp", category: "ui")
}
