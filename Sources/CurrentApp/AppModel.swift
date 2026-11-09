import AppKit
import Combine
import CurrentCore
import Foundation
import UniformTypeIdentifiers
import UserNotifications

enum LibraryLocation: Hashable {
    case all, active, paused, completed, failed
    case category(String), queue(String)

    func title(in state: AppState) -> String {
        switch self {
        case .all: return "All downloads"
        case .active: return "Active"
        case .paused: return "Paused"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .category(let id): return state.categories.first(where: { $0.id == id })?.name ?? "Category"
        case .queue(let id): return state.queues.first(where: { $0.id == id })?.name ?? "Queue"
        }
    }

    func includes(_ job: DownloadJob) -> Bool {
        switch self {
        case .all: return true
        case .active: return job.status == .active || job.status == .waiting
        case .paused: return job.status == .paused
        case .completed: return job.status == .complete
        case .failed: return job.status == .error
        case .category(let id): return job.categoryID == id
        case .queue(let id): return job.request.queueID == id
        }
    }
}

enum AppSheet: Identifiable {
    case add(String), preferences, queue(DownloadQueue), category(CurrentCore.Category), grabber, browsers
    var id: String {
        switch self {
        case .add: return "add"
        case .preferences: return "preferences"
        case .queue(let value): return "queue-" + value.id
        case .category(let value): return "category-" + value.id
        case .grabber: return "grabber"
        case .browsers: return "browsers"
        }
    }
}

struct AppNotice: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

struct RemovalRequest {
    let ids: [String]
    let deleteFiles: Bool
}

@MainActor
final class AppModel: ObservableObject {
    @Published var state = AppState()
    @Published var location: LibraryLocation? = .all
    @Published var selectedIDs = Set<String>()
    @Published var search = ""
    @Published var sheet: AppSheet?
    @Published var notice: AppNotice?
    @Published var removal: RemovalRequest?
    @Published var showInspector = true
    @Published var isStarting = true
    @Published var isConnected = false
    @Published var isAttached = false
    @Published var connectionMessage = "Starting download engine…"
    @Published var clipboardCandidate: String?
    @Published var notificationStatus = ""

    private var runtime: ServiceRuntime?
    private var pollingTask: Task<Void, Never>?
    private var didStart = false
    private var knownCompletions = Set<String>()
    private var hasInitialSnapshot = false
    private var clipboardChange = NSPasteboard.general.changeCount

    var visibleJobs: [DownloadJob] {
        state.jobs.filter { job in
            (location ?? .all).includes(job) && (search.isEmpty ||
                job.filename.localizedCaseInsensitiveContains(search) ||
                job.request.urls.contains(where: { $0.localizedCaseInsensitiveContains(search) }))
        }.sorted { $0.createdAt > $1.createdAt }
    }
    var selectedJobs: [DownloadJob] { state.jobs.filter { selectedIDs.contains($0.id) } }
    var selectedJob: DownloadJob? { selectedJobs.count == 1 ? selectedJobs.first : nil }
    var totalSpeed: Int64 { state.jobs.reduce(0) { $0 + $1.bytesPerSecond } }
    var canPause: Bool { selectedJobs.contains { $0.status == .active || $0.status == .waiting } }
    var canResume: Bool { selectedJobs.contains { [.paused, .error, .cancelled].contains($0.status) } }
    var canCancel: Bool { selectedJobs.contains { [.active, .waiting, .paused].contains($0.status) } }

