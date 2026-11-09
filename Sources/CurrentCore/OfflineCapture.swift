import Foundation
import CryptoKit

enum OfflineURL {
    static func normalized(_ raw: String, relativeTo base: URL? = nil) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 8192,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let url = URL(string: text, relativeTo: base)?.absoluteURL,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host?.lowercased(), !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        parts.scheme = scheme; parts.host = host; parts.fragment = nil
        if parts.port == (scheme == "https" ? 443 : 80) { parts.port = nil }
        if parts.path.isEmpty { parts.path = "/" }
        return parts.url
    }
    static func sameOrigin(_ first: URL, _ second: URL) -> Bool {
        first.scheme?.lowercased() == second.scheme?.lowercased() && first.host?.lowercased() == second.host?.lowercased() &&
        (first.port ?? (first.scheme == "https" ? 443 : 80)) == (second.port ?? (second.scheme == "https" ? 443 : 80)) && second.user == nil && second.password == nil
    }
    static func isPage(_ url: URL) -> Bool {
        ["", "html", "htm", "xhtml", "php", "asp", "aspx", "jsp"].contains(url.pathExtension.lowercased())
    }
    static func matches(_ patterns: [String], url: URL) -> Bool {
        let path = url.path + (url.query.map { "?" + $0 } ?? "")
        return patterns.contains { pattern in
            let expression = "^" + NSRegularExpression.escapedPattern(for: pattern).replacingOccurrences(of: "\\*", with: ".*").replacingOccurrences(of: "\\?", with: ".") + "$"
            guard let regex = try? NSRegularExpression(pattern: expression) else { return false }
            return [path, url.absoluteString].contains { value in regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil }
        }
    }
}

struct OfflineCaptureResult {
    let directory: String
    let fileCount: Int
    let totalBytes: Int
}

private struct OfflineFetchedResource {
    let data: Data
    let url: URL
    let mime: String
}

enum OfflineWebsiteCapture {
    private struct Item {
        let requestedURL: URL
        let responseURL: URL
        let data: Data
        let kind: OfflineMarkup.Kind
        let path: String
    }
    static func run(_ project: WebsiteProject) async throws -> OfflineCaptureResult {
        guard let source = OfflineURL.normalized(project.sourceURL) else { throw CurrentError.invalid("The website source URL is invalid.") }
        let destination = try OfflineDirectory.open(URL(fileURLWithPath: project.destinationDirectory))
        guard destination.identity == project.destinationIdentity else {
            throw CurrentError.invalid("The website destination folder was moved or replaced. Current left it untouched; choose a new destination folder.")
        }
        let deadline = Date().addingTimeInterval(TimeInterval(project.maxDurationSeconds))
        var pending: [(URL, Int, Bool)] = [(source, 0, true)]
        var scheduled = Set([source.absoluteString])
        var items: [Item] = []
        var index = 0
        var downloadedBytes = 0
        while index < pending.count {
            try Task.checkCancellation()
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw CurrentError.invalid("The website capture exceeded its time limit. The previous snapshot is retained.") }
            let (url, depth, documentNavigation) = pending[index]
            let loader = OfflineResourceLoader(origin: source, headers: project.headers, maximumBytes: min(project.maxResourceBytes, project.maxTotalBytes - downloadedBytes), timeout: remaining)
            let response: OfflineFetchedResource
            do { response = try await loader.fetch(url) }
            catch { try Task.checkCancellation(); throw error }
            downloadedBytes += response.data.count
            guard downloadedBytes <= project.maxTotalBytes else { throw CurrentError.invalid("The website capture exceeds its total byte limit.") }
            let kind = OfflineMarkup.kind(mime: response.mime, url: response.url, data: response.data)
            if index == 0, kind != .html { throw CurrentError.invalid("Start the offline website project from an HTML page.") }
            let path = index == 0 ? "index.html" : filename(url: url, kind: kind, mime: response.mime)
            items.append(Item(requestedURL: url, responseURL: response.url, data: response.data, kind: kind, path: path))
            scheduled.insert(response.url.absoluteString)
            index += 1
            if kind == .binary || (kind == .html && !documentNavigation) { continue }
            let text = OfflineMarkup.text(response.data)
            let discovery = OfflineMarkup.references(in: text, kind: kind, base: response.url)
            for reference in discovery {
                guard let candidate = OfflineURL.normalized(reference.raw, relativeTo: reference.base), OfflineURL.sameOrigin(source, candidate),
                      !OfflineURL.matches(project.excludePatterns, url: candidate) else { continue }
                let navigation = reference.navigation && OfflineURL.isPage(candidate)
                if navigation {
                    guard project.mode == "site", depth < project.maxDepth,
                          project.includePatterns.isEmpty || OfflineURL.matches(project.includePatterns, url: candidate) else { continue }
                }
                guard !scheduled.contains(candidate.absoluteString) else { continue }
                guard pending.count < project.maxFiles else { throw CurrentError.invalid("The website capture exceeds its file limit. Increase the limit or narrow the URL filters.") }
                scheduled.insert(candidate.absoluteString)
                pending.append((candidate, navigation ? depth + 1 : depth, navigation))
            }
        }
        try Task.checkCancellation()
        guard Date() < deadline else { throw CurrentError.invalid("The website capture exceeded its time limit.") }
        var mapping: [String: String] = [:]
        for item in items { mapping[item.requestedURL.absoluteString] = item.path; mapping[item.responseURL.absoluteString] = item.path }
        var output: [(String, Data)] = []
        var outputBytes = 0
        for item in items {
            try Task.checkCancellation()
            let data: Data
            if item.kind == .binary { data = item.data }
            else { data = Data(OfflineMarkup.rewrite(OfflineMarkup.text(item.data), kind: item.kind, base: item.responseURL, mapping: mapping).utf8) }
            outputBytes += data.count
            guard outputBytes <= project.maxTotalBytes else { throw CurrentError.invalid("Rewritten offline resources exceed the project's total byte limit.") }
            output.append((item.path, data))
        }
        let resources: [JSONValue] = items.map { .object(["url": .string($0.requestedURL.absoluteString), "responseURL": .string($0.responseURL.absoluteString), "path": .string($0.path)]) }
        let manifest = try JSONEncoder.current.encode(JSONValue.object(["version": .number(1), "sourceURL": .string(source.absoluteString), "capturedAt": .string(ISO8601DateFormatter().string(from: Date())), "resources": .array(resources)]))
        output.append(("manifest.json", manifest))
        try destination.verifyPath()
        let snapshot = try destination.child("Current-" + project.id + "-" + UUID().uuidString.lowercased(), create: true)
        for (name, data) in output {
            try Task.checkCancellation()
            guard Date() < deadline else { throw CurrentError.invalid("The website capture exceeded its time limit while saving.") }
            try snapshot.writeExclusive(data, name: name)
        }
        // A disk/publication failure may leave an unreferenced private snapshot.
        // We never unlink output paths: even a concurrent replacement is safe.
        try destination.verifyPath(); try snapshot.verifyPath(); try Task.checkCancellation()
        return OfflineCaptureResult(directory: snapshot.url.path, fileCount: items.count, totalBytes: outputBytes)
    }

    private static func filename(url: URL, kind: OfflineMarkup.Kind, mime: String) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let ext: String
        switch kind {
        case .html: ext = "html"
        case .css: ext = "css"
        case .binary:
            let candidate = url.pathExtension.lowercased()
            if !candidate.isEmpty, candidate.count <= 12, candidate.allSatisfy({ $0.isASCII && $0.isLetter || $0.isNumber }) { ext = candidate }
            else { ext = ["image/png": "png", "image/jpeg": "jpg", "image/webp": "webp", "image/svg+xml": "svg", "video/mp4": "mp4", "font/woff2": "woff2"][mime] ?? "bin" }
        }
        return "resource-" + digest + "." + ext
    }
}

