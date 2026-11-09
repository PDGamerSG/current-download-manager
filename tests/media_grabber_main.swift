import Foundation
import Darwin

private final class Observations {
    let lock = NSLock()
    var progress: [MediaProgress] = []
    var exit: (Int32, String)?
    func record(_ value: MediaProgress) { lock.lock(); defer { lock.unlock() }; progress.append(value) }
    func finish(_ code: Int32, _ message: String) { lock.lock(); defer { lock.unlock() }; exit = (code, message) }
    func snapshot() -> ([MediaProgress], (Int32, String)?) { lock.lock(); defer { lock.unlock() }; return (progress, exit) }
}

@main struct MediaGrabberChecks {
    static var assertions = 0
    static var failures = 0
    static func expect(_ value: Bool, _ description: String) {
        assertions += 1
        if !value { failures += 1; print("FAIL: \(description)") }
    }
    static func rejected(_ operation: () async throws -> Void, _ description: String) async {
        do { try await operation(); expect(false, description) } catch { expect(true, description) }
    }
    static func stageDirectory(_ job: DownloadJob, state: URL) throws -> URL {
        let folder = state.appendingPathComponent("media/jobs/" + job.id.lowercased())
        guard let stage = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first else { throw CurrentError.invalid("Missing media stage.") }
        return stage
    }
    static func noPrivateRuns(_ state: URL) throws -> Bool {
        try !FileManager.default.contentsOfDirectory(atPath: state.appendingPathComponent("media").path).contains(where: { $0.hasPrefix("run-") })
    }
    static func main() async throws {
        let root = CommandLine.arguments[1]
        let state = URL(fileURLWithPath: CommandLine.arguments[2])
        let mode = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "all"
        if ["all", "grabber"].contains(mode) {
            await rejected({ _ = try await SiteGrabber.preview(url: "file:///etc/passwd", depth: 0, extensions: ["zip"]) }, "grabber rejects local files")
            await rejected({ _ = try await SiteGrabber.preview(url: "http://person:secret@127.0.0.1/", depth: 0, extensions: ["zip"]) }, "grabber rejects embedded credentials")
            let direct = try await SiteGrabber.preview(url: root + "/grab/index.html", depth: 0, extensions: [".ZIP", "MP4", "pdf"])
            let paths = Set(direct.map(\.url))
            if paths.count != 4 { print("Observed preview links: \(paths.sorted())") }
            expect(paths == Set([root + "/grab/sub/clip.mp4?x=1&y=2", root + "/grab/sub/UPPER.MP4", root + "/grab/sub/archive%20one.zip", root + "/grab/sub/caf%C3%A9.pdf"]), "base URI, entities, relative links, deduplication and origin filtering")
            expect(direct.first(where: { $0.filename == "archive one.zip" }) != nil, "preview filenames are decoded")
            let depthOne = try await SiteGrabber.preview(url: root + "/grab/index.html", depth: 1, extensions: ["zip"])
            expect(depthOne.contains(where: { $0.url == root + "/depth-1.zip" }), "depth one visits linked HTML pages")
            expect(!depthOne.contains(where: { $0.url == root + "/depth-2.zip" }), "depth one does not visit grandchildren")
            let cappedDepth = try await SiteGrabber.preview(url: root + "/grab/level1.html", depth: 99, extensions: ["zip"])
            expect(cappedDepth.contains(where: { $0.url == root + "/depth-4.zip" }), "depth three includes the third nested page")
            expect(!cappedDepth.contains(where: { $0.url == root + "/depth-5.zip" }), "requested depth is capped at three")
            let redirected = try await SiteGrabber.preview(url: root + "/redirect-same", depth: 0, extensions: ["mp4"])
            expect(redirected.count == 2, "same-origin redirects resolve links against the final page")
            await rejected({ _ = try await SiteGrabber.preview(url: root + "/outside", depth: 0, extensions: ["zip"]) }, "outside-origin redirects are rejected")
            await rejected({ _ = try await SiteGrabber.preview(url: root + "/oversize", depth: 0, extensions: ["zip"]) }, "advertised pages larger than 2 MiB are rejected")
            await rejected({ _ = try await SiteGrabber.preview(url: root + "/oversize-stream", depth: 0, extensions: ["zip"]) }, "streamed pages larger than 2 MiB are rejected")
            let resources = try await SiteGrabber.preview(url: root + "/many-resources", depth: 3, extensions: ["zip"])
            expect(resources.count == 500, "resource results are capped at 500")
            let pages = try await SiteGrabber.preview(url: root + "/many-pages", depth: 3, extensions: ["zip"])
            expect(pages.count == 49, "crawl visits at most 50 pages including the root")
            let (statsData, _) = try await URLSession.shared.data(from: URL(string: root + "/stats")!)
            let stats = try JSONSerialization.jsonObject(with: statsData) as! [String: Any]
            expect((stats["foreign"] as? [String: Int])?.isEmpty == true, "neither links nor redirects contact the other origin")
        }
        if ["all", "media"].contains(mode) {
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
            var request = DownloadRequest(urls: [root + "/media/stream.m3u8?private=source-secret"])
            request.kind = .media
            request.headers = ["Cookie": "fixture=secret", "Referer": "https://fixture.invalid/private"]
            request.username = "fixture-user"; request.password = "fixture-password"
            request.connections = 1
            let filename = "literal-%(title)s-100%.mp4"
            let job = DownloadJob(request: request, filename: filename, directory: state.path, categoryID: "video")
            let seen = Observations()
            let worker = MediaWorker(job: job, stateDirectory: state, onProgress: seen.record, onExit: seen.finish)
            do { try worker.start() } catch { expect(false, "media worker starts: \(error.localizedDescription)"); exit(1) }
            let mediaRuns = state.appendingPathComponent("media")
            let runFiles = try FileManager.default.contentsOfDirectory(at: mediaRuns, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("run-") }
            let privateFiles = try runFiles.flatMap { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
            expect(privateFiles.allSatisfy { ((try? FileManager.default.attributesOfItem(atPath: $0.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o077 == 0 }, "configuration, cookie and log files have no group or world permissions")
            let ps = Process(); ps.executableURL = URL(fileURLWithPath: "/bin/ps"); ps.arguments = ["-eo", "args"]
            let psPipe = Pipe(); ps.standardOutput = psPipe; ps.standardError = FileHandle.nullDevice
            try ps.run(); let processList = String(decoding: psPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); ps.waitUntilExit()
            let workerCommands = processList.split(separator: "\n").filter { $0.contains("--config-locations") && $0.contains(state.path) }
            expect(!workerCommands.isEmpty && workerCommands.allSatisfy { !$0.contains("source-secret") && !$0.contains("fixture=secret") && !$0.contains("fixture.invalid") && !$0.contains("fixture-user") && !$0.contains("fixture-password") }, "yt-dlp process arguments contain no URLs, passwords or session headers")
            let began = Date()
            while seen.snapshot().1 == nil && Date().timeIntervalSince(began) < 45 { try await Task.sleep(nanoseconds: 100_000_000) }
            if seen.snapshot().1 == nil { worker.cancel() }
            let (progress, outcome) = seen.snapshot()
            expect(outcome?.0 == 0, "real HLS download exits successfully: \(outcome?.1 ?? "timed out")")
            expect(progress.contains(where: { $0.completedBytes > 0 && $0.bytesPerSecond > 0 }), "native media progress reports bytes and speed")
            expect(FileManager.default.fileExists(atPath: job.fileURL.path), "media output uses the exact literal destination filename")
            let probe = Process(); probe.executableURL = ToolLocator.find("ffprobe")
            probe.arguments = ["-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", job.fileURL.path]
            let pipe = Pipe(); probe.standardOutput = pipe; probe.standardError = FileHandle.nullDevice
            try probe.run(); let durationData = pipe.fileHandleForReading.readDataToEndOfFile(); probe.waitUntilExit()
            let duration = Double(String(decoding: durationData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            expect(probe.terminationStatus == 0 && duration >= 15.9, "downloaded media contains the full independently probed 16-second fixture")
            let cancellationJob = DownloadJob(request: request, filename: "paused.mp4", directory: state.path, categoryID: "video")
            let cancellation = Observations()
            let interrupted = MediaWorker(job: cancellationJob, stateDirectory: state, onProgress: cancellation.record, onExit: cancellation.finish)
            try interrupted.start()
            let cancelStart = Date()
            while !cancellation.snapshot().0.contains(where: { $0.completedBytes > 0 }) && Date().timeIntervalSince(cancelStart) < 10 { try await Task.sleep(nanoseconds: 50_000_000) }
            interrupted.cancel()
            while cancellation.snapshot().1 == nil && Date().timeIntervalSince(cancelStart) < 15 { try await Task.sleep(nanoseconds: 50_000_000) }
            expect(cancellation.snapshot().1?.0 != 0 && cancellation.snapshot().1 != nil, "cancel reports a non-success exit")
            let stage = try stageDirectory(cancellationJob, state: state)
            let files = try FileManager.default.contentsOfDirectory(atPath: stage.path)
            expect(files.contains(where: { $0.contains(".part") || $0.hasSuffix(".ytdl") }), "cancel retains native partial/resume files inside private staging")
            expect(!FileManager.default.fileExists(atPath: cancellationJob.fileURL.path + ".part"), "native media partials never appear next to the destination")
            let resumed = Observations()
            let resumedWorker = MediaWorker(job: cancellationJob, stateDirectory: state, onProgress: resumed.record, onExit: resumed.finish)
            try resumedWorker.start()
            let resumeStart = Date()
            while resumed.snapshot().1 == nil && Date().timeIntervalSince(resumeStart) < 45 { try await Task.sleep(nanoseconds: 100_000_000) }
            if resumed.snapshot().1 == nil { resumedWorker.cancel() }
            expect(resumed.snapshot().1?.0 == 0 && FileManager.default.fileExists(atPath: cancellationJob.fileURL.path), "a new worker resumes the retained partial to completion")
            var dashRequest = request; dashRequest.urls = [root + "/media/manifest.mpd"]
            let dashJob = DownloadJob(request: dashRequest, filename: "merged.unknown", directory: state.path, categoryID: "video")
            let dash = Observations()
            let dashWorker = MediaWorker(job: dashJob, stateDirectory: state, onProgress: dash.record, onExit: dash.finish)
            try dashWorker.start()
            let dashStart = Date()
            while dash.snapshot().1 == nil && Date().timeIntervalSince(dashStart) < 45 { try await Task.sleep(nanoseconds: 100_000_000) }
            if dash.snapshot().1 == nil { dashWorker.cancel() }
            expect(dash.snapshot().1?.0 == 0 && FileManager.default.fileExists(atPath: dashJob.fileURL.path), "DASH separate audio/video merge uses the exact requested filename with an arbitrary extension: \(dash.snapshot().1?.1 ?? "timed out")")
            let dashProbe = Process(); dashProbe.executableURL = ToolLocator.find("ffprobe")
            dashProbe.arguments = ["-v", "error", "-show_entries", "stream=codec_type", "-of", "json", dashJob.fileURL.path]
            let dashPipe = Pipe(); dashProbe.standardOutput = dashPipe; dashProbe.standardError = FileHandle.nullDevice
            try dashProbe.run(); let dashData = dashPipe.fileHandleForReading.readDataToEndOfFile(); dashProbe.waitUntilExit()
            let dashStreams = ((try? JSONSerialization.jsonObject(with: dashData)) as? [String: Any])?["streams"] as? [[String: String]] ?? []
            expect(dashStreams.contains(where: { $0["codec_type"] == "video" }) && dashStreams.contains(where: { $0["codec_type"] == "audio" }), "merged DASH output contains both independent video and audio streams")
            let sibling = state.appendingPathComponent("sibling.unknown.mp4")
            try Data("unrelated-existing-file".utf8).write(to: sibling)
            let siblingJob = DownloadJob(request: dashRequest, filename: "sibling.unknown", directory: state.path, categoryID: "video")
            let siblingWorker = MediaWorker(job: siblingJob, stateDirectory: state, onProgress: { _ in }, onExit: { _, _ in })
            do { try siblingWorker.start(); siblingWorker.cancel(); expect(false, "media worker refuses an existing merger-output collision") } catch { expect(true, "media worker refuses an existing merger-output collision") }
            expect(try Data(contentsOf: sibling) == Data("unrelated-existing-file".utf8), "unrelated merger sibling remains byte-identical")
            var deniedRequest = request; deniedRequest.headers = [:]
            let deniedJob = DownloadJob(request: deniedRequest, filename: "denied.mp4", directory: state.path, categoryID: "video")
            let denied = Observations()
            let deniedWorker = MediaWorker(job: deniedJob, stateDirectory: state, onProgress: denied.record, onExit: denied.finish)
            try deniedWorker.start()
            let deniedStart = Date()
            while denied.snapshot().1 == nil && Date().timeIntervalSince(deniedStart) < 20 { try await Task.sleep(nanoseconds: 100_000_000) }
            expect(denied.snapshot().1?.0 != 0 && denied.snapshot().1 != nil, "HTTP access denial reports failure")
            let message = denied.snapshot().1?.1 ?? ""
            expect(!message.contains("source-secret") && !message.contains("fixture=secret") && !message.contains("127.0.0.1"), "failure text does not expose source URLs or credentials")
            let collision = Observations()
            let collisionWorker = MediaWorker(job: job, stateDirectory: state, onProgress: collision.record, onExit: collision.finish)
            do { try collisionWorker.start(); expect(false, "existing final destination must not be overwritten") } catch { expect(true, "existing final destination must not be overwritten") }
        }
        if ["all", "symlink"].contains(mode) {
            let downloads = state.appendingPathComponent("unsafe-downloads")
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            for source in ["stream.m3u8", "manifest.mpd"] {
                var request = DownloadRequest(urls: [root + "/media/" + source]); request.kind = .media
                request.headers = ["Cookie": "fixture=secret", "Referer": "https://fixture.invalid/private"]; request.connections = 1
                let job = DownloadJob(request: request, filename: source + ".mp4", directory: downloads.path, categoryID: "video")
                let original = Data(String(repeating: "UNRELATED-LOCAL-FILE-", count: 100).utf8)
                let suffixes = source.hasSuffix("m3u8") ? [".part"] : [".f137.mp4.part", ".f0.mp4.part", ".f1.m4a.part", ".ytdl", ".part.ytdl"]
                var protected: [(URL, URL)] = []
                for (index, suffix) in suffixes.enumerated() {
                    let sentinel = state.appendingPathComponent(source + "-unrelated-\(index).txt")
                    try original.write(to: sentinel)
                    let link = URL(fileURLWithPath: job.fileURL.path + suffix)
                    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sentinel)
                    protected.append((sentinel, link))
                }
                let seen = Observations()
                let worker = MediaWorker(job: job, stateDirectory: state, onProgress: seen.record, onExit: seen.finish)
                try worker.start()
                let began = Date()
                while seen.snapshot().1 == nil && Date().timeIntervalSince(began) < 45 { try await Task.sleep(nanoseconds: 100_000_000) }
                if seen.snapshot().1 == nil { _ = try await worker.cancelAndWait() }
                expect(seen.snapshot().1?.0 == 0 && FileManager.default.fileExists(atPath: job.fileURL.path), "media succeeds while unrelated destination sidecars exist")
                for (sentinel, link) in protected {
                    expect((try? Data(contentsOf: sentinel)) == original, "media never overwrites a symlink target outside private staging")
                    expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == sentinel.path, "media leaves unrelated destination sidecar symlinks untouched")
                }
            }
        }
        if ["all", "stage-security"].contains(mode) {
            var request = DownloadRequest(urls: [root + "/media/stream.m3u8"]); request.kind = .media
            request.headers = ["Cookie": "fixture=secret", "Referer": "https://fixture.invalid/private"]; request.connections = 1
            let job = DownloadJob(request: request, filename: "unsafe-resume.mp4", directory: state.path, categoryID: "video")
            let seen = Observations()
            let worker = MediaWorker(job: job, stateDirectory: state, onProgress: seen.record, onExit: seen.finish)
            try worker.start()
            let began = Date()
            while !seen.snapshot().0.contains(where: { $0.completedBytes > 0 }) && Date().timeIntervalSince(began) < 10 { try await Task.sleep(nanoseconds: 50_000_000) }
            _ = try await worker.cancelAndWait()
            let stage = try stageDirectory(job, state: state)
            let permissions = try FileManager.default.attributesOfItem(atPath: stage.path)[.posixPermissions] as? NSNumber
            expect(permissions?.intValue == 0o700, "persistent staging directory is private")
            let unrelated = state.appendingPathComponent("resume-unrelated.txt")
            let original = Data("unrelated-private-stage-target".utf8); try original.write(to: unrelated)
            let part = stage.appendingPathComponent("payload.mp4.part")
            if FileManager.default.fileExists(atPath: part.path) { try FileManager.default.removeItem(at: part) }
            try FileManager.default.createSymbolicLink(at: part, withDestinationURL: unrelated)
            let unsafe = MediaWorker(job: job, stateDirectory: state, onProgress: { _ in }, onExit: { _, _ in })
            do { try unsafe.start(); expect(false, "resume refuses a symbolic-link artifact inside staging") } catch { expect(true, "resume refuses a symbolic-link artifact inside staging") }
            expect((try? Data(contentsOf: unrelated)) == original, "unsafe staged symlink target remains unchanged")
            try FileManager.default.removeItem(at: part)
            expect(Darwin.link(unrelated.path, part.path) == 0, "hard-link resume fixture is created")
            let hardlink = MediaWorker(job: job, stateDirectory: state, onProgress: { _ in }, onExit: { _, _ in })
            do { try hardlink.start(); expect(false, "resume refuses a multiply-linked artifact inside staging") } catch { expect(true, "resume refuses a multiply-linked artifact inside staging") }
            try FileManager.default.removeItem(at: part)
            let moved = stage.appendingPathExtension("saved")
            try FileManager.default.moveItem(at: stage, to: moved)
            try FileManager.default.createSymbolicLink(at: stage, withDestinationURL: state)
            let directoryLink = MediaWorker(job: job, stateDirectory: state, onProgress: { _ in }, onExit: { _, _ in })
            do { try directoryLink.start(); expect(false, "resume refuses a symbolic-link staging directory") } catch { expect(true, "resume refuses a symbolic-link staging directory") }
            expect((try? Data(contentsOf: unrelated)) == original, "unsafe staging directory never changes unrelated files")
            try FileManager.default.removeItem(at: stage); try FileManager.default.moveItem(at: moved, to: stage)
            var refreshed = job; refreshed.request.urls = [root + "/media/stream.m3u8?refreshed-source=1"]
            let freshSeen = Observations()
            let fresh = MediaWorker(job: refreshed, stateDirectory: state, onProgress: freshSeen.record, onExit: freshSeen.finish)
            try fresh.start()
            let stageRoot = stage.deletingLastPathComponent()
            let stages = try FileManager.default.contentsOfDirectory(at: stageRoot, includingPropertiesForKeys: nil)
            expect(stages.count == 2, "refresh uses a distinct private stage while preserving the old source's resume state")
            _ = try await fresh.cancelAndWait()
            let otherJob = stageRoot.deletingLastPathComponent().appendingPathComponent(UUID().uuidString.lowercased())
            try FileManager.default.createDirectory(at: otherJob, withIntermediateDirectories: true)
            let otherFile = otherJob.appendingPathComponent("another-job.part"); try original.write(to: otherFile)
            try FileManager.default.createSymbolicLink(at: stage.appendingPathComponent("malicious-stage-link"), withDestinationURL: state)
            try MediaWorker.discardStaging(jobID: job.id, stateDirectory: state)
            expect(!FileManager.default.fileExists(atPath: stageRoot.path), "discard removes this job's persistent partial staging")
            expect((try? Data(contentsOf: unrelated)) == original && (try? Data(contentsOf: otherFile)) == original, "discard never follows stage symlinks or removes another job's data")
            try MediaWorker.discardStaging(jobID: job.id, stateDirectory: state)
            do { try MediaWorker.discardStaging(jobID: "../../outside", stateDirectory: state); expect(false, "discard rejects a non-UUID path") } catch { expect(true, "discard rejects a non-UUID path") }
        }
        if ["all", "tree", "await-tree"].contains(mode) {
            let tool = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tests/media_grabber_tree.py")
            let originalTool = ProcessInfo.processInfo.environment["CURRENT_YT_DLP"]
            setenv("CURRENT_YT_DLP", tool.path, 1)
            var request = DownloadRequest(urls: ["https://fixture.invalid/media"]); request.kind = .media
            let treeJob = DownloadJob(request: request, filename: "tree", directory: state.path, categoryID: "video")
            let observation = Observations()
            let worker = MediaWorker(job: treeJob, stateDirectory: state, onProgress: observation.record, onExit: observation.finish)
            try worker.start()
            let stage = try stageDirectory(treeJob, state: state)
            let heartbeat = stage.appendingPathComponent("payload.heartbeat")
            let childPIDFile = stage.appendingPathComponent("payload.childpid")
            let started = Date()
            while !FileManager.default.fileExists(atPath: heartbeat.path) && Date().timeIntervalSince(started) < 5 { try await Task.sleep(nanoseconds: 50_000_000) }
            expect(FileManager.default.fileExists(atPath: heartbeat.path), "process-tree fixture is running before cancellation")
            let awaitedCode: Int32?
            if mode == "await-tree" { awaitedCode = try await worker.cancelAndWait() }
            else { worker.cancel(); awaitedCode = nil }
            let exitedAtReturn = observation.snapshot().1 != nil
            let cancelled = Date()
            while observation.snapshot().1 == nil && Date().timeIntervalSince(cancelled) < 8 { try await Task.sleep(nanoseconds: 50_000_000) }
            let firstHeartbeat = try? String(contentsOf: heartbeat, encoding: .utf8)
            try await Task.sleep(nanoseconds: 400_000_000)
            let secondHeartbeat = try? String(contentsOf: heartbeat, encoding: .utf8)
            expect(observation.snapshot().1 != nil && firstHeartbeat != nil && firstHeartbeat == secondHeartbeat, "cancel halts surviving child processes before reporting exit")
            if mode == "await-tree" {
                expect(awaitedCode != nil && awaitedCode != 0 && exitedAtReturn, "cancelAndWait returns the final non-success outcome after group cleanup")
                expect(try noPrivateRuns(state), "cancelAndWait returns after private media credential/log files are removed")
            }
            if let raw = try? String(contentsOf: childPIDFile, encoding: .utf8), let child = Int32(raw) { Darwin.kill(child, SIGKILL) }
            if let originalTool { setenv("CURRENT_YT_DLP", originalTool, 1) } else { unsetenv("CURRENT_YT_DLP") }
        }
        if ["all", "race", "timeout"].contains(mode) {
            let tool = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tests/media_grabber_race.py")
            let originalTool = ProcessInfo.processInfo.environment["CURRENT_YT_DLP"]
            setenv("CURRENT_YT_DLP", tool.path, 1)
            for outcome in mode == "timeout" ? ["timeout"] : ["success", "failure", "collision", "dangling"] {
                var request = DownloadRequest(urls: ["https://fixture.invalid/" + (outcome == "failure" ? "failure" : "success")]); request.kind = .media
                let job = DownloadJob(request: request, filename: outcome + ".unknown", directory: state.path, categoryID: "video")
                let observation = Observations()
                let processing = DispatchSemaphore(value: 0)
                let released = Observations()
                let worker = MediaWorker(job: job, stateDirectory: state, onProgress: { value in
                    observation.record(value)
                    if value.completedBytes == 1 { processing.wait() }
                }, onExit: observation.finish)
                try worker.start()
                let stage = try stageDirectory(job, state: state)
                let sentinel = Data("unrelated-destination".utf8)
                let missing = state.appendingPathComponent("missing-target")
                if outcome == "collision" { try sentinel.write(to: job.fileURL) }
                if outcome == "dangling" { try FileManager.default.createSymbolicLink(at: job.fileURL, withDestinationURL: missing) }
                let began = Date()
                while observation.snapshot().0.isEmpty && Date().timeIntervalSince(began) < 5 { try await Task.sleep(nanoseconds: 20_000_000) }
                try Data().write(to: stage.appendingPathComponent("payload.unknown.release"))
                let ready = stage.appendingPathComponent("payload.unknown.ready")
                while !FileManager.default.fileExists(atPath: ready.path) && Date().timeIntervalSince(began) < 5 { try await Task.sleep(nanoseconds: 20_000_000) }
                if let raw = try? String(contentsOf: ready, encoding: .utf8), let child = Int32(raw) {
                    while Darwin.kill(child, 0) == 0 && Date().timeIntervalSince(began) < 5 { try await Task.sleep(nanoseconds: 20_000_000) }
                }
                let wait = Task { () throws -> Int32 in
                    let code = try await worker.cancelAndWait()
                    released.finish(code, "")
                    return code
                }
                if outcome == "timeout" {
                    do { _ = try await wait.value; expect(false, "blocked cleanup returns an actionable timeout") }
                    catch { expect(error.localizedDescription.lowercased().contains("stop") && Date().timeIntervalSince(began) < 10, "blocked cleanup returns an actionable timeout within about eight seconds") }
                    processing.signal()
                    _ = try await worker.cancelAndWait()
                } else {
                    try await Task.sleep(nanoseconds: 150_000_000)
                    expect(released.snapshot().1 == nil, "cancelAndWait waits while final normalization is pending")
                    processing.signal()
                    let code = try await wait.value
                    expect((code == 0) == (outcome == "success"), "cancelAndWait preserves the actual finalized exit outcome when completion races with cancel")
                    expect((observation.snapshot().1?.0 == 0) == (outcome == "success"), "onExit agrees with cancelAndWait after a completion/cancel race")
                    if outcome == "success" {
                        expect((try? Data(contentsOf: job.fileURL)) == Data("complete-media-fixture".utf8), "successful racing completion is normalized to the exact final filename")
                        var info = stat(); let exists = lstat(job.fileURL.path, &info) == 0
                        let identity = worker.completedFileIdentity()
                        expect(exists && identity?.device == UInt64(UInt32(bitPattern: info.st_dev)) && identity?.inode == UInt64(info.st_ino), "worker publishes the identity of its exclusively committed output")
                        let before = identity
                        try FileManager.default.moveItem(at: job.fileURL, to: job.fileURL.appendingPathExtension("saved"))
                        try Data("replacement-file".utf8).write(to: job.fileURL)
                        let retained = worker.completedFileIdentity()
                        expect(retained?.device == before?.device && retained?.inode == before?.inode, "worker never adopts a replacement destination after committing")
                    } else if outcome == "collision" {
                        expect((try? Data(contentsOf: job.fileURL)) == sentinel, "exclusive final commit preserves a destination created after the download started")
                    } else if outcome == "dangling" {
                        expect((try? FileManager.default.destinationOfSymbolicLink(atPath: job.fileURL.path)) == missing.path && !FileManager.default.fileExists(atPath: missing.path), "exclusive final commit preserves a dangling destination symlink")
                    } else { expect(!FileManager.default.fileExists(atPath: job.fileURL.path), "failed racing completion does not promote its incomplete output") }
                    expect(try noPrivateRuns(state), "awaited completion has removed all private media credential/log files")
                }
            }
            if let originalTool { setenv("CURRENT_YT_DLP", originalTool, 1) } else { unsetenv("CURRENT_YT_DLP") }
        }
        print("Media/grabber checks: \(assertions) assertions, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