    func start() async {
        guard !didStart else { return }
        didStart = true
        isStarting = true
        connectionMessage = "Starting download engine…"
        var candidate: ServiceRuntime?
        do {
            let newRuntime = try ServiceRuntime()
            candidate = newRuntime
            try await newRuntime.start()
            runtime = newRuntime
            isAttached = false
            accept(await newRuntime.service.snapshot())
            isConnected = true
        } catch {
            let startupError = error
            if let candidate { await candidate.stop() }
            do {
                let response = try await BridgeClient.request(.object(["action": .string("status")]))
                accept(try decodeState(response))
                isAttached = true
                isConnected = true
            } catch {
                isConnected = false
                connectionMessage = startupError.localizedDescription
            }
        }
        isStarting = false
        if isConnected { connectionMessage = isAttached ? "Connected to running service" : "Download engine ready" }
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self else { break }
                await self.poll()
            }
        }
    }

    func reconnect() {
        guard !isStarting else { return }
        isStarting = true
        Task {
            pollingTask?.cancel()
            if let owned = runtime {
                await owned.stop()
                runtime = nil
            }
            didStart = false
            await start()
        }
    }

    func shutdown() async {
        pollingTask?.cancel()
        if let runtime { await runtime.stop() }
    }

    private func decodeState(_ value: JSONValue) throws -> AppState {
        if value.object["state"] != nil { return try value["state"].decode(AppState.self) }
        return try value.decode(AppState.self)
    }

    private func poll() async {
        do {
            if let runtime {
                accept(await runtime.service.snapshot())
                if let error = await runtime.service.engineError {
                    isConnected = false
                    connectionMessage = error
                    return
                }
            }
            else { accept(try decodeState(await BridgeClient.request(.object(["action": .string("status")])))) }
            isConnected = true
            connectionMessage = isAttached ? "Connected to running service" : "Download engine ready"
        } catch {
            isConnected = false
            connectionMessage = error.localizedDescription
        }
        inspectClipboard()
    }

    private func accept(_ next: AppState) {
        let completions = Set(next.jobs.filter { $0.status == .complete }.map(\.id))
        if hasInitialSnapshot, next.settings.notifyOnCompletion {
            for job in next.jobs where completions.subtracting(knownCompletions).contains(job.id) {
                postCompletion(job)
            }
        }
        knownCompletions = completions
        hasInitialSnapshot = true
        if state != next { state = next }
        selectedIDs.formIntersection(Set(next.jobs.map(\.id)))
    }

    @discardableResult
    func send(_ action: String, _ payload: [String: JSONValue] = [:]) async throws -> JSONValue {
        var input = payload
        input["action"] = .string(action)
        let result: JSONValue
        if let runtime { result = try await runtime.service.command(.object(input)) }
        else { result = try await BridgeClient.request(.object(input)) }
        await poll()
        return result
    }

    func perform(_ action: String, ids: [String]? = nil, extra: [String: JSONValue] = [:]) {
        var payload = extra
        payload["ids"] = .array((ids ?? Array(selectedIDs)).map(JSONValue.string))
        Task {
            do { try await send(action, payload) }
            catch { show(error) }
        }
    }

    func pauseSelection() {
        perform("pause", ids: selectedJobs.filter { [.active, .waiting].contains($0.status) }.map(\.id))
    }

    func resumeSelection() {
        let paused = selectedJobs.filter { $0.status == .paused }.map(\.id)
        let retry = selectedJobs.filter { [.error, .cancelled].contains($0.status) }.map(\.id)
        if !paused.isEmpty { perform("resume", ids: paused) }
        if !retry.isEmpty { perform("retry", ids: retry) }
    }

    func cancelSelection() {
        perform("cancel", ids: selectedJobs.filter { [.active, .waiting, .paused].contains($0.status) }.map(\.id))
    }

    func show(_ error: Error) {
        notice = AppNotice(title: "Current couldn’t complete that action", message: error.localizedDescription)
    }

    func reveal(_ job: DownloadJob) { NSWorkspace.shared.activateFileViewerSelecting([job.fileURL]) }
    func open(_ job: DownloadJob) {
        guard FileManager.default.fileExists(atPath: job.fileURL.path) else {
            notice = AppNotice(title: "File not found", message: "The file may have been moved or deleted. Its saved location is \(job.fileURL.path).")
            return
        }
        NSWorkspace.shared.open(job.fileURL)
    }

    func requestRemoval(ids: [String]? = nil, deleteFiles: Bool = false) {
        let values = ids ?? Array(selectedIDs)
        guard !values.isEmpty else { return }
        removal = RemovalRequest(ids: values, deleteFiles: deleteFiles)
    }

    func importDownloads() {
        let panel = NSOpenPanel()
        panel.title = "Import downloads"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let data = try Data(contentsOf: url)
                guard data.count <= 10_485_760 else { throw CurrentError.invalid("Choose a download list smaller than 10 MiB.") }
                let requests = try JSONDecoder.current.decode([DownloadRequest].self, from: data)
                guard !requests.isEmpty, requests.count <= 500 else { throw CurrentError.invalid("Import a list containing 1–500 downloads.") }
                _ = try requests.map { try $0.validated() }
                try await send("add", ["requests": try .from(requests)])
            } catch { show(error) }
        }
    }

    func exportDownloads() {
        Task {
            do {
                let response = try await send("export")
                let panel = NSSavePanel()
                panel.title = "Export download list"
                panel.nameFieldStringValue = "Current downloads.json"
                panel.allowedContentTypes = [.json]
                guard panel.runModal() == .OK, let url = panel.url else { return }
                let encoder = JSONEncoder.current
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(response).write(to: url, options: .atomic)
            } catch { show(error) }
        }
    }

    func acceptDroppedText(_ text: String) {
        let links = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { Self.isDownloadURL($0) }
        if !links.isEmpty { sheet = .add(links.joined(separator: "\n")) }
    }

    static func isDownloadURL(_ text: String) -> Bool {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), url.host != nil else { return false }
        return ["http", "https", "ftp", "sftp"].contains(scheme)
    }

    private func inspectClipboard() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != clipboardChange else { return }
        clipboardChange = pasteboard.changeCount
        guard state.settings.clipboardDetection, NSApp.isActive,
              let value = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              Self.isDownloadURL(value) else { return }
        clipboardCandidate = value
    }

    var supportsNotifications: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    func requestNotificationPermission() {
        guard supportsNotifications else {
            notificationStatus = "Notifications are available from the packaged Current app."
            return
        }
        Task {
            do {
                let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                notificationStatus = allowed ? "Notifications are allowed." : "Notifications are off in System Settings."
            } catch { notificationStatus = error.localizedDescription }
        }
    }

    private func postCompletion(_ job: DownloadJob) {
        guard supportsNotifications else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = "Download complete"
            content.body = job.filename
            content.sound = .default
            try? await center.add(UNNotificationRequest(identifier: job.id, content: content, trigger: nil))
        }
    }
}

enum Display {
    static func icon(for job: DownloadJob) -> NSImage {
        NSWorkspace.shared.icon(for: UTType(filenameExtension: job.fileURL.pathExtension) ?? .data)
    }
    static func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
    static func speed(_ value: Int64) -> String { value > 0 ? "\(bytes(value))/s" : "—" }
    static func remaining(_ seconds: Int?) -> String {
        guard let seconds else { return "—" }
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }
    static func safeURL(_ value: String) -> String {
        guard var components = URLComponents(string: value) else { return value }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? value
    }
}

extension JobStatus {
    var title: String {
        switch self {
        case .waiting: return "Queued"
        case .active: return "Downloading"
        case .paused: return "Paused"
        case .complete: return "Completed"
        case .error: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
    var symbol: String {
        switch self {
        case .waiting: return "clock"
        case .active: return "arrow.down.circle.fill"
        case .paused: return "pause.circle"
        case .complete: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle"
        }
    }
}
