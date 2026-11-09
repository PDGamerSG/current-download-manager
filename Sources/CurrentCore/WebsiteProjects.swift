import Foundation

public struct WebsiteProject: Codable, Identifiable {
    public var id: String
    public var name: String
    public var sourceURL: String
    public var destinationDirectory: String
    public var maxDepth: Int = 1
    public var mode: String = "site"
    public var includePatterns: [String] = []
    public var excludePatterns: [String] = []
    public var intervalSeconds: Int?
    public var scheduledAt: Date?
    public var enabled = true
    public var maxFiles = 300
    public var maxResourceBytes = 8 * 1024 * 1024
    public var maxTotalBytes = 64 * 1024 * 1024
    public var maxDurationSeconds = 120
    public var headers: [String: String] = [:]
    public var status = "idle"
    public var lastError: String?
    public var fileCount = 0
    public var totalBytes = 0
    public var lastRunAt: Date?
    public var lastSuccessAt: Date?
    public var nextRunAt: Date?
    public var outputDirectory: String?
    public var entryPath: String?
    var manuallyStopped = false
    var destinationIdentity: OfflineFileIdentity?

    public init(name: String, sourceURL: String, destinationDirectory: String) {
        id = UUID().uuidString.lowercased(); self.name = name
        self.sourceURL = sourceURL; self.destinationDirectory = destinationDirectory
    }
}

