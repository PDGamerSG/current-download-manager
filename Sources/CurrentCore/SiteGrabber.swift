import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct GrabbedLink: Codable, Identifiable {
    public let url: String
    public var id: String { url }
    public let filename: String
    public init(url: String, filename: String) { self.url = url; self.filename = filename }
}

public enum SiteGrabber {
    public static func preview(url: String, depth: Int, extensions: [String]) async throws -> [GrabbedLink] {
        guard let start = normalizedURL(url), let origin = GrabberOrigin(start) else {
            throw CurrentError.invalid("Enter an HTTP or HTTPS page URL without embedded credentials.")
        }
        let allowed = Set(extensions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() }.filter { !$0.isEmpty })
        let maximumDepth = min(3, max(0, depth))
        let started = Date()
        var pending: [(URL, Int)] = [(start, 0)]
        var scheduled = Set([start.absoluteString])
        var found = Set<String>()
        var result: [GrabbedLink] = []
        var pageIndex = 0
        while pageIndex < pending.count, pageIndex < 50, result.count < 500 {
            try Task.checkCancellation()
            guard Date().timeIntervalSince(started) < 60 else { break }
            let (page, currentDepth) = pending[pageIndex]
            pageIndex += 1
            let response: GrabberPage
            do { response = try await GrabberPageLoader(origin: origin).fetch(page) }
            catch {
                try Task.checkCancellation()
                if pageIndex == 1 { throw error }
                continue
            }
            let tags = HTMLLinkScanner.tags(in: response.data)
            var base = response.url
            if let raw = tags.first(where: { $0.name == "base" })?.attributes["href"],
               let resolved = normalizedURL(raw, relativeTo: response.url) { base = resolved }
            for element in tags {
                let tag = element.name
                guard !["base", "script", "style"].contains(tag) else { continue }
                for attribute in ["href", "src", "poster", "data-src"] {
                    guard let raw = element.attributes[attribute],
                          let candidate = normalizedURL(raw, relativeTo: base), origin.contains(candidate) else { continue }
                    let ext = candidate.pathExtension.lowercased()
                    let isPage = ["", "html", "htm", "xhtml", "php", "asp", "aspx", "jsp"].contains(ext)
                    if (!allowed.isEmpty && allowed.contains(ext)) || (allowed.isEmpty && !isPage) {
                        if found.insert(candidate.absoluteString).inserted {
                            result.append(GrabbedLink(url: candidate.absoluteString, filename: safeFilename(candidate)))
                            if result.count == 500 { break }
                        }
                    } else if isPage, currentDepth < maximumDepth, pending.count < 50,
                              ["a", "area", "iframe", "frame"].contains(tag),
                              scheduled.insert(candidate.absoluteString).inserted {
                        pending.append((candidate, currentDepth + 1))
                    }
                }
                if result.count == 500 { break }
            }
        }
        return result
    }

    private static func normalizedURL(_ raw: String, relativeTo base: URL? = nil) -> URL? {
        let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, raw.utf8.count <= 8192,
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let resolved = URL(string: raw, relativeTo: base)?.absoluteURL,
              var components = URLComponents(url: resolved, resolvingAgainstBaseURL: true),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        components.scheme = scheme
        components.host = host
        components.fragment = nil
        if components.port == (scheme == "https" ? 443 : 80) { components.port = nil }
        if components.path.isEmpty { components.path = "/" }
        return components.url
    }

    private static func safeFilename(_ url: URL) -> String {
        let leaf = url.lastPathComponent
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        let cleaned = String(String.UnicodeScalarView(leaf.unicodeScalars.map { forbidden.contains($0) ? "_" : $0 }))
        let limited = String(cleaned.prefix(180))
        return limited.isEmpty || limited == "." || limited == ".." ? "download" : limited
    }
}

