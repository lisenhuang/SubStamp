import BackgroundTasks
import Foundation

final class BackgroundTaskManager {
    static let shared = BackgroundTaskManager()

    private let scheduler = BGTaskScheduler.shared
    private(set) var currentTask: BGContinuedProcessingTask?
    private(set) var currentIdentifier: String?

    private init() {}

    func register(identifier: String, handler: @escaping (BGContinuedProcessingTask) -> Void) {
        currentIdentifier = identifier
        scheduler.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let continuedTask = task as? BGContinuedProcessingTask else { return }
            self.currentTask = continuedTask
            handler(continuedTask)
        }
    }

    func submit(identifier: String, title: String, subtitle: String) throws {
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        request.strategy = .queue
        try scheduler.submit(request)
    }

    func updateProgress(fraction: Double, subtitle: String? = nil) {
        guard let task = currentTask else { return }
        task.progress.totalUnitCount = 100
        task.progress.completedUnitCount = Int64(fraction * 100)
        if let subtitle {
            task.updateTitle(task.title, subtitle: subtitle)
        }
    }

    func setExpirationHandler(_ handler: @escaping () -> Void) {
        currentTask?.expirationHandler = handler
    }

    func end(success: Bool) {
        currentTask?.setTaskCompleted(success: success)
        currentTask = nil
        currentIdentifier = nil
    }
}
