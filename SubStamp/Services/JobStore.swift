import Foundation

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

    func deleteJob(id: UUID) {
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
}
