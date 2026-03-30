import Foundation

struct ProjectSummary: Identifiable {
    let job: JobModel
    let cueCount: Int
    let hasTranslatedCues: Bool
    let videoExists: Bool
    let diskUsageBytes: Int64

    var id: UUID { job.id }

    var displayName: String {
        let baseName = job.videoURL.deletingPathExtension().lastPathComponent
        return baseName.isEmpty ? job.videoURL.lastPathComponent : baseName
    }

    var formattedDiskUsage: String {
        ByteCountFormatter.string(fromByteCount: diskUsageBytes, countStyle: .file)
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
        let job = try JSONDecoder().decode(JobModel.self, from: data)
        return try normalizedPersistedJob(job, at: url)
    }

    func loadAllJobs() -> [JobModel] {
        guard let contents = try? fileManager.contentsOfDirectory(at: jobsDirectory(), includingPropertiesForKeys: nil) else {
            return []
        }
        let jobs = contents
            .filter { $0.lastPathComponent.hasPrefix("job_") }
            .compactMap(loadPersistedJob)
        return jobs.sorted(by: { $0.updatedAt > $1.updatedAt })
    }

    func loadProjectSummaries() -> [ProjectSummary] {
        loadAllSavedJobs().map { job in
            let translated = loadSavedProjectCues(id: job.id, type: .translated)
            let transcribed = loadSavedProjectCues(id: job.id, type: .transcribed)
            let bestCues = translated?.isEmpty == false ? translated : transcribed
            return ProjectSummary(
                job: job,
                cueCount: bestCues?.count ?? 0,
                hasTranslatedCues: translated?.isEmpty == false,
                videoExists: fileManager.fileExists(atPath: job.videoURL.path),
                diskUsageBytes: diskUsageBytes(forSavedProject: job)
            )
        }
    }

    func totalManagedFileDiskUsageBytes() -> Int64 {
        totalBytes(for: managedFileURLs())
    }

    func totalSavedProjectDiskUsageBytes() -> Int64 {
        let urls = loadAllSavedJobs().flatMap { projectFileURLs(forSavedProject: $0) }
        return totalBytes(for: urls)
    }

    func totalNonProjectManagedDiskUsageBytes() -> Int64 {
        let protectedPaths = protectedManagedPathsForSavedProjects()
        let removable = managedFileURLs().filter { !protectedPaths.contains($0.standardizedFileURL.path) }
        return totalBytes(for: removable)
    }

    func saveProjectSnapshot(_ job: JobModel) throws {
        let data = try JSONEncoder().encode(job)
        try ensureDirectory()
        try data.write(to: savedJobURL(id: job.id), options: .atomic)
    }

    func saveProjectCues(_ cues: [SubtitleCue], id: UUID, type: CueFile) throws {
        let data = try JSONEncoder().encode(cues)
        try ensureDirectory()
        try data.write(to: savedCueURL(id: id, type: type), options: .atomic)
    }

