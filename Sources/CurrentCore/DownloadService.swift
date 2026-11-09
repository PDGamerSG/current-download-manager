import Foundation

public actor DownloadService {
    private let store: StateStore
    private let engine: Aria2Engine
    private var state: AppState
    private var loop: Task<Void,Never>?
    private var locked = false
    private var waiters: [CheckedContinuation<Void,Never>] = []
    private var stopping = false
    private var finalizing: [String:String] = [:]
    private var finalizationTasks: [String:Task<Void,Never>] = [:]
    private var loadedCookies = ""
    private struct ActiveMedia { var generation: String; let worker: MediaWorker; let speedLimit: Int64 }
    private var media: [String:ActiveMedia] = [:]
    private var engineSpeedLimit: Int64?
    private var previousBytes: [String:Int64] = [:]
    public private(set) var engineError: String?
    public init(store: StateStore) throws { self.store = store; state = try store.load(); engine = Aria2Engine(store:store) }
    public func snapshot() -> AppState { state }
    private func acquire() async {
        if !locked { locked = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() { if waiters.isEmpty { locked = false } else { waiters.removeFirst().resume() } }
    public func start() async throws {
        _ = try state.settings.validated()
        loadedCookies = try TransferSafety.cookieJar(state.jobs)
        try await engine.start(settings:state.settings,cookieJar:loadedCookies)
        for i in state.jobs.indices {
            state.jobs[i].gid = nil; state.jobs[i].bytesPerSecond = 0; state.jobs[i].connections = 0
            if ![.complete,.error,.cancelled].contains(state.jobs[i].status) { state.jobs[i].status = state.jobs[i].intent == .paused ? .paused : .waiting }
            previousBytes[state.jobs[i].id] = state.jobs[i].completedBytes
        }
        try store.save(state)
        for job in state.jobs where job.needsVerification == true && job.intent != .cancelled && job.status != .complete { beginFinalization(job) }
        try await tick()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds:400_000_000)
                guard !Task.isCancelled, let self else { break }
                do { try await self.tick() } catch { await self.recordEngineError(error.localizedDescription) }
            }
        }
    }
    private func recordEngineError(_ message: String) { engineError = message }
    public func stop() async {
        stopping = true; loop?.cancel(); loop = nil
        await acquire(); defer { release() }
        for task in finalizationTasks.values { task.cancel() }; finalizationTasks.removeAll(); finalizing.removeAll()
        for id in Array(media.keys) { _ = try? await cancelMedia(id) }
        if let statuses = try? await engine.statuses() { apply(statuses) }
        try? store.save(state); await engine.stop()
    }
    public func command(_ input: JSONValue) async throws -> JSONValue {
        let action = input["action"].string
        if action == "status" { return try .from(state) }
        if action == "export" { return try .from(state.jobs.map{ $0.request.redacted }) }
        if action == "grab" {
            guard input.object["depth"] == nil || input["depth"].integer != nil else { throw CurrentError.invalid("Crawl depth must be a whole number.") }
            return try await .from(SiteGrabber.preview(url:input["url"].string,depth:input["depth"].int,extensions:input["extensions"].array.map{$0.string}))
        }
        if action == "install-browser-host" { return .string(try BrowserInstaller.install()) }
        await acquire(); defer { release() }
        guard !stopping else { throw CurrentError.invalid("Current is shutting down.") }
        var result: JSONValue = .bool(true)
        switch action {
        case "add", "import":
            var requests: [DownloadRequest]
            if let array = input.object["requests"] { requests = try array.decode([DownloadRequest].self) }
            else if let request = input.object["request"] { requests = [try request.decode(DownloadRequest.self)] }
            else {
                let template = try input.decode(DownloadRequest.self)
                requests = template.urls.map { url in var r = template; r.urls = [url]; return r }
            }
            guard !requests.isEmpty, requests.count <= 500, state.jobs.count+requests.count <= 5000 else { throw CurrentError.invalid("Add 1–500 downloads at a time; archive old history after 5,000 entries.") }
            // Validate the entire batch before accepting any item.
            requests = try requests.map { try $0.validated() }
            for r in requests { guard state.queues.contains(where:{$0.id == r.queueID}) else { throw CurrentError.invalid("Choose an existing download queue.") } }
            var jobs: [DownloadJob] = []
            do {
                for request in requests { jobs.append(try makeJob(request,existing:state.jobs+jobs)) }
                var candidate = state; candidate.jobs += jobs
                _ = try TransferSafety.cookieJar(candidate.jobs)
                try store.save(candidate); state = candidate
            } catch {
                for job in jobs { TransferSafety.releaseEmptyReservation(job) }
                throw error
            }
            do { try await synchronizeCookies(); try await reconcile() }
            catch {
                for index in state.jobs.indices where jobs.contains(where:{$0.id == state.jobs[index].id}) { state.jobs[index].status = .error; state.jobs[index].error = error.localizedDescription }
                try? store.save(state)
            }
            result = try .from(jobs.compactMap { job in state.jobs.first(where:{$0.id == job.id}) })
        case "pause", "resume", "cancel", "retry", "remove", "delete-file", "priority", "move", "refresh":
            let ids = input.object["ids"]?.array.map{$0.string} ?? [input["id"].string]
            guard !ids.isEmpty, ids.allSatisfy({ id in state.jobs.contains(where:{$0.id == id}) }) else { throw CurrentError.invalid("Select an existing download.") }
            if action == "move" { guard state.queues.contains(where:{$0.id == input["queueID"].string}) else { throw CurrentError.invalid("Choose an existing queue.") } }
            for id in ids {
                guard let index = state.jobs.firstIndex(where:{$0.id == id}) else { continue }
                switch action {
                case "pause":
                    if [.complete,.error,.cancelled].contains(state.jobs[index].status) { continue }
                    state.jobs[index].intent = .paused; state.jobs[index].status = .paused; state.jobs[index].bytesPerSecond = 0
                    _ = try await cancelMedia(id)
                    if let gid = state.jobs[index].gid { _ = try? await engine.call("forcePause",[.string(gid)]) }
                case "resume", "retry", "refresh":
                    if state.jobs[index].status == .complete {
                        if action == "resume" { continue }
                        throw CurrentError.invalid("This file is complete. Add a new download to keep the existing file.")
                    }
                    if action != "refresh", state.jobs[index].needsVerification == true {
                        state.jobs[index].intent = .running; state.jobs[index].status = .waiting; state.jobs[index].error = nil
                        beginFinalization(state.jobs[index]); continue
                    }
                    invalidateFinalization(id); state.jobs[index].needsVerification = false
                    if action == "refresh" {
                        var r = state.jobs[index].request; r.urls = [input["url"].string]; _ = try r.validated()
                        // Old origin credentials must not follow a refreshed URL to a different origin.
                        if origin(r.urls[0]) != origin(state.jobs[index].request.urls[0]) { r.headers = [:]; r.username = nil; r.password = nil }
                        state.jobs[index].request = r
                    }
                    if [.error,.cancelled,.complete].contains(state.jobs[index].status) || action == "refresh" || action == "retry" {
                        try await detach(index)
                    }
                    state.jobs[index].intent = .running; state.jobs[index].status = .waiting; state.jobs[index].error = nil
                case "cancel", "remove", "delete-file":
                    invalidateFinalization(id)
                    if action == "delete-file", FileManager.default.fileExists(atPath:state.jobs[index].fileURL.path) { try TransferSafety.verifyOwnership(state.jobs[index]) }
                    state.jobs[index].intent = .cancelled
                    try await detach(index)
                    state.jobs[index].status = .cancelled; state.jobs[index].bytesPerSecond = 0
                    if action == "delete-file" {
                        if state.jobs[index].request.kind == .media { try MediaWorker.discardStaging(jobID:id,stateDirectory:store.directory) }
                        let url = state.jobs[index].fileURL
                        if FileManager.default.fileExists(atPath:url.path) {
                            // Detaching may await a child. Recheck after that wait
                            // so a replacement cannot inherit deletion permission.
                            try TransferSafety.verifyOwnership(state.jobs[index])
                            try FileManager.default.removeItem(at:url)
                        }
                    }
                    if action != "cancel" { state.jobs.remove(at:index) }
                case "priority":
                    guard let priority = input["priority"].integer else { throw CurrentError.invalid("Priority must be a whole number.") }
                    state.jobs[index].priority = max(-100,min(100,priority))
                case "move": state.jobs[index].request.queueID = input["queueID"].string
                default: break
                }
            }
            try store.save(state); try await synchronizeCookies(); try await reconcile()
        case "settings":
            var merged = try JSONValue.from(state.settings).object
            for (key,value) in input["settings"].object { merged[key] = value }
            let settings = try JSONValue.object(merged).decode(AppSettings.self).validated()
            _ = try await engine.call("changeGlobalOption",[.object(["max-concurrent-downloads":.string(String(settings.maxConcurrent))])])
            for job in state.jobs where job.gid != nil && ![.complete,.error,.cancelled].contains(job.status) {
                _ = try await engine.call("changeOption",[.string(job.gid!),.object(["all-proxy":.string(settings.proxy)])])
            }
            state.settings = settings
            try store.save(state); try await reconcile(); result = try .from(settings)
        case "queue-save":
            let queue = try input["queue"].decode(DownloadQueue.self)
            guard !queue.id.isEmpty, !queue.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, (1...32).contains(queue.maxConcurrent) else { throw CurrentError.invalid("Name the queue and choose 1–32 simultaneous downloads.") }
            if let schedule = queue.schedule, let end = schedule.end, end <= schedule.start { throw CurrentError.invalid("The schedule end must follow its start; use the next day for an overnight window.") }
            if let index = state.queues.firstIndex(where:{$0.id == queue.id}) { state.queues[index] = queue } else { state.queues.append(queue) }
            try store.save(state); try await reconcile(); result = try .from(queue)
        case "queue-delete":
            let id = input["id"].string; guard id != "main" else { throw CurrentError.invalid("The main queue cannot be deleted.") }
            state.queues.removeAll(where:{$0.id == id}); for i in state.jobs.indices where state.jobs[i].request.queueID == id { state.jobs[i].request.queueID = "main" }
            try store.save(state); try await reconcile()
        case "category-save":
            let category = try input["category"].decode(Category.self); try DownloadRequest.validateFilename(category.name)
            guard !category.id.isEmpty else { throw CurrentError.invalid("The category needs an identifier.") }
            if let i = state.categories.firstIndex(where:{$0.id == category.id}) { state.categories[i] = category } else { state.categories.insert(category,at:0) }
            try store.save(state); result = try .from(category)
        case "category-delete":
            let id = input["id"].string; guard id != "other" else { throw CurrentError.invalid("Keep the Other category for unclassified downloads.") }
            state.categories.removeAll(where:{$0.id == id}); try store.save(state)
        default: throw CurrentError.invalid("Unknown command: \(action)")
        }
        return result
    }
    private func origin(_ raw: String) -> String { guard let u = URL(string:raw) else { return "" }; return "\(u.scheme ?? "")://\(u.host ?? ""):\(u.port ?? (u.scheme == "https" ? 443 : 80))" }
    private func makeJob(_ request: DownloadRequest, existing: [DownloadJob]) throws -> DownloadJob {
        let url = URL(string:request.urls[0])!
        let category = state.categories.first(where:{$0.id == request.categoryID}) ?? state.categories.first(where:{$0.matches(url)}) ?? Category(id:"other",name:"Other",extensions:[])
        let directory = request.directory.flatMap{$0.isEmpty ? nil : $0} ?? URL(fileURLWithPath:state.settings.downloadDirectory).appendingPathComponent(category.name).path
        try FileManager.default.createDirectory(atPath:directory,withIntermediateDirectories:true)
        var name = request.filename.flatMap{$0.isEmpty ? nil : $0} ?? url.lastPathComponent
        if (try? DownloadRequest.validateFilename(name)) == nil { name = "download-"+String(UUID().uuidString.prefix(8)) }
        if request.kind == .media && request.filename == nil { name = "video-"+String(UUID().uuidString.prefix(8))+".mp4" }
        let original = name; var count = 1
        while true {
            let path = URL(fileURLWithPath:directory).appendingPathComponent(name).path
            if !FileManager.default.fileExists(atPath:path), !FileManager.default.fileExists(atPath:path+".aria2"), !existing.contains(where:{$0.directory == directory && $0.filename == name}) {
                var job = DownloadJob(request:request,filename:name,directory:directory,categoryID:category.id)
                if try TransferSafety.reserve(&job) { return job }
            }
            let u = URL(fileURLWithPath:original); let ext = u.pathExtension
            name = u.deletingPathExtension().lastPathComponent+" (\(count))"+(ext.isEmpty ? "" : "."+ext); count += 1
        }
    }
    private func detach(_ index: Int) async throws {
        _ = try await cancelMedia(state.jobs[index].id,acceptCompletion:false)
        if let gid = state.jobs[index].gid {
            _ = try? await engine.call("forceRemove",[.string(gid)])
            _ = try? await engine.call("removeDownloadResult",[.string(gid)])
            state.jobs[index].gid = nil
        }
    }
    private func tick() async throws {
        await acquire(); defer { release() }
        guard !stopping else { return }
        guard engine.isRunning else { throw CurrentError.invalid("The download engine stopped unexpectedly. Restart Current to recover unfinished downloads.") }
        apply(try await engine.statuses())
        if Date().timeIntervalSince(state.quotaWindow) >= 3600 { state.quotaWindow = Date(); state.quotaBytes = 0 }
        for job in state.jobs {
            let before = previousBytes[job.id] ?? 0; state.quotaBytes += max(0,job.completedBytes-before); previousBytes[job.id] = job.completedBytes
        }
        try await reconcile(); try store.save(state); engineError = nil
    }
    private func apply(_ statuses: [String:JSONValue]) {
        for index in state.jobs.indices {
            guard ![.complete,.error,.cancelled].contains(state.jobs[index].status), let gid = state.jobs[index].gid, let remote = statuses[gid], finalizing[state.jobs[index].id] == nil else { continue }
            let status = remote["status"].string
            state.jobs[index].totalBytes = Int64(remote["totalLength"].int)
            state.jobs[index].completedBytes = Int64(remote["completedLength"].int)
            state.jobs[index].bytesPerSecond = Int64(remote["downloadSpeed"].int)
            state.jobs[index].connections = remote["connections"].int
            state.jobs[index].bitfield = remote["bitfield"].string
            if status == "complete" { beginFinalization(state.jobs[index]) }
            else if status == "error" {
                state.jobs[index].status = .error; state.jobs[index].bytesPerSecond = 0
                let code = remote["errorCode"].string
                let hints = ["3":"File not found. Check the URL or refresh an expired link.","22":"The server rejected the request. Check login cookies or refresh the URL.","24":"Authentication failed. Supply valid credentials or browser cookies.","32":"Checksum mismatch. The downloaded file failed integrity verification.","9":"Not enough disk space.","13":"The destination already exists. Choose a different filename."]
                state.jobs[index].error = hints[code] ?? "Download failed (engine code \(code)). Check the source URL, network and destination permissions."
            } else if state.jobs[index].intent == .cancelled { state.jobs[index].status = .cancelled }
            else if state.jobs[index].intent == .paused { state.jobs[index].status = .paused }
            else { state.jobs[index].status = status == "active" ? .active : .waiting }
        }
    }
    private func reconcile() async throws {
        let now = Date(); var desired = Set<String>(); var queueCount: [String:Int] = [:]
        let globalLimit = state.settings.speedLimit
        let concurrent = globalLimit > 0 ? Int(min(Int64(state.settings.maxConcurrent),globalLimit)) : state.settings.maxConcurrent
        let quotaReached = state.settings.hourlyQuota > 0 && state.quotaBytes >= state.settings.hourlyQuota
        let sorted = state.jobs.filter { $0.intent == .running && ![.complete,.error,.cancelled].contains($0.status) && finalizing[$0.id] == nil }.sorted { $0.priority == $1.priority ? $0.createdAt < $1.createdAt : $0.priority > $1.priority }
        if !quotaReached {
            for job in sorted {
                guard desired.count < concurrent, let queue = state.queues.first(where:{$0.id == job.request.queueID}), queue.isEligible(at:now), queueCount[queue.id,default:0] < queue.maxConcurrent else { continue }
                desired.insert(job.id); queueCount[queue.id,default:0] += 1
            }
        }
        let share = globalLimit > 0 ? globalLimit / Int64(max(1,desired.count)) : 0
        let fileCount = state.jobs.filter { desired.contains($0.id) && $0.request.kind == .file }.count
        let fileLimit = globalLimit > 0 ? max(1,share * Int64(fileCount)) : 0
        if engineSpeedLimit != fileLimit {
            _ = try await engine.call("changeGlobalOption",[.object(["max-overall-download-limit":.string(String(fileLimit))])]); engineSpeedLimit = fileLimit
        }
        for index in state.jobs.indices {
            let job = state.jobs[index]
            guard ![.complete,.error,.cancelled].contains(job.status), finalizing[job.id] == nil else { continue }
            if job.request.kind == .media {
                let limit = share > 0 ? (job.request.speedLimit > 0 ? min(job.request.speedLimit,share) : share) : job.request.speedLimit
                if let active = media[job.id], !desired.contains(job.id) || active.speedLimit != limit { _ = try await cancelMedia(job.id) }
                if finalizing[job.id] != nil { continue }
                if desired.contains(job.id) && media[job.id] == nil { startMedia(index,speedLimit:limit) }
                else if !desired.contains(job.id) { state.jobs[index].status = job.intent == .paused ? .paused : .waiting; state.jobs[index].bytesPerSecond = 0 }
                continue
            }
            do { try TransferSafety.verifyOwnership(job) }
            catch { try await detach(index); state.jobs[index].status = .error; state.jobs[index].error = error.localizedDescription; continue }
            if job.gid == nil {
                do { state.jobs[index].gid = try await engine.add(job,settings:state.settings) }
                catch { state.jobs[index].status = .error; state.jobs[index].error = error.localizedDescription; continue }
            }
            guard let gid = state.jobs[index].gid else { continue }
            if desired.contains(job.id) {
                if state.jobs[index].status != .active {
                    do { _ = try await engine.call("unpause",[.string(gid)]); state.jobs[index].status = .active; state.jobs[index].hasStarted = true }
                    catch { /* An already active job is reconciled by the next status poll. */ }
                }
            } else {
                if state.jobs[index].status == .active { _ = try? await engine.call("forcePause",[.string(gid)]) }
                state.jobs[index].status = job.intent == .paused ? .paused : .waiting; state.jobs[index].bytesPerSecond = 0
            }
        }
    }
    private func startMedia(_ index: Int, speedLimit: Int64) {
        let job = state.jobs[index], generation = UUID().uuidString
        var effective = job
        effective.request.speedLimit = speedLimit
        let worker = MediaWorker(job:effective,stateDirectory:store.directory,onProgress:{ [weak self] progress in Task { await self?.updateMedia(job.id,generation:generation,progress:progress) } },onExit:{ [weak self] code,message in Task { await self?.mediaExited(job.id,generation:generation,code:code,message:message) } })
        do { media[job.id] = ActiveMedia(generation:generation,worker:worker,speedLimit:speedLimit); try worker.start(); state.jobs[index].status = .active }
        catch { media[job.id] = nil; state.jobs[index].status = .error; state.jobs[index].error = error.localizedDescription }
    }
    @discardableResult private func cancelMedia(_ id: String, acceptCompletion: Bool = true) async throws -> Bool {
        guard var entry = media[id] else { return false }
        // Invalidate queued callbacks before awaiting cleanup. Keep the handle on
        // timeout so a retry cannot start a second writer to the same partial.
        entry.generation = UUID().uuidString; media[id] = entry
        do {
            let code = try await entry.worker.cancelAndWait(); media[id] = nil
            if code == 0, let index = state.jobs.firstIndex(where:{$0.id == id}) { recordMediaOwnership(index,worker:entry.worker) }
            if code == 0, acceptCompletion, let index = state.jobs.firstIndex(where:{$0.id == id}), state.jobs[index].intent != .cancelled {
                beginFinalization(state.jobs[index]); return true
            }
            return false
        } catch {
            if let index = state.jobs.firstIndex(where:{$0.id == id}) { state.jobs[index].status = .error; state.jobs[index].error = error.localizedDescription }
            throw error
        }
    }
    private func updateMedia(_ id: String, generation: String, progress: MediaProgress) async {
        await acquire(); defer { release() }
        guard media[id]?.generation == generation, let index = state.jobs.firstIndex(where:{$0.id == id}) else { return }
        state.jobs[index].completedBytes = progress.completedBytes; state.jobs[index].totalBytes = progress.totalBytes; state.jobs[index].bytesPerSecond = progress.bytesPerSecond
    }
    private func mediaExited(_ id: String, generation: String, code: Int32, message: String) async {
        await acquire(); defer { release() }
        guard let entry = media[id], entry.generation == generation, let index = state.jobs.firstIndex(where:{$0.id == id}) else { return }
        media[id] = nil; state.jobs[index].bytesPerSecond = 0
        if code == 0 { recordMediaOwnership(index,worker:entry.worker); beginFinalization(state.jobs[index]) }
        else { state.jobs[index].status = .error; state.jobs[index].error = message.isEmpty ? "Media download failed. Check the source URL and supported formats." : message }
        try? store.save(state)
    }
    private func recordMediaOwnership(_ index: Int, worker: MediaWorker) {
        guard let identity = worker.completedFileIdentity() else { return }
        state.jobs[index].fileDevice = identity.device; state.jobs[index].fileInode = identity.inode; state.jobs[index].hasStarted = true
    }
    private func beginFinalization(_ job: DownloadJob) {
        guard finalizing[job.id] == nil else { return }
        guard let index = state.jobs.firstIndex(where:{$0.id == job.id}) else { return }
        state.jobs[index].needsVerification = true
        guard !stopping else { return }
        let generation = UUID().uuidString; finalizing[job.id] = generation
        let scanner = state.settings.scannerPath
        let verificationJob = state.jobs[index]
        finalizationTasks[job.id] = Task { [weak self] in
            do { let scan = try await FileVerifier.finish(verificationJob,scannerPath:scanner); await self?.finalized(job.id,generation:generation,error:nil,scan:scan) }
            catch { await self?.finalized(job.id,generation:generation,error:error.localizedDescription,scan:nil) }
        }
    }
    private func invalidateFinalization(_ id: String) { finalizing[id] = nil; finalizationTasks.removeValue(forKey:id)?.cancel() }
    private func finalized(_ id: String, generation: String, error: String?, scan: String?) async {
        await acquire(); defer { release() }
        guard finalizing[id] == generation else { return }; finalizing[id] = nil; finalizationTasks[id] = nil
        guard let index = state.jobs.firstIndex(where:{$0.id == id}), state.jobs[index].intent != .cancelled else { return }
        var failure = error
        if failure == nil {
            do { try TransferSafety.verifyOwnership(state.jobs[index]) }
            catch { failure = error.localizedDescription }
        }
        state.jobs[index].status = failure == nil ? .complete : .error; state.jobs[index].error = failure; state.jobs[index].scanResult = scan; state.jobs[index].bytesPerSecond = 0
        if failure == nil {
            state.jobs[index].needsVerification = false
            state.jobs[index].completedAt = Date()
            if let attrs = try? FileManager.default.attributesOfItem(atPath:state.jobs[index].fileURL.path), let size = attrs[.size] as? NSNumber { state.jobs[index].totalBytes = size.int64Value; state.jobs[index].completedBytes = size.int64Value }
        }
        try? store.save(state)
    }
    private func synchronizeCookies() async throws {
        let cookies = try TransferSafety.cookieJar(state.jobs)
        guard cookies != loadedCookies else { return }
        // A cookie jar is a process-wide aria2 startup option. Restarting is
        // deliberate: control files retain each partial and policy stays in Current.
        if let statuses = try? await engine.statuses() { apply(statuses) }
        await engine.stop()
        try await engine.start(settings:state.settings,cookieJar:cookies); loadedCookies = cookies; engineSpeedLimit = nil
        for index in state.jobs.indices where ![.complete,.error,.cancelled].contains(state.jobs[index].status) && finalizing[state.jobs[index].id] == nil {
            state.jobs[index].gid = nil; state.jobs[index].bytesPerSecond = 0
            state.jobs[index].status = state.jobs[index].intent == .paused ? .paused : .waiting
        }
    }
}

public final class ServiceRuntime {
    public let service: DownloadService
    private let bridge: HTTPBridge
    private let lock: ProcessLock
    public init() throws {
        let store = try StateStore(); lock = try ProcessLock(at:store.directory.appendingPathComponent("service.lock"))
        service = try DownloadService(store:store); bridge = HTTPBridge(store:store)
    }
    public func start() async throws { try await service.start(); do { try await bridge.start { [service] value in try await service.command(value) } } catch { await service.stop(); throw error } }
    public func stop() async { bridge.stop(); await service.stop() }
}