public actor WebsiteProjectManager {
    private let store: WebsiteProjectStore
    private var projects: [WebsiteProject]
    private var workers: [String: Task<Void, Never>] = [:]
    private var timer: Task<Void, Never>?
    private var started = false
    private var stopping = false
    private var editingIDs = Set<String>()

    public init(stateDirectory: URL) throws {
        let store = try WebsiteProjectStore(stateDirectory: stateDirectory)
        self.store = store; projects = try store.load()
    }
    public func start() async throws {
        guard !started else { return }
        guard !stopping else { throw CurrentError.invalid("Website projects are shutting down.") }
        for index in projects.indices where projects[index].status == "running" {
            projects[index].status = "idle"
            projects[index].lastError = "The previous capture was interrupted. The last successful snapshot is retained."
            if projects[index].enabled, !projects[index].manuallyStopped,
               projects[index].intervalSeconds != nil || projects[index].scheduledAt != nil {
                projects[index].nextRunAt = Date()
            }
        }
        try store.save(projects)
        started = true
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.tick()
            }
        }
    }
    public func stop() async {
        guard !stopping else { return }
        stopping = true; started = false
        timer?.cancel(); timer = nil
        let running = Array(workers.values)
        for task in running { task.cancel() }
        for task in running { await task.value }
        workers.removeAll()
        try? store.save(projects)
        stopping = false
    }
    public func command(_ input: JSONValue) async throws -> JSONValue {
        guard started, !stopping else { throw CurrentError.invalid("Website projects are not running or are shutting down.") }
        switch input["action"].string {
        case "web-project-list": return .object(["projects": try .from(projects)])
        case "web-project-save":
            let value = input["project"]
            guard !value.object.isEmpty else { throw CurrentError.invalid("Provide a website project definition.") }
            let existing = value["id"].string.isEmpty ? nil : projects.firstIndex { $0.id == value["id"].string }
            guard value["id"].string.isEmpty || existing != nil else { throw CurrentError.invalid("Choose an existing website project.") }
            guard !editingIDs.contains(value["id"].string) else { throw CurrentError.invalid("This website project is stopping or being deleted.") }
            if let existing, workers[projects[existing].id] != nil { throw CurrentError.invalid("Stop the website project before editing it.") }
            guard existing != nil || projects.count < 100 else { throw CurrentError.invalid("Save up to 100 website projects.") }
            var project = existing.map { projects[$0] } ?? WebsiteProject(name: "", sourceURL: "", destinationDirectory: "")
            try Self.configure(&project, input: value)
            var next = projects
            if let existing { next[existing] = project } else { next.append(project) }
            try store.save(next); projects = next
            return .object(["project": try .from(project)])
        case "web-project-run":
            guard !editingIDs.contains(input["id"].string) else { throw CurrentError.invalid("This website project is stopping or being deleted.") }
            let index = try index(input["id"].string)
            try launch(index)
            return .object(["project": try .from(projects[index])])
        case "web-project-stop":
            let id = input["id"].string
            guard !editingIDs.contains(id) else { throw CurrentError.invalid("This website project is already stopping or being deleted.") }
            let index = try index(id)
            editingIDs.insert(id); defer { editingIDs.remove(id) }
            var next = projects; next[index].manuallyStopped = true; next[index].status = "paused"; next[index].nextRunAt = nil
            try store.save(next); projects = next
            if let task = workers[id] { task.cancel(); await task.value }
            return .object(["project": try .from(projects[try self.index(id)])])
        case "web-project-delete":
            let id = input["id"].string
            guard !editingIDs.contains(id) else { throw CurrentError.invalid("This website project is already stopping or being deleted.") }
            _ = try index(id)
            editingIDs.insert(id); defer { editingIDs.remove(id) }
            if let task = workers[id] { task.cancel(); await task.value }
            let next = projects.filter { $0.id != id }
            try store.save(next); projects = next
            // Snapshots are user documents. Removing metadata never deletes them.
            return .object(["deleted": .bool(true)])
        default: throw CurrentError.invalid("Unknown website project command.")
        }
    }

    private func index(_ id: String) throws -> Int {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { throw CurrentError.invalid("Choose an existing website project.") }
        return index
    }
    private func tick() {
        guard started, !stopping else { return }
        for index in projects.indices where projects[index].enabled && !projects[index].manuallyStopped && !editingIDs.contains(projects[index].id) {
            guard let due = projects[index].nextRunAt, due <= Date(), workers[projects[index].id] == nil else { continue }
            try? launch(index)
        }
    }
    private func launch(_ index: Int) throws {
        let id = projects[index].id
        guard workers[id] == nil else { return }
        guard workers.count < 2 else { throw CurrentError.invalid("Two website projects are already running. Wait for one to finish or stop it first.") }
        var next = projects
        next[index].manuallyStopped = false; next[index].status = "running"; next[index].lastError = nil
        next[index].lastRunAt = Date(); next[index].nextRunAt = nil
        try store.save(next); projects = next
        let project = projects[index]
        workers[id] = Task { [weak self] in
            let result: Result<OfflineCaptureResult, Error>
            do { result = .success(try await OfflineWebsiteCapture.run(project)) }
            catch { result = .failure(error) }
            await self?.finished(id: id, result: result)
        }
    }
    private func finished(id: String, result: Result<OfflineCaptureResult, Error>) {
        workers[id] = nil
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        switch result {
        case .success(let output):
            projects[index].outputDirectory = output.directory
            projects[index].entryPath = "index.html"
            projects[index].fileCount = output.fileCount; projects[index].totalBytes = output.totalBytes
            projects[index].lastSuccessAt = Date(); projects[index].lastError = nil
            projects[index].status = projects[index].manuallyStopped ? "paused" : "complete"
        case .failure(let error):
            if error is CancellationError || stopping || projects[index].manuallyStopped {
                projects[index].status = projects[index].manuallyStopped ? "paused" : "idle"
                projects[index].lastError = nil
            } else {
                projects[index].status = "error"
                projects[index].lastError = error.localizedDescription
            }
        }
        if projects[index].enabled, !projects[index].manuallyStopped, let interval = projects[index].intervalSeconds {
            projects[index].nextRunAt = Date().addingTimeInterval(TimeInterval(interval))
        } else { projects[index].nextRunAt = nil }
        do { try store.save(projects) }
        catch { projects[index].lastError = "Website project status could not be saved: " + error.localizedDescription }
    }

    private static func configure(_ project: inout WebsiteProject, input: JSONValue) throws {
        if input.object["name"] != nil { project.name = input["name"].string.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !project.name.isEmpty, project.name.count <= 120, !hasControls(project.name) else { throw CurrentError.invalid("Name the website project using up to 120 characters.") }
        if input.object["sourceURL"] != nil { project.sourceURL = input["sourceURL"].string }
        guard let source = OfflineURL.normalized(project.sourceURL) else { throw CurrentError.invalid("Enter an HTTP or HTTPS source URL without embedded credentials.") }
        project.sourceURL = source.absoluteString
        if let value = input.object["destinationDirectory"] {
            guard value.string.hasPrefix("/"), !value.string.contains("\0") else { throw CurrentError.invalid("Choose an absolute website destination folder.") }
            let directory = try OfflineDirectory.open(URL(fileURLWithPath: value.string))
            if project.destinationDirectory != directory.url.path || project.destinationIdentity == nil {
                project.destinationIdentity = directory.identity
            } else if project.destinationIdentity != directory.identity {
                throw CurrentError.invalid("The destination folder was replaced. Select a new destination folder.")
            }
            project.destinationDirectory = directory.url.path
        }
        guard !project.destinationDirectory.isEmpty, project.destinationIdentity != nil else { throw CurrentError.invalid("Choose an existing destination folder.") }
        func integer(_ key: String, old: Int, range: ClosedRange<Int>) throws -> Int {
            guard let value = input.object[key] else { return old }
            guard let count = value.integer, range.contains(count) else { throw CurrentError.invalid("\(key) must be a whole number between \(range.lowerBound) and \(range.upperBound).") }
            return count
        }
        project.maxDepth = try integer("maxDepth", old: project.maxDepth, range: 0...5)
        project.maxFiles = try integer("maxFiles", old: project.maxFiles, range: 1...500)
        project.maxResourceBytes = try integer("maxResourceBytes", old: project.maxResourceBytes, range: 1024...(16 * 1024 * 1024))
        project.maxTotalBytes = try integer("maxTotalBytes", old: project.maxTotalBytes, range: 1024...(128 * 1024 * 1024))
        project.maxDurationSeconds = try integer("maxDurationSeconds", old: project.maxDurationSeconds, range: 1...300)
        if let value = input.object["mode"] { project.mode = value.string }
        guard ["site", "page"].contains(project.mode) else { throw CurrentError.invalid("Choose site or page capture mode.") }
        for key in ["includePatterns", "excludePatterns"] where input.object[key] != nil {
            guard case .array(let values) = input[key], values.count <= 32 else { throw CurrentError.invalid("Use up to 32 URL filter patterns.") }
            let patterns = values.map(\.string)
            guard patterns.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !hasControls($0) }) else { throw CurrentError.invalid("URL filter patterns must contain 1–256 printable characters.") }
            if key == "includePatterns" { project.includePatterns = patterns } else { project.excludePatterns = patterns }
        }
        if let value = input.object["intervalSeconds"] {
            if value == .null || value.integer == 0 { project.intervalSeconds = nil }
            else {
                guard let interval = value.integer, (60...2_592_000).contains(interval) else { throw CurrentError.invalid("Repeat captures every 60 seconds to 30 days, or use zero to turn repeats off.") }
                project.intervalSeconds = interval
            }
        }
        if let value = input.object["scheduledAt"] {
            if value == .null { project.scheduledAt = nil }
            else { project.scheduledAt = try value.decode(Date.self) }
        }
        if let enabled = input.object["enabled"] {
            guard case .bool(let value) = enabled else { throw CurrentError.invalid("Project enabled must be true or false.") }
            project.enabled = value
        }
        if let headers = input.object["headers"] {
            guard case .object(let values) = headers, values.count <= 16 else { throw CurrentError.invalid("Provide up to 16 website request headers.") }
            var validated: [String: String] = [:]
            let allowed = Set(["user-agent", "cookie", "authorization", "referer", "accept-language"])
            for (key, value) in values {
                guard allowed.contains(key.lowercased()), case .string(let text) = value, text.utf8.count <= 8192, !hasControls(text) else {
                    throw CurrentError.invalid("Use valid User-Agent, Cookie, Authorization, Referer or Accept-Language headers. They are scoped to the exact website origin.")
                }
                validated[key] = text
            }
            project.headers = validated
        }
        if project.enabled, !project.manuallyStopped {
            if let scheduled = project.scheduledAt { project.nextRunAt = scheduled }
            else if let interval = project.intervalSeconds { project.nextRunAt = Date().addingTimeInterval(TimeInterval(interval)) }
            else { project.nextRunAt = nil }
        } else { project.nextRunAt = nil }
    }
    private static func hasControls(_ value: String) -> Bool { value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }
}