    func loadBestSavedProjectCues(id: UUID) -> (cues: [SubtitleCue], type: CueFile)? {
        if let translated = loadSavedProjectCues(id: id, type: .translated), !translated.isEmpty {
            return (translated, .translated)
        }
        if let transcribed = loadSavedProjectCues(id: id, type: .transcribed), !transcribed.isEmpty {
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

    func deleteSavedProject(id: UUID) {
        let draftJob = try? loadJob(id: id)
        let savedJob = try? loadSavedJob(id: id)
        let remainingJobs = loadAllReferencedJobs(excluding: id)

        var managedURLs: [URL] = []
        if let draftJob {
            managedURLs.append(draftJob.videoURL)
            if let outputURL = draftJob.outputURL {
                managedURLs.append(outputURL)
            }
        }
        if let savedJob {
            managedURLs.append(savedJob.videoURL)
            if let outputURL = savedJob.outputURL {
                managedURLs.append(outputURL)
            }
        }

        removeManagedFilesIfNeeded(managedURLs, referencedJobs: remainingJobs)

        try? fileManager.removeItem(at: jobURL(id: id))
        try? fileManager.removeItem(at: cueURL(id: id, type: .transcribed))
        try? fileManager.removeItem(at: cueURL(id: id, type: .translated))
        try? fileManager.removeItem(at: savedJobURL(id: id))
        try? fileManager.removeItem(at: savedCueURL(id: id, type: .transcribed))
        try? fileManager.removeItem(at: savedCueURL(id: id, type: .translated))
    }

    func deleteAllSavedProjects() {
        let savedJobs = loadAllSavedJobs()
        let draftJobs = loadAllJobs()
        let managedURLs = (savedJobs + draftJobs).reduce(into: [URL]()) { urls, job in
            urls.append(job.videoURL)
            if let outputURL = job.outputURL {
                urls.append(outputURL)
            }
        }

        removeManagedFilesIfNeeded(managedURLs, referencedJobs: [])
        clearDirectoryContents(at: jobsDirectory())
        clearDirectoryContents(at: uploadsDirectory())
        clearManagedTemporaryFiles()
    }

    func deleteManagedFilesNotBelongingToSavedProjects() {
        let protectedPaths = protectedManagedPathsForSavedProjects()
        clearDirectoryContents(at: jobsDirectory(), keepingPaths: protectedPaths)
        clearDirectoryContents(at: uploadsDirectory(), keepingPaths: protectedPaths)
        clearManagedTemporaryFiles(keepingPaths: protectedPaths)
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

    func loadAllSavedJobs() -> [JobModel] {
        migrateLegacySavedProjectsIfNeeded()
        guard let contents = try? fileManager.contentsOfDirectory(at: jobsDirectory(), includingPropertiesForKeys: nil) else {
            return []
        }
        let jobs = contents
            .filter { $0.lastPathComponent.hasPrefix("project_job_") }
            .compactMap(loadPersistedJob)
        return jobs.sorted(by: { $0.updatedAt > $1.updatedAt })
    }

    func loadSavedProjectCues(id: UUID, type: CueFile) -> [SubtitleCue]? {
        let url = savedCueURL(id: id, type: type)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([SubtitleCue].self, from: data)
    }

    func deleteSavedProjectCues(id: UUID, type: CueFile) {
        try? fileManager.removeItem(at: savedCueURL(id: id, type: type))
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

    private func savedJobURL(id: UUID) -> URL {
        jobsDirectory().appendingPathComponent("project_job_\(id.uuidString).json")
    }

    private func savedCueURL(id: UUID, type: CueFile) -> URL {
        jobsDirectory().appendingPathComponent("project_\(type.rawValue)_\(id.uuidString).json")
    }

    private func loadSavedJob(id: UUID) throws -> JobModel {
        let data = try Data(contentsOf: savedJobURL(id: id))
        let job = try JSONDecoder().decode(JobModel.self, from: data)
        return try normalizedPersistedJob(job, at: savedJobURL(id: id))
    }

    private func loadPersistedJob(from url: URL) -> JobModel? {
        guard let data = try? Data(contentsOf: url),
              let job = try? JSONDecoder().decode(JobModel.self, from: data) else {
            return nil
        }
        return try? normalizedPersistedJob(job, at: url)
    }

    private func normalizedPersistedJob(_ job: JobModel, at persistedURL: URL) throws -> JobModel {
        let normalized = normalizedManagedPaths(in: job)
        guard hasDifferentManagedPaths(lhs: job, rhs: normalized) else { return normalized }

        let data = try JSONEncoder().encode(normalized)
        try ensureDirectory()
        try data.write(to: persistedURL, options: .atomic)
        return normalized
    }

    private func normalizedManagedPaths(in job: JobModel) -> JobModel {
        var normalized = job
        normalized.videoURL = remappedManagedURL(normalized.videoURL)
        normalized.outputURL = normalized.outputURL.map(remappedManagedURL)
        return normalized
    }

    private func hasDifferentManagedPaths(lhs: JobModel, rhs: JobModel) -> Bool {
        lhs.videoURL.standardizedFileURL.path != rhs.videoURL.standardizedFileURL.path
            || lhs.outputURL?.standardizedFileURL.path != rhs.outputURL?.standardizedFileURL.path
    }

    private func remappedManagedURL(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        guard !fileManager.fileExists(atPath: standardized.path) else { return standardized }

        if let candidate = remapURL(
            standardized,
            marker: "/Library/Application Support/SubStamp/uploads/",
            currentBase: uploadsDirectory()
        ), fileManager.fileExists(atPath: candidate.path) {
            return candidate
        }

        if let candidate = remapURL(
            standardized,
            marker: "/Library/Application Support/SubStamp/jobs/",
            currentBase: jobsDirectory()
        ), fileManager.fileExists(atPath: candidate.path) {
            return candidate
        }

        let tempCandidate = fileManager.temporaryDirectory
            .appendingPathComponent(standardized.lastPathComponent)
            .standardizedFileURL
        if standardized.lastPathComponent.lowercased().hasPrefix("substamp_"),
           fileManager.fileExists(atPath: tempCandidate.path) {
            return tempCandidate
        }

        return standardized
    }

    private func remapURL(_ url: URL, marker: String, currentBase: URL) -> URL? {
        let path = url.standardizedFileURL.path
        guard let range = path.range(of: marker) else { return nil }
        let suffix = String(path[range.upperBound...])
        return currentBase.appendingPathComponent(suffix).standardizedFileURL
    }

    private func migrateLegacySavedProjectsIfNeeded() {
        let legacyJobs = loadAllJobs().filter { !$0.shouldOfferResume }
        for job in legacyJobs {
            guard !fileManager.fileExists(atPath: savedJobURL(id: job.id).path) else { continue }
            try? saveProjectSnapshot(job)
            if let transcribed = loadCues(id: job.id, type: .transcribed) {
                try? saveProjectCues(transcribed, id: job.id, type: .transcribed)
            }
            if let translated = loadCues(id: job.id, type: .translated) {
                try? saveProjectCues(translated, id: job.id, type: .translated)
            }
        }
    }

    private func loadAllReferencedJobs(excluding id: UUID) -> [JobModel] {
        let drafts = loadAllJobs().filter { $0.id != id }
        let saved = loadAllSavedJobs().filter { $0.id != id }
        return drafts + saved
    }

    private func uploadsDirectory() -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("SubStamp/uploads", isDirectory: true)
    }

    private func diskUsageBytes(forSavedProject savedJob: JobModel) -> Int64 {
        totalBytes(for: projectFileURLs(forSavedProject: savedJob))
    }

    private func projectFileURLs(forSavedProject savedJob: JobModel) -> [URL] {
        var urls: [URL] = [
            savedJobURL(id: savedJob.id),
            savedCueURL(id: savedJob.id, type: .transcribed),
            savedCueURL(id: savedJob.id, type: .translated),
            savedJob.videoURL
        ]

        if let outputURL = savedJob.outputURL {
            urls.append(outputURL)
        }

        urls.append(jobURL(id: savedJob.id))
        urls.append(cueURL(id: savedJob.id, type: .transcribed))
        urls.append(cueURL(id: savedJob.id, type: .translated))

        if let draftJob = try? loadJob(id: savedJob.id) {
            urls.append(draftJob.videoURL)
            if let outputURL = draftJob.outputURL {
                urls.append(outputURL)
            }
        }

        return urls
    }

    private func protectedManagedPathsForSavedProjects() -> Set<String> {
        Set(
            loadAllSavedJobs()
                .flatMap { projectFileURLs(forSavedProject: $0) }
                .map { $0.standardizedFileURL.path }
        )
    }

    private func managedFileURLs() -> [URL] {
        directoryContents(at: jobsDirectory())
            + directoryContents(at: uploadsDirectory())
            + managedTemporaryFileURLs()
    }

    private func totalBytes(for urls: [URL]) -> Int64 {
        var seenPaths = Set<String>()
        return urls.reduce(into: Int64.zero) { total, url in
            let path = url.standardizedFileURL.path
            guard seenPaths.insert(path).inserted else { return }
            total += fileSizeBytes(at: url)
        }
    }

    private func fileSizeBytes(at url: URL) -> Int64 {
        guard fileManager.fileExists(atPath: url.path) else { return 0 }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return Int64(size)
    }

    private func removeManagedFilesIfNeeded(_ urls: [URL], referencedJobs: [JobModel]) {
        var seenPaths = Set<String>()
        for url in urls {
            let path = url.standardizedFileURL.path
            guard seenPaths.insert(path).inserted else { continue }
            removeManagedFileIfNeeded(url, otherJobs: referencedJobs)
        }
    }

    private func removeManagedFileIfNeeded(_ url: URL, otherJobs: [JobModel]) {
        guard fileManager.fileExists(atPath: url.path) else { return }

        let uploadsDirectory = uploadsDirectory().standardizedFileURL.path
        let standardizedPath = url.standardizedFileURL.path
        let temporaryDirectory = fileManager.temporaryDirectory.standardizedFileURL.path
        let isStillReferenced = otherJobs.contains { job in
            if job.videoURL.standardizedFileURL.path == standardizedPath {
                return true
            }
            return job.outputURL?.standardizedFileURL.path == standardizedPath
        }

        let isManagedUpload = standardizedPath.hasPrefix(uploadsDirectory)
        let isManagedTemporary = standardizedPath.hasPrefix(temporaryDirectory)
            && url.lastPathComponent.lowercased().hasPrefix("substamp_")

        guard (isManagedUpload || isManagedTemporary) && !isStillReferenced else { return }
        try? fileManager.removeItem(at: url)
    }

    private func clearDirectoryContents(at directory: URL, keepingPaths: Set<String> = []) {
        for url in directoryContents(at: directory) {
            if keepingPaths.contains(url.standardizedFileURL.path) {
                continue
            }
            try? fileManager.removeItem(at: url)
        }
    }

    private func clearManagedTemporaryFiles(keepingPaths: Set<String> = []) {
        for url in managedTemporaryFileURLs() {
            if keepingPaths.contains(url.standardizedFileURL.path) {
                continue
            }
            try? fileManager.removeItem(at: url)
        }
    }

    private func directoryContents(at directory: URL) -> [URL] {
        (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }

    private func managedTemporaryFileURLs() -> [URL] {
        directoryContents(at: fileManager.temporaryDirectory)
            .filter { $0.lastPathComponent.lowercased().hasPrefix("substamp_") }
    }
}
