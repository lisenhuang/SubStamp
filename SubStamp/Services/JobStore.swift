import Foundation

struct ProjectSummary: Identifiable {
    let job: JobModel
    let cueCount: Int
    let hasTranslatedCues: Bool
    let videoExists: Bool

    var id: UUID { job.id }

    var displayName: String {
        let baseName = job.videoURL.deletingPathExtension().lastPathComponent
        return baseName.isEmpty ? job.videoURL.lastPathComponent : baseName
    }
}

final class JobStore {
    enum CueFile: String {
        case transcribed = "cues_transcribed"
        case translated = "cues_translated"
    }

    private let fileManager = FileManager.default

    func save(job: JobModel) throws {
        let url = jobURL(id: job.id)
        let data = try JSONEncoder().encode(job)
        try ensureDirectory()
        try data.write(to: url, options: .atomic)
    }

    func loadJob(id: UUID) throws -> JobModel {
        let url = jobURL(id: id)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(JobModel.self, from: data)
    }

    func loadAllJobs() -> [JobModel] {
        guard let contents = try? fileManager.contentsOfDirectory(at: jobsDirectory(), includingPropertiesForKeys: nil) else {
            return []
        }
        let jobs = contents
            .filter { $0.lastPathComponent.hasPrefix("job_") }
            .compactMap { url -> JobModel? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(JobModel.self, from: data)
            }
        return jobs.sorted(by: { $0.updatedAt > $1.updatedAt })
    }

    func loadProjectSummaries() -> [ProjectSummary] {
        loadAllJobs().map { job in
            let translated = loadCues(id: job.id, type: .translated)
            let transcribed = loadCues(id: job.id, type: .transcribed)
            let bestCues = translated?.isEmpty == false ? translated : transcribed
            return ProjectSummary(
                job: job,
                cueCount: bestCues?.count ?? 0,
                hasTranslatedCues: translated?.isEmpty == false,
                videoExists: fileManager.fileExists(atPath: job.videoURL.path)
            )
        }
    }

    func loadBestSavedCues(id: UUID) -> (cues: [SubtitleCue], type: CueFile)? {
        if let translated = loadCues(id: id, type: .translated), !translated.isEmpty {
            return (translated, .translated)
        }
        if let transcribed = loadCues(id: id, type: .transcribed), !transcribed.isEmpty {
            return (transcribed, .transcribed)
        }
        return nil
    }

    func deleteJob(id: UUID) {
        let otherJobs = loadAllJobs().filter { $0.id != id }
        if let job = try? loadJob(id: id) {
            removeManagedFileIfNeeded(job.videoURL, otherJobs: otherJobs)
            if let outputURL = job.outputURL {
                removeManagedFileIfNeeded(outputURL, otherJobs: otherJobs)
            }
        }
        try? fileManager.removeItem(at: jobURL(id: id))
        try? fileManager.removeItem(at: cueURL(id: id, type: .transcribed))
        try? fileManager.removeItem(at: cueURL(id: id, type: .translated))
    }

    func saveCues(_ cues: [SubtitleCue], id: UUID, type: CueFile) throws {
        let url = cueURL(id: id, type: type)
        let data = try JSONEncoder().encode(cues)
        try ensureDirectory()
        try data.write(to: url, options: .atomic)
    }

    func deleteCues(id: UUID, type: CueFile) {
        try? fileManager.removeItem(at: cueURL(id: id, type: type))
    }

    func loadCues(id: UUID, type: CueFile) -> [SubtitleCue]? {
        let url = cueURL(id: id, type: type)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([SubtitleCue].self, from: data)
    }

    private func jobsDirectory() -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("SubStamp/jobs", isDirectory: true)
    }

    private func ensureDirectory() throws {
        let dir = jobsDirectory()
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    private func jobURL(id: UUID) -> URL {
        jobsDirectory().appendingPathComponent("job_\(id.uuidString).json")
    }

    private func cueURL(id: UUID, type: CueFile) -> URL {
        jobsDirectory().appendingPathComponent("\(type.rawValue)_\(id.uuidString).json")
    }

    private func removeManagedFileIfNeeded(_ url: URL, otherJobs: [JobModel]) {
        guard fileManager.fileExists(atPath: url.path) else { return }

        let uploadsDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SubStamp/uploads", isDirectory: true)
            .standardizedFileURL.path
        let standardizedPath = url.standardizedFileURL.path
        let temporaryDirectory = fileManager.temporaryDirectory.standardizedFileURL.path
        let isStillReferenced = otherJobs.contains { job in
            if job.videoURL.standardizedFileURL.path == standardizedPath {
                return true
            }
            return job.outputURL?.standardizedFileURL.path == standardizedPath
        }

        let isManagedUpload = uploadsDirectory.map { standardizedPath.hasPrefix($0) } ?? false
        let isManagedTemporary = standardizedPath.hasPrefix(temporaryDirectory)
            && url.lastPathComponent.lowercased().hasPrefix("substamp_")

        guard (isManagedUpload || isManagedTemporary) && !isStillReferenced else { return }
        try? fileManager.removeItem(at: url)
    }
}
