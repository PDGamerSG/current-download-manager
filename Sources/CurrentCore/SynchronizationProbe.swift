import Foundation

struct SynchronizationProbeResult {
    var changed: Bool
    var etag: String?
    var lastModified: String?
    var transferHeaders: [String:String] = [:]
}

/// Validators describe a previously verified version. Payload transfers still
/// go through aria2, so queue limits, quotas, scanning and recovery all apply.
enum SynchronizationProbe {
    static func supports(_ job: DownloadJob) -> Bool {
        job.request.kind == .file && job.request.urls.count == 1
            && job.request.urls.first.flatMap(URL.init(string:)).map { ["http", "https"].contains($0.scheme?.lowercased() ?? "") } == true
    }

    static func check(_ job: DownloadJob, settings: AppSettings) async throws -> SynchronizationProbeResult {
        try Task.checkCancellation()
        guard supports(job), let source = URL(string: job.request.urls[0]),
              var components = URLComponents(url: source, resolvingAgainstBaseURL: false) else {
            throw CurrentError.invalid("File updates require one HTTP or HTTPS source.")
        }
        let headers = job.request.headers.filter { ["user-agent", "accept-encoding"].contains($0.key.lowercased()) }
        func result(changed: Bool, etag: String? = nil, lastModified: String? = nil) -> SynchronizationProbeResult {
            SynchronizationProbeResult(changed: changed, etag: etag, lastModified: lastModified, transferHeaders: headers)
        }
        // A configured proxy remains authoritative. Use an ordinary proxied
        // transfer rather than letting a separate metadata request bypass it.
        if !settings.proxy.isEmpty { return result(changed: true) }
        let user = job.request.username ?? components.user
        let password = job.request.password ?? components.password ?? ""
        components.user = nil; components.password = nil; components.fragment = nil
        guard let url = components.url else { throw CurrentError.invalid("The update source is invalid.") }
        let guardDelegate = SynchronizationRedirectGuard(url)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 30
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil; config.urlCache = nil
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config, delegate: guardDelegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "HEAD"
        for (key, value) in job.request.headers where !conditionalHeaders.contains(key.lowercased()) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if request.value(forHTTPHeaderField: "User-Agent") == nil, let agent = settings.userAgent, !agent.isEmpty {
            request.setValue(agent, forHTTPHeaderField: "User-Agent")
        }
        if let user, !user.isEmpty { request.setValue("Basic " + Data("\(user):\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization") }
        let info = job.synchronization
        if let etag = try safeValidator(info?.etag) { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        else if let modified = try safeValidator(info?.lastModified) { request.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
        let (_, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw CurrentError.invalid("The server did not return HTTP update metadata.") }
        if http.statusCode == 304, info?.etag != nil || info?.lastModified != nil {
            return result(changed: false, etag: info?.etag, lastModified: info?.lastModified)
        }
        if [405, 501].contains(http.statusCode) { return result(changed: true) }
        guard http.statusCode == 200 else {
            if (300...399).contains(http.statusCode) { throw CurrentError.invalid("The update redirected to a different origin. Add the new source explicitly to keep credentials scoped.") }
            throw CurrentError.invalid("The update check failed (HTTP \(http.statusCode)). The existing version was kept.")
        }
        let etag = try safeValidator(http.value(forHTTPHeaderField: "ETag"))
        let modified = try safeValidator(http.value(forHTTPHeaderField: "Last-Modified"))
        var changed = true
        if let previous = info?.etag, let etag { changed = previous != etag }
        else if info?.etag == nil, let previous = info?.lastModified, let modified { changed = previous != modified }
        return result(changed: changed, etag: etag, lastModified: modified)
    }

    static let conditionalHeaders: Set<String> = ["range", "if-range", "if-match", "if-none-match", "if-modified-since", "if-unmodified-since"]
    private static func safeValidator(_ value: String?) throws -> String? {
        guard let value, !value.isEmpty else { return nil }
        guard value.utf8.count <= 4096, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw CurrentError.invalid("The server returned an invalid update validator. The existing version was kept.")
        }
        return value
    }
}

private final class SynchronizationRedirectGuard: NSObject, URLSessionTaskDelegate {
    private let source: URL
    init(_ source: URL) { self.source = source }
    private func origin(_ url: URL) -> String {
        "\(url.scheme?.lowercased() ?? "")://\(url.host?.lowercased() ?? ""):\(url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80))"
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let destination = request.url, destination.user == nil, destination.password == nil,
              origin(destination) == origin(source) else { completionHandler(nil); return }
        completionHandler(request)
    }
}
