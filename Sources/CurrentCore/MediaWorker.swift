import Foundation
import Darwin
import CryptoKit

public struct MediaProgress {
    public var completedBytes: Int64
    public var totalBytes: Int64
    public var bytesPerSecond: Int64
}

// Process/outcome state is guarded by lock; file and progress state is confined to queue after start.
public final class MediaWorker: @unchecked Sendable {
    private let job: DownloadJob
    private let stateDirectory: URL
    private let onProgress: (MediaProgress) -> Void
    private let onExit: (Int32, String) -> Void
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "Current.MediaWorker", qos: .utility)
    private var pid: pid_t = 0
    private var started = false
    private var cancelled = false
    private var finished = false
    private var outcome: Int32?
    private var committedIdentity: (device: UInt64, inode: UInt64)?
    private var waiting: [UUID: CheckedContinuation<Int32, Error>] = [:]
    private var runDirectory: URL?
    private var stageDirectory: URL?
    private var stageDescriptor: Int32 = -1
    private var stagingOutput: URL?
    private var logReader: FileHandle?
    private var timer: DispatchSourceTimer?
    private var pendingLog = Data()
    private var logTail = Data()
    private var finalPath: String?
    private var currentFile = ""
    private var currentCompleted: Int64 = 0
    private var completedFormats: Int64 = 0
    private var lastProgress = MediaProgress(completedBytes: 0, totalBytes: 0, bytesPerSecond: 0)

    public init(job: DownloadJob, stateDirectory: URL, onProgress: @escaping (MediaProgress) -> Void, onExit: @escaping (Int32, String) -> Void) {
        self.job = job; self.stateDirectory = stateDirectory; self.onProgress = onProgress; self.onExit = onExit
    }

    public func completedFileIdentity() -> (device: UInt64, inode: UInt64)? {
        lock.lock(); defer { lock.unlock() }
        return committedIdentity
    }

    /// Call only after the job's worker has stopped. Traversal never follows directory or file symlinks.
    public static func discardStaging(jobID: String, stateDirectory: URL) throws {
        guard let identifier = UUID(uuidString: jobID)?.uuidString.lowercased() else { throw CurrentError.invalid("Invalid media job identifier.") }
        let state = Darwin.open(stateDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if state < 0, errno == ENOENT { return }
        guard state >= 0 else { throw CurrentError.invalid("Cannot safely open media staging for deletion.") }
        defer { Darwin.close(state) }
        try validatePrivateDirectory(state)
        func existingChild(_ name: String, in parent: Int32) throws -> Int32? {
            let descriptor = Darwin.openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if descriptor < 0, errno == ENOENT { return nil }
            guard descriptor >= 0 else { throw CurrentError.invalid("Cannot safely open media staging for deletion.") }
            do { try validatePrivateDirectory(descriptor); return descriptor }
            catch { Darwin.close(descriptor); throw error }
        }
        guard let media = try existingChild("media", in: state) else { return }
        defer { Darwin.close(media) }
        guard let jobs = try existingChild("jobs", in: media) else { return }
        defer { Darwin.close(jobs) }
        try removeStagedEntry(identifier, in: jobs, depth: 0)
    }

    private static func removeStagedEntry(_ name: String, in parent: Int32, depth: Int) throws {
        var entry = stat()
        if fstatat(parent, name, &entry, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return }
            throw CurrentError.invalid("Cannot inspect media staging for deletion.")
        }
        if entry.st_mode & S_IFMT != S_IFDIR {
            guard unlinkat(parent, name, 0) == 0 || errno == ENOENT else { throw CurrentError.invalid("Cannot remove media staging. Check folder permissions.") }
            return
        }
        guard depth < 16 else { throw CurrentError.invalid("Media staging has an unexpected directory structure.") }
        let folder = Darwin.openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { throw CurrentError.invalid("Media staging changed during deletion. Retry after checking its folder.") }
        defer { Darwin.close(folder) }
        try validatePrivateDirectory(folder)
        var opened = stat()
        guard fstat(folder, &opened) == 0, opened.st_dev == entry.st_dev, opened.st_ino == entry.st_ino else {
            throw CurrentError.invalid("Media staging changed during deletion. Retry after checking its folder.")
        }
        let duplicate = dup(folder)
        guard duplicate >= 0, let directory = fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            throw CurrentError.invalid("Cannot list media staging for deletion.")
        }
        defer { closedir(directory) }
        while true {
            errno = 0
            guard let item = readdir(directory) else {
                guard errno == 0 else { throw CurrentError.invalid("Cannot list all media staging files for deletion.") }
                break
            }
            let child = withUnsafeBytes(of: item.pointee.d_name) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
            if child != ".", child != ".." { try removeStagedEntry(child, in: folder, depth: depth + 1) }
        }
        var current = stat()
        guard fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0, current.st_dev == entry.st_dev, current.st_ino == entry.st_ino,
              unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw CurrentError.invalid("Media staging changed during deletion. Retry after checking its folder.") }
    }

    /// The only process arguments are fixed switches and a private configuration path.
    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard !started else { throw CurrentError.invalid("This media worker has already started.") }
        guard !cancelled else { throw CurrentError.invalid("This media worker was cancelled before it started.") }
        guard let tool = ToolLocator.find("yt-dlp") else {
            throw CurrentError.invalid("Website media capture requires yt-dlp. Install it with brew install yt-dlp, then retry. Install ffmpeg for merging separate audio and video streams.")
        }
        _ = try job.request.validated()
        try DownloadRequest.validateFilename(job.filename)
        guard job.request.kind == .media, job.request.urls.count == 1,
              let source = URL(string: job.request.urls[0]), ["http", "https"].contains(source.scheme?.lowercased() ?? "") else {
            throw CurrentError.invalid("A media job needs one HTTP or HTTPS source URL. Add other sources as separate downloads.")
        }
        guard job.directory.hasPrefix("/"), !job.directory.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw CurrentError.invalid("Choose an absolute destination folder for this media download.")
        }
        for value in [job.request.username, job.request.password].compactMap({ $0 }) {
            guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw CurrentError.invalid("Media credentials contain an invalid control character.")
            }
        }
        guard Self.outputCandidates(job.fileURL).allSatisfy({ !Self.entryExists($0.path) }) else {
            throw CurrentError.invalid("A file already exists at this destination. Choose another filename before retrying.")
        }
        let mediaDirectory = stateDirectory.appendingPathComponent("media", isDirectory: true)
        let run = mediaDirectory.appendingPathComponent("run-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: job.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let stateFD = try Self.openPrivateDirectory(stateDirectory)
            defer { Darwin.close(stateFD) }
            let mediaFD = try Self.openPrivateChild("media", in: stateFD)
            defer { Darwin.close(mediaFD) }
            try prepareStage(in: mediaFD)
            let runFD = try Self.openPrivateChild(run.lastPathComponent, in: mediaFD, reuse: false)
            Darwin.close(runFD)
            runDirectory = run
            let configURL = run.appendingPathComponent("options.conf")
            let cookiesURL = run.appendingPathComponent("cookies.txt")
            let cookies = try cookieFile(source: source)
            if let cookies, !FileManager.default.createFile(atPath: cookiesURL.path, contents: Data(cookies.utf8), attributes: [.posixPermissions: 0o600]) {
                throw CurrentError.invalid("Cannot write private session cookies.")
            }
            let config = configuration(ffmpeg: ToolLocator.find("ffmpeg"), cookies: cookies == nil ? nil : cookiesURL)
            guard FileManager.default.createFile(atPath: configURL.path, contents: Data(config.utf8), attributes: [.posixPermissions: 0o600]) else {
                throw CurrentError.invalid("Cannot write private media settings.")
            }
            let logURL = run.appendingPathComponent("progress.log")
            let logFD = Darwin.open(logURL.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            guard logFD >= 0 else { throw CurrentError.invalid("Cannot create the private media log.") }
            defer { Darwin.close(logFD) }
            logReader = try FileHandle(forReadingFrom: logURL)
            let child = try Self.spawn(tool: tool, config: configURL, logFD: logFD, workingDirectory: stageDirectory!)
            pid = child; started = true
            queue.async { [self] in
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now(), repeating: .milliseconds(200))
                timer.setEventHandler { [weak self] in self?.readProgress() }
                self.timer = timer; timer.resume()
            }
            DispatchQueue.global(qos: .utility).async { [self] in
                var status: Int32 = 0
                var waited: pid_t
                repeat { waited = waitpid(child, &status, 0) } while waited < 0 && errno == EINTR
                let result = waited < 0 ? Int32(1) : (status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f))
                queue.async { [self] in leaderExited(code: result) }
            }
        } catch {
            try? logReader?.close(); logReader = nil
            if let runDirectory { try? FileManager.default.removeItem(at: runDirectory) }
            runDirectory = nil
            if stageDescriptor >= 0 { Darwin.close(stageDescriptor); stageDescriptor = -1 }
            stageDirectory = nil; stagingOutput = nil
            throw CurrentError.invalid("The media worker could not start. Check that its state and destination folders are writable, private folders without symbolic links, and that yt-dlp is installed correctly.")
        }
    }

    /// Source/session identity changes must never resume an older URL's bytes after a refresh.
    private func prepareStage(in mediaFD: Int32) throws {
        guard let identifier = UUID(uuidString: job.id)?.uuidString.lowercased() else { throw CurrentError.invalid("Invalid media job identifier.") }
        let identity: [String: Any] = ["urls": job.request.urls, "headers": job.request.headers, "username": job.request.username as Any? ?? NSNull(), "password": job.request.password as Any? ?? NSNull()]
        let encoded = try JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys])
        let digest = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        let jobsFD = try Self.openPrivateChild("jobs", in: mediaFD)
        defer { Darwin.close(jobsFD) }
        let jobFD = try Self.openPrivateChild(identifier, in: jobsFD)
        defer { Darwin.close(jobFD) }
        stageDescriptor = try Self.openPrivateChild(digest, in: jobFD)
        let stage = stateDirectory.appendingPathComponent("media/jobs/" + identifier + "/" + digest, isDirectory: true)
        stageDirectory = stage
        // Existing resume files must be ordinary owned files, never links to something outside the private stage.
        for name in try FileManager.default.contentsOfDirectory(atPath: stage.path) {
            let file = Darwin.openat(stageDescriptor, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard file >= 0 else { throw CurrentError.invalid("Unsafe media resume artifact.") }
            defer { Darwin.close(file) }
            var info = stat()
            guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1,
                  fchmod(file, 0o600) == 0 else { throw CurrentError.invalid("Unsafe media resume artifact.") }
        }
        let ext = job.fileURL.pathExtension.lowercased()
        let safeExtension = !ext.isEmpty && ext.count <= 12 && ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) ? "." + ext : ""
        stagingOutput = stage.appendingPathComponent("payload" + safeExtension)
    }

    private static func openPrivateDirectory(_ url: URL) throws -> Int32 {
        if !entryExists(url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CurrentError.invalid("Unsafe media state directory.") }
        do { try validatePrivateDirectory(descriptor); return descriptor }
        catch { Darwin.close(descriptor); throw error }
    }

    private static func openPrivateChild(_ name: String, in parent: Int32, reuse: Bool = true) throws -> Int32 {
        guard mkdirat(parent, name, 0o700) == 0 || (reuse && errno == EEXIST) else { throw CurrentError.invalid("Cannot create private media staging.") }
        let descriptor = Darwin.openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CurrentError.invalid("Unsafe media staging directory.") }
        do { try validatePrivateDirectory(descriptor); return descriptor }
        catch { Darwin.close(descriptor); throw error }
    }

    private static func validatePrivateDirectory(_ descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), fchmod(descriptor, 0o700) == 0 else {
            throw CurrentError.invalid("Media staging must be a private folder owned by the current user.")
        }
    }

    private static func entryExists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 || errno != ENOENT
    }

    /// SIGINT lets yt-dlp persist native .part/.ytdl state; escalation also reaches ffmpeg and runtime children.
    public func cancel() {
        lock.lock()
        let firstCancellation = !cancelled; cancelled = true
        let child = finished ? 0 : pid
        lock.unlock()
        guard firstCancellation, child > 0 else { return }
        Darwin.kill(-child, SIGINT)
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in self?.signalIfRunning(child, signal: SIGTERM) }
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.signalIfRunning(child, signal: SIGKILL) }
    }

    /// Resume or replacement workers may start only after this returns: the process group and file cleanup are finished.
    public func cancelAndWait() async throws -> Int32 {
        cancel()
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if finished, let outcome { lock.unlock(); continuation.resume(returning: outcome); return }
            if !started { lock.unlock(); continuation.resume(returning: 130); return }
            let id = UUID()
            waiting[id] = continuation
            lock.unlock()
            // This queue is independent of parsing/finalization, so even a blocked cleanup has a bounded await.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8) { [self] in timeoutWaiter(id) }
        }
    }

    private func timeoutWaiter(_ id: UUID) {
        lock.lock(); let continuation = waiting.removeValue(forKey: id); lock.unlock()
        continuation?.resume(throwing: CurrentError.invalid("The media process did not stop within eight seconds. Wait briefly and retry pausing; restart Current if it remains active."))
    }

    private func signalIfRunning(_ child: pid_t, signal: Int32) {
        lock.lock(); let running = !finished && pid == child; lock.unlock()
        if running { Darwin.kill(-child, signal) }
    }

    private func leaderExited(code: Int32) {
        lock.lock(); let wasCancelled = cancelled; let child = pid; lock.unlock()
        if !wasCancelled, child > 0, Darwin.kill(-child, 0) == 0 {
            // A normal leader should reap its children; terminate unexpected survivors before publishing completion.
            Darwin.kill(-child, SIGTERM)
        }
        waitForGroupExit(child, code: code, attempt: 0)
    }

    private func waitForGroupExit(_ child: pid_t, code: Int32, attempt: Int) {
        // The leader can exit before a postprocessor. Keep escalation and this worker alive until the group stops.
        guard child > 0, Darwin.kill(-child, 0) == 0 else { complete(code: code); return }
        if attempt >= 50 { Darwin.kill(-child, SIGKILL) }
        queue.asyncAfter(deadline: .now() + .milliseconds(100)) { [self] in waitForGroupExit(child, code: code, attempt: attempt + 1) }
    }

    private func configuration(ffmpeg: URL?, cookies: URL?) -> String {
        func option(_ name: String, _ value: String) -> String { name + " " + Self.quote(value) }
        // Every downloader/postprocessor artifact stays in private staging, away from destination sidecars.
        let output = stagingOutput!.path.replacingOccurrences(of: "%", with: "%%")
        var lines = [
            "--no-plugin-dirs", "--no-exec", "--no-playlist", "--no-simulate", "--abort-on-error",
            "--no-overwrites", "--no-post-overwrites", "--continue", "--part", "--no-mtime",
            "--newline", "--progress", "--progress-delta 0.5", "--quiet", "--no-colors", "--no-cache-dir",
            "--downloader native", "--hls-prefer-native", "--abort-on-unavailable-fragments",
            "--retries 5", "--fragment-retries 5", "--extractor-retries 3", "--socket-timeout 20",
            option("--retry-sleep", "http:exp=1:8"), option("--retry-sleep", "fragment:exp=1:8"),
            option("--concurrent-fragments", String(job.request.speedLimit > 0 ? 1 : min(4, max(1, job.request.connections)))),
            option("--output", output),
            option("--paths", "home:" + stageDirectory!.path), option("--paths", "temp:" + stageDirectory!.path),
            option("--progress-template", #"download:CURRENT_PROGRESS {"downloaded":%(progress.downloaded_bytes|0)j,"total":%(progress.total_bytes,progress.total_bytes_estimate|0)j,"speed":%(progress.speed|0)j,"file":%(progress.filename|unknown)j}"#),
            option("--print", "after_move:CURRENT_FILE %(filepath)j")
        ]
        if let ffmpeg {
            lines.append(option("--ffmpeg-location", ffmpeg.path))
            lines.append(option("--format", "bestvideo*+bestaudio/best"))
            let ext = job.fileURL.pathExtension.lowercased()
            if ["mp4", "mkv", "webm", "mov"].contains(ext) { lines.append(option("--merge-output-format", ext)) }
        } else { lines.append(option("--format", "best")) }
        if job.request.speedLimit > 0 { lines.append(option("--limit-rate", String(job.request.speedLimit))) }
        if let cookies { lines.append(option("--cookies", cookies.path)) }
        for key in job.request.headers.keys.sorted() where key.lowercased() != "cookie" { lines.append(option("--add-headers", key + ":" + job.request.headers[key]!)) }
        if let username = job.request.username { lines.append(option("--username", username)) }
        if let password = job.request.password { lines.append(option("--password", password)) }
        // Config arguments precede CLI arguments in yt-dlp. A `--` here would turn the fixed CLI switches into URLs.
        // The validated source starts with http(s), so it cannot be interpreted as an option.
        lines.append(Self.quote(job.request.urls[0]))
        return lines.joined(separator: "\n") + "\n"
    }

    private func cookieFile(source: URL) throws -> String? {
        let headers = job.request.headers.filter { $0.key.lowercased() == "cookie" }.map(\.value)
        guard !headers.isEmpty, let host = source.host else { return nil }
        var result = "# Netscape HTTP Cookie File\n"
        for header in headers {
            for pair in header.split(separator: ";", omittingEmptySubsequences: true) {
                let pieces = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pieces.count == 2 else { throw CurrentError.invalid("The captured Cookie header is invalid. Capture the media link again.") }
                let name = pieces[0].trimmingCharacters(in: .whitespaces)
                let value = pieces[1].trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, !name.contains(where: { $0.isWhitespace || "()<>@,;:\\\"/[]?={}".contains($0) }) else {
                    throw CurrentError.invalid("The captured Cookie header is invalid. Capture the media link again.")
                }
                // Host-only cookies prevent session credentials from being attached to unrelated CDN domains.
                result += [host, "FALSE", "/", source.scheme?.lowercased() == "https" ? "TRUE" : "FALSE", "0", name, value].joined(separator: "\t") + "\n"
            }
        }
        return result
    }

    private static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// A dedicated group makes cancellation cover native media postprocessors without invoking a shell.
    private static func spawn(tool: URL, config: URL, logFD: Int32, workingDirectory: URL) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw CurrentError.invalid("Cannot initialize the media process.") }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw CurrentError.invalid("Cannot initialize the media process.") }
        defer { posix_spawnattr_destroy(&attributes) }
        var signals = sigset_t(); sigemptyset(&signals); sigaddset(&signals, SIGINT); sigaddset(&signals, SIGTERM)
        var mask = sigset_t(); sigemptyset(&mask)
        let directoryResult: Int32
        if #available(macOS 26.0, *) { directoryResult = posix_spawn_file_actions_addchdir(&actions, workingDirectory.path) }
        else { directoryResult = posix_spawn_file_actions_addchdir_np(&actions, workingDirectory.path) }
        guard posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              directoryResult == 0,
              posix_spawn_file_actions_adddup2(&actions, logFD, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, logFD, STDERR_FILENO) == 0,
              posix_spawn_file_actions_addclose(&actions, logFD) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawnattr_setsigdefault(&attributes, &signals) == 0,
              posix_spawnattr_setsigmask(&attributes, &mask) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else {
            throw CurrentError.invalid("Cannot configure the media process.")
        }
        let arguments = [tool.path, "--ignore-config", "--config-locations", config.path]
        var argv = arguments.map { strdup($0) } + [nil]
        defer { for argument in argv { if let argument { free(argument) } } }
        var child: pid_t = 0
        let result = argv.withUnsafeMutableBufferPointer { buffer in posix_spawn(&child, tool.path, &actions, &attributes, buffer.baseAddress!, environ) }
        guard result == 0 else { throw CurrentError.invalid("Cannot launch yt-dlp.") }
        return child
    }

    private func readProgress() {
        guard let reader = logReader else { return }
        while let data = try? reader.read(upToCount: 64 * 1024), !data.isEmpty {
            logTail.append(data)
            if logTail.count > 64 * 1024 { logTail.removeFirst(logTail.count - 64 * 1024) }
            pendingLog.append(data)
            while let newline = pendingLog.firstIndex(of: 10) {
                let line = pendingLog.prefix(upTo: newline)
                parseLine(String(decoding: line, as: UTF8.self))
                pendingLog.removeSubrange(...newline)
            }
            // Malformed external output cannot grow the in-memory line buffer indefinitely.
            if pendingLog.count > 256 * 1024 { pendingLog.removeFirst(pendingLog.count - 256 * 1024) }
        }
    }

    private func parseLine(_ line: String) {
        if line.hasPrefix("CURRENT_FILE ") {
            finalPath = try? JSONDecoder().decode(String.self, from: Data(line.dropFirst("CURRENT_FILE ".count).utf8))
            return
        }
        guard line.hasPrefix("CURRENT_PROGRESS "),
              let object = try? JSONSerialization.jsonObject(with: Data(line.dropFirst("CURRENT_PROGRESS ".count).utf8)) as? [String: Any] else { return }
        func bytes(_ key: String) -> Int64 {
            let value = (object[key] as? NSNumber)?.doubleValue ?? 0
            return value.isFinite && value > 0 ? Int64(min(value, Double(Int64.max - 1024))) : 0
        }
        let file = object["file"] as? String ?? "unknown"
        let completed = bytes("downloaded")
        if file != currentFile {
            completedFormats = completedFormats.addingReportingOverflow(currentCompleted).overflow ? completedFormats : completedFormats + currentCompleted
            currentCompleted = 0; currentFile = file
        }
        currentCompleted = max(currentCompleted, completed)
        let accumulated = completedFormats.addingReportingOverflow(currentCompleted)
        let total = completedFormats.addingReportingOverflow(bytes("total"))
        lastProgress = MediaProgress(completedBytes: max(lastProgress.completedBytes, accumulated.overflow ? Int64.max : accumulated.partialValue), totalBytes: max(lastProgress.totalBytes, total.overflow ? Int64.max : total.partialValue), bytesPerSecond: bytes("speed"))
        lastProgress.totalBytes = max(lastProgress.totalBytes, lastProgress.completedBytes)
        onProgress(lastProgress)
    }

    private func complete(code: Int32) {
        timer?.cancel(); timer = nil
        readProgress()
        if !pendingLog.isEmpty { parseLine(String(decoding: pendingLog, as: UTF8.self)); pendingLog.removeAll() }
        lock.lock(); let wasCancelled = cancelled; pid = 0; lock.unlock()
        var result = code
        var message = ""
        if code == 0 {
            do {
                let committed = try finalizeFile()
                lock.lock(); committedIdentity = (committed.device, committed.inode); lock.unlock()
                onProgress(MediaProgress(completedBytes: committed.size, totalBytes: committed.size, bytesPerSecond: 0))
            } catch { result = 1; message = "The media could not be committed safely. The destination may already exist; choose another filename or retry after checking its folder." }
        } else if wasCancelled { message = "Media download paused or cancelled. Partial files were retained for resuming." }
        else { message = failureMessage(code: code) }
        try? logReader?.close(); logReader = nil
        if let runDirectory { try? FileManager.default.removeItem(at: runDirectory) }
        runDirectory = nil
        if stageDescriptor >= 0 { Darwin.close(stageDescriptor); stageDescriptor = -1 }
        stageDirectory = nil; stagingOutput = nil
        lock.lock()
        outcome = result; finished = true
        let waiters = Array(waiting.values); waiting.removeAll()
        lock.unlock()
        onExit(result, message)
        for continuation in waiters { continuation.resume(returning: result) }
    }

    private func finalizeFile() throws -> (size: Int64, device: UInt64, inode: UInt64) {
        let destination = job.fileURL.standardizedFileURL
        guard stageDescriptor >= 0, let stagingOutput, let finalPath,
              Self.outputCandidates(stagingOutput).contains(URL(fileURLWithPath: finalPath).standardizedFileURL),
              Self.outputCandidates(destination).allSatisfy({ !Self.entryExists($0.path) }) else { throw CurrentError.invalid("Unsafe media output or destination collision.") }
        let leaf = URL(fileURLWithPath: finalPath).lastPathComponent
        let source = Darwin.openat(stageDescriptor, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard source >= 0 else { throw CurrentError.invalid("Cannot open staged media.") }
        defer { Darwin.close(source) }
        var info = stat()
        guard fstat(source, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1, info.st_size > 0 else {
            throw CurrentError.invalid("Incomplete or unsafe staged media.")
        }
        let folder = Darwin.open(destination.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { throw CurrentError.invalid("Cannot open the destination folder safely.") }
        defer { Darwin.close(folder) }
        let identity: (device: UInt64, inode: UInt64)
        if linkat(stageDescriptor, leaf, folder, destination.lastPathComponent, 0) != 0 {
            guard errno == EXDEV else { throw CurrentError.invalid("The destination already exists or cannot be created safely.") }
            identity = try Self.copyExclusively(source: source, size: info.st_size, folder: folder, filename: destination.lastPathComponent)
        } else { identity = (UInt64(UInt32(bitPattern: info.st_dev)), UInt64(info.st_ino)) }
        // Remove only entries in this owned private stage after its output was exclusively committed.
        if let stageDirectory {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: stageDirectory.path)) ?? [] { _ = unlinkat(stageDescriptor, name, 0) }
            _ = rmdir(stageDirectory.path)
        }
        return (info.st_size, identity.device, identity.inode)
    }

    private static func copyExclusively(source: Int32, size: off_t, folder: Int32, filename: String) throws -> (device: UInt64, inode: UInt64) {
        let destination = Darwin.openat(folder, filename, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard destination >= 0 else { throw CurrentError.invalid("The destination already exists or cannot be created safely.") }
        defer { Darwin.close(destination) }
        var owned = stat()
        guard fstat(destination, &owned) == 0 else { throw CurrentError.invalid("Cannot inspect the new media file.") }
        var succeeded = false
        defer {
            if !succeeded {
                var current = stat()
                if fstatat(folder, filename, &current, AT_SYMLINK_NOFOLLOW) == 0, current.st_dev == owned.st_dev, current.st_ino == owned.st_ino { _ = unlinkat(folder, filename, 0) }
            }
        }
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        var copied: off_t = 0
        while copied < size {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(source, $0.baseAddress!, min($0.count, Int(min(size - copied, off_t($0.count))))) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw CurrentError.invalid("Could not read the complete staged media.") }
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes { Darwin.write(destination, $0.baseAddress!.advanced(by: offset), count - offset) }
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw CurrentError.invalid("Could not write the media file. Check free disk space.") }
                offset += written
            }
            copied += off_t(count)
        }
        guard fsync(destination) == 0 else { throw CurrentError.invalid("Could not save the media file. Check free disk space.") }
        succeeded = true
        return (UInt64(UInt32(bitPattern: owned.st_dev)), UInt64(owned.st_ino))
    }

    private static func outputCandidates(_ destination: URL) -> Set<URL> {
        let destination = destination.standardizedFileURL
        var candidates: Set<URL> = [destination]
        for ext in ["mp4", "mkv", "webm", "mov", "flv", "avi", "m4a", "mka", "aac", "mp3", "ogg", "opus", "wav", "ts"] {
            candidates.insert(destination.appendingPathExtension(ext))
            candidates.insert(destination.deletingPathExtension().appendingPathExtension(ext))
        }
        return candidates
    }

    private func failureMessage(code: Int32) -> String {
        let output = String(decoding: logTail, as: UTF8.self).lowercased()
        if output.contains("drm") { return "This media is protected by DRM and cannot be downloaded by Current." }
        if output.contains("ffmpeg") && (output.contains("not found") || output.contains("not installed")) { return "This media needs ffmpeg. Install it with brew install ffmpeg, then retry." }
        if output.contains("403") || output.contains("401") || output.contains("sign in") || output.contains("login") || output.contains("cookies") { return "The website denied access. Capture a fresh media link with its session cookies, then retry." }
        if output.contains("404") || output.contains("410") { return "The media URL is unavailable or expired. Capture a fresh link and retry." }
        if output.contains("unsupported url") || output.contains("no video formats") { return "yt-dlp does not support this page or media format. Update yt-dlp or capture a direct media link." }
        if output.contains("fixed output name but more than one file") { return "This page contains multiple media items. Capture a single video or audio link and retry." }
        if output.contains("no such option") { return "The installed yt-dlp is too old for media capture. Update it with brew upgrade yt-dlp, then retry." }
        return "The media download failed (yt-dlp exit \(code)). Update yt-dlp or capture a fresh link, then retry."
    }
}