private enum HTMLLinkScanner {
    struct Tag { let name: String; let attributes: [String: String] }
    // Quote-aware tag scanning preserves HTML5 audio/video/source elements that macOS's HTML tidy parser drops.
    private static let tagsPattern = try! NSRegularExpression(pattern: #"<!--[\s\S]*?(?:-->|$)|<(script|style)\b(?:\"[^\"]*\"|'[^']*'|[^'\">])*?>(?:[\s\S]*?</\1\s*>|[\s\S]*$)|<([a-z][a-z0-9:-]*)\b(?:\"[^\"]*\"|'[^']*'|[^'\">])*?>"#, options: [.caseInsensitive])
    private static let attributesPattern = try! NSRegularExpression(pattern: #"([a-z_:][a-z0-9_:.-]*)\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s\"'=<>`]+))"#, options: [.caseInsensitive])

    static func tags(in data: Data) -> [Tag] {
        let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let source = html as NSString
        return tagsPattern.matches(in: html, range: NSRange(location: 0, length: source.length)).compactMap { match in
            guard match.range(at: 2).location != NSNotFound else { return nil }
            let name = source.substring(with: match.range(at: 2)).lowercased()
            let rawTag = source.substring(with: match.range) as NSString
            var attributes: [String: String] = [:]
            for attribute in attributesPattern.matches(in: rawTag as String, range: NSRange(location: 0, length: rawTag.length)) {
                let key = rawTag.substring(with: attribute.range(at: 1)).lowercased()
                guard ["href", "src", "poster", "data-src"].contains(key), attributes[key] == nil else { continue }
                guard let valueRange = (2...4).map({ attribute.range(at: $0) }).first(where: { $0.location != NSNotFound }), valueRange.length <= 8192 else { continue }
                attributes[key] = decodeEntities(rawTag.substring(with: valueRange))
            }
            return attributes.isEmpty ? nil : Tag(name: name, attributes: attributes)
        }
    }

    private static func decodeEntities(_ value: String) -> String {
        guard value.contains("&") else { return value }
        let escaped = value.replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;")
        guard let document = try? XMLDocument(xmlString: "<html><body><p title=\"\(escaped)\"></p></body></html>", options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]),
              let element = try? document.nodes(forXPath: "//p").first as? XMLElement,
              let decoded = element.attribute(forName: "title")?.stringValue else { return value }
        return decoded
    }
}

private struct GrabberOrigin {
    let scheme: String
    let host: String
    let port: Int
    init?(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), let host = url.host?.lowercased() else { return nil }
        self.scheme = scheme; self.host = host; self.port = url.port ?? (scheme == "https" ? 443 : 80)
    }
    func contains(_ url: URL) -> Bool {
        guard let other = GrabberOrigin(url), url.user == nil, url.password == nil else { return false }
        return scheme == other.scheme && host == other.host && port == other.port
    }
}

private struct GrabberPage { let data: Data; let url: URL }

/// A delegate enforces the size bound while bytes arrive, rather than after a whole response is buffered.
private final class GrabberPageLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let maximumBytes = 2 * 1024 * 1024
    private let origin: GrabberOrigin
    private let lock = NSLock()
    private var continuation: CheckedContinuation<GrabberPage, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var data = Data()
    private var finalURL: URL?
    private var cancelled = false

    init(origin: GrabberOrigin) { self.origin = origin }

    func fetch(_ url: URL) async throws -> GrabberPage {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let config = URLSessionConfiguration.ephemeral
                config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
                config.timeoutIntervalForRequest = 10; config.timeoutIntervalForResource = 15
                config.httpMaximumConnectionsPerHost = 1
                let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
                self.session = session
                var request = URLRequest(url: url)
                request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
                request.setValue("Current-SiteGrabber/1.0", forHTTPHeaderField: "User-Agent")
                let task = session.dataTask(with: request); self.task = task
                lock.unlock()
                task.resume()
            }
        }, onCancel: { self.cancel() })
    }

    private func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<GrabberPage, Error>) {
        lock.lock()
        let continuation = self.continuation; self.continuation = nil
        let session = self.session; self.session = nil
        let task = self.task; self.task = nil
        lock.unlock()
        guard let continuation else { return }
        task?.cancel(); session?.invalidateAndCancel()
        continuation.resume(with: result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, origin.contains(url) else {
            completionHandler(nil)
            finish(.failure(CurrentError.invalid("A page redirected outside the starting website; that redirect was blocked.")))
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, let url = response.url, origin.contains(url), (200...299).contains(http.statusCode) else {
            completionHandler(.cancel)
            finish(.failure(CurrentError.invalid("The website did not return an accessible HTML page.")))
            return
        }
        let mime = response.mimeType?.lowercased() ?? ""
        guard mime.isEmpty || ["text/html", "application/xhtml+xml"].contains(mime) else {
            completionHandler(.cancel)
            finish(.failure(CurrentError.invalid("Site grabber needs an HTML page URL.")))
            return
        }
        guard response.expectedContentLength <= Int64(Self.maximumBytes) else {
            completionHandler(.cancel)
            finish(.failure(CurrentError.invalid("The page exceeds the site grabber's 2 MiB limit.")))
            return
        }
        finalURL = url
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard self.data.count <= Self.maximumBytes - data.count else {
            finish(.failure(CurrentError.invalid("The page exceeds the site grabber's 2 MiB limit.")))
            return
        }
        self.data.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil {
            finish(.failure(CurrentError.invalid("The page could not be loaded. Check the URL and connection, then retry.")))
        } else if let finalURL { finish(.success(GrabberPage(data: data, url: finalURL))) }
        else { finish(.failure(CurrentError.invalid("The website did not return an HTML page."))) }
    }
}
