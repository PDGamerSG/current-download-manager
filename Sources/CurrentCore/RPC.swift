import Foundation

public final class Aria2Engine {
    private var process: Process?
    private let secret = ToolLocator.randomSecret()
    private var port: UInt16 = 0
    private let store: StateStore
    private let session: URLSession
    private var defaultUserAgent = "aria2"
    public init(store: StateStore) {
        self.store = store
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 8; config.connectionProxyDictionary = [:]
        session = URLSession(configuration:config)
    }
    public var isRunning: Bool { process?.isRunning ?? false }
    public func start(settings: AppSettings, cookieJar: String = "# Netscape HTTP Cookie File\n") async throws {
        guard let binary = ToolLocator.find("aria2c") else { throw CurrentError.invalid("aria2c is missing. Install aria2 with Homebrew or use the bundled Current app.") }
        port = try ToolLocator.freePort()
        try store.write(Data(cookieJar.utf8),name:"cookies.txt")
        var lines = [
            "enable-rpc=true", "rpc-listen-all=false", "rpc-listen-port=\(port)", "rpc-secret=\(secret)", "rpc-allow-origin-all=false",
            "disable-ipv6=true", "file-allocation=none", "continue=true", "always-resume=true", "auto-file-renaming=false", "allow-overwrite=false",
            "max-concurrent-downloads=\(settings.maxConcurrent)", "max-overall-download-limit=\(settings.speedLimit)",
            "max-connection-per-server=16", "split=8", "min-split-size=1M", "stream-piece-selector=geom", "max-tries=5", "retry-wait=1",
            "connect-timeout=15", "timeout=30", "auto-save-interval=1", "force-save=true", "summary-interval=0", "console-log-level=warn",
            "enable-color=false", "check-certificate=true", "http-accept-gzip=false", "download-result=hide", "max-download-result=2000",
            "follow-metalink=false", "follow-torrent=false", "load-cookies=\(store.directory.appendingPathComponent("cookies.txt").path)"
        ]
        // Use the operating system's CA bundle, independent of a build machine's
        // Homebrew OpenSSL configuration directory.
        if FileManager.default.fileExists(atPath:"/etc/ssl/cert.pem") { lines.append("ca-certificate=/etc/ssl/cert.pem") }
        try store.write(Data((lines.joined(separator:"\n")+"\n").utf8),name:"aria2.conf")
        let logURL = store.directory.appendingPathComponent("engine.log")
        if !FileManager.default.fileExists(atPath:logURL.path) { try store.write(Data(),name:"engine.log") }
        let log = try FileHandle(forWritingTo:logURL); try log.truncate(atOffset:0)
        let child = Process(); child.executableURL = binary
        child.arguments = ["--conf-path=\(store.directory.appendingPathComponent("aria2.conf").path)", "--stop-with-process=\(getpid())"]
        child.standardOutput = log; child.standardError = log; child.standardInput = FileHandle.nullDevice
        try child.run(); process = child
        for _ in 0..<60 {
            guard child.isRunning else { throw CurrentError.invalid("aria2 could not start. Inspect the private engine.log in Application Support/Current.") }
            if (try? await call("getVersion")) != nil {
                if let options = try? await call("getGlobalOption"), !options["user-agent"].string.isEmpty {
                    defaultUserAgent = options["user-agent"].string
                }
                return
            }
            try await Task.sleep(nanoseconds:100_000_000)
        }
        child.terminate(); throw CurrentError.invalid("Timed out starting the download engine.")
    }
    public func call(_ method: String, _ params: [JSONValue] = []) async throws -> JSONValue {
        var request = URLRequest(url:URL(string:"http://127.0.0.1:\(port)/jsonrpc")!)
        request.httpMethod = "POST"; request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.httpBody = try JSONEncoder.current.encode(JSONValue.object([
            "jsonrpc":.string("2.0"),"id":.string(UUID().uuidString),"method":.string("aria2."+method),"params":.array([.string("token:"+secret)]+params)
        ]))
        let (data,response) = try await session.data(for:request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CurrentError.invalid("The download engine rejected the request.") }
        let value = try JSONDecoder.current.decode(JSONValue.self,from:data)
        if value.object["error"] != nil { throw CurrentError.invalid(value["error"]["message"].string) }
        return value["result"]
    }
    /// Options that can also be applied to already admitted downloads after a settings change.
    public func requestOptions(for job: DownloadJob, settings: AppSettings) throws -> [String: JSONValue] {
        try settings.validateNetworkPolicy()
        let request = job.request
        // aria2 applies one connection limit to every source of a mirrored job.
        // Choosing the strictest matching rule respects every supplied server.
        let caps = request.urls.compactMap(URL.init(string:)).compactMap { settings.connectionLimit(for: $0) }
        let connections = min(request.connections, caps.min() ?? request.connections)
        let explicitAgent = request.headers.first { $0.key.lowercased() == "user-agent" }?.value
        let configuredAgent = settings.userAgent?.trimmingCharacters(in: .whitespaces)
        let agent = explicitAgent ?? (configuredAgent?.isEmpty == false ? configuredAgent! : defaultUserAgent)
        return [
            "split": .string(String(connections)), "max-connection-per-server": .string(String(connections)),
            "all-proxy": .string(settings.proxy), "user-agent": .string(agent)
        ]
    }

    public func add(_ job: DownloadJob, settings: AppSettings) async throws -> String {
        let r = job.request
        var options = try requestOptions(for: job, settings: settings)
        options["dir"] = .string(job.directory)
        options["out"] = .string(job.filename)
        options["pause"] = .string("true")
        options["max-download-limit"] = .string(String(r.speedLimit))
        options["header"] = .array(r.headers.filter { !["cookie", "user-agent"].contains($0.key.lowercased()) }.sorted(by: { $0.key < $1.key }).map { .string($0.key + ": " + $0.value) })
        if let checksum = r.checksum, !checksum.isEmpty { options["checksum"] = .string(checksum.lowercased()); options["check-integrity"] = .string("true") }
        // URL userinfo is origin-scoped by aria2's redirect resolver. Per-job
        // http-user/http-passwd options would be sent to redirected hosts too.
        let sources = r.urls.map { raw -> JSONValue in
            guard let user = r.username, !user.isEmpty, var c = URLComponents(string:raw), let first = r.urls.first.flatMap(URL.init(string:)), c.scheme == first.scheme, c.host == first.host, c.port == first.port else { return .string(raw) }
            c.user = user; c.password = r.password
            return .string(c.string ?? raw)
        }
        let gid = try await call("addUri",[.array(sources),.object(options)])
        return gid.string
    }
    public func statuses() async throws -> [String:JSONValue] {
        let active = try await call("tellActive").array
        let waiting = try await call("tellWaiting",[.number(0),.number(2000)]).array
        let stopped = try await call("tellStopped",[.number(0),.number(2000)]).array
        return Dictionary((active+waiting+stopped).map { ($0["gid"].string,$0) },uniquingKeysWith:{$1})
    }
    public func stop() async {
        _ = try? await call("forcePauseAll")
        _ = try? await call("shutdown")
        for _ in 0..<30 { if !isRunning { break }; try? await Task.sleep(nanoseconds:100_000_000) }
        if let process, process.isRunning { process.terminate() }
        process = nil
    }
    deinit { session.invalidateAndCancel(); if let process, process.isRunning { process.terminate() } }
}