/// Streaming bounds apply after content decoding as well as to advertised sizes.
private final class OfflineResourceLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let origin: URL
    private let headers: [String: String]
    private let maximumBytes: Int
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var continuation: CheckedContinuation<OfflineFetchedResource, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var cancelled = false
    private var bytes = Data()
    private var response: HTTPURLResponse?
    private var redirects = 0
    init(origin: URL, headers: [String: String], maximumBytes: Int, timeout: TimeInterval) {
        self.origin = origin; self.headers = headers; self.maximumBytes = maximumBytes; self.timeout = max(0.1, timeout)
    }
    func fetch(_ url: URL) async throws -> OfflineFetchedResource {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !cancelled else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let configuration = URLSessionConfiguration.ephemeral
                configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.urlCache = nil
                configuration.timeoutIntervalForRequest = min(15, timeout); configuration.timeoutIntervalForResource = timeout
                configuration.httpMaximumConnectionsPerHost = 1
                let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                self.session = session
                var request = URLRequest(url: url)
                request.setValue("Current-OfflineWebsite/0.2", forHTTPHeaderField: "User-Agent")
                for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
                let task = session.dataTask(with: request); self.task = task
                lock.unlock(); task.resume()
            }
        }, onCancel: {
            self.lock.lock(); self.cancelled = true; self.lock.unlock()
            self.finish(.failure(CancellationError()))
        })
    }
    private func finish(_ result: Result<OfflineFetchedResource, Error>) {
        lock.lock()
        let continuation = self.continuation; self.continuation = nil
        let session = self.session; self.session = nil
        let task = self.task; self.task = nil
        lock.unlock()
        guard let continuation else { return }
        task?.cancel(); session?.invalidateAndCancel(); continuation.resume(with: result)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        guard let url = request.url, OfflineURL.sameOrigin(origin, url), redirects <= 10 else {
            completionHandler(nil); finish(.failure(CurrentError.invalid("A website redirect changed origin or exceeded the redirect limit; it was blocked."))); return
        }
        var scoped = request
        for (name, value) in headers { scoped.setValue(value, forHTTPHeaderField: name) }
        completionHandler(scoped)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, let url = response.url, OfflineURL.sameOrigin(origin, url), (200...299).contains(http.statusCode) else {
            completionHandler(.cancel); finish(.failure(CurrentError.invalid("A website resource did not return a successful HTTP response. The previous snapshot is retained."))); return
        }
        guard maximumBytes >= 0, response.expectedContentLength <= Int64(maximumBytes) else {
            completionHandler(.cancel); finish(.failure(CurrentError.invalid("A website resource exceeds the project's byte limit."))); return
        }
        self.response = http; completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard data.count <= maximumBytes, bytes.count <= maximumBytes - data.count else {
            finish(.failure(CurrentError.invalid("A streamed website resource exceeds the project's byte limit."))); return
        }
        bytes.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil { finish(.failure(CurrentError.invalid("A website resource could not be loaded before its timeout. Check the connection and source URL."))) }
        else if let response, let raw = response.url, let url = OfflineURL.normalized(raw.absoluteString) { finish(.success(OfflineFetchedResource(data: bytes, url: url, mime: response.mimeType?.lowercased() ?? ""))) }
        else { finish(.failure(CurrentError.invalid("The website returned an invalid response."))) }
    }
}
