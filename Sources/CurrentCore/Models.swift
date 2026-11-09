import Foundation

public enum CurrentError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let message): return message } }
}

public enum JSONValue: Codable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public var object: [String: JSONValue] { if case .object(let v) = self { return v }; return [:] }
    public var array: [JSONValue] { if case .array(let v) = self { return v }; return [] }
    public var string: String { if case .string(let v) = self { return v }; return "" }
    public var integer: Int? { if case .number(let v) = self { return Int(exactly:v) }; return Int(string) }
    public var int: Int { integer ?? 0 }
    public var bool: Bool { if case .bool(let v) = self { return v }; return false }
    public subscript(_ key: String) -> JSONValue { object[key] ?? .null }
    public static func from<T: Encodable>(_ value: T) throws -> JSONValue { try JSONDecoder.current.decode(Self.self, from: JSONEncoder.current.encode(value)) }
    public func decode<T: Decodable>(_ type: T.Type) throws -> T { try JSONDecoder.current.decode(type, from: JSONEncoder.current.encode(self)) }
}
public extension JSONEncoder {
    static var current: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }
}
public extension JSONDecoder {
    static var current: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}

public enum DownloadKind: String, Codable { case file, media }
public struct DownloadRequest: Codable, Equatable {
    public var urls: [String]
    public var filename: String?
    public var directory: String?
    public var headers: [String: String] = [:]
    public var connections: Int = 8
    public var checksum: String?
    public var username: String?
    public var password: String?
    public var speedLimit: Int64 = 0
    public var queueID: String = "main"
    public var categoryID: String?
    public var startPaused: Bool = false
    public var kind: DownloadKind = .file
    public init(urls: [String], filename: String? = nil) { self.urls = urls; self.filename = filename }
    enum CodingKeys: String, CodingKey { case urls, filename, directory, headers, connections, checksum, username, password, speedLimit, queueID, categoryID, startPaused, kind }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        urls = try c.decode([String].self, forKey: .urls)
        filename = try c.decodeIfPresent(String.self, forKey: .filename)
        directory = try c.decodeIfPresent(String.self, forKey: .directory)
        headers = try c.decodeIfPresent([String:String].self, forKey: .headers) ?? [:]
        connections = try c.decodeIfPresent(Int.self, forKey: .connections) ?? 8
        checksum = try c.decodeIfPresent(String.self, forKey: .checksum)
        username = try c.decodeIfPresent(String.self, forKey: .username)
        password = try c.decodeIfPresent(String.self, forKey: .password)
        speedLimit = try c.decodeIfPresent(Int64.self, forKey: .speedLimit) ?? 0
        queueID = try c.decodeIfPresent(String.self, forKey: .queueID) ?? "main"
        categoryID = try c.decodeIfPresent(String.self, forKey: .categoryID)
        startPaused = try c.decodeIfPresent(Bool.self, forKey: .startPaused) ?? false
        kind = try c.decodeIfPresent(DownloadKind.self, forKey: .kind) ?? .file
    }
    public func validated() throws -> DownloadRequest {
        guard !urls.isEmpty, urls.count <= 32 else { throw CurrentError.invalid("Provide between 1 and 32 source URLs.") }
        for value in urls {
            guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  let url = URL(string: value), let scheme = url.scheme?.lowercased(),
                  ["http", "https", "ftp", "sftp"].contains(scheme),
                  let host = url.host, !host.isEmpty else { throw CurrentError.invalid("Use a valid HTTP, HTTPS, FTP or SFTP URL.") }
        }
        if let filename, !filename.isEmpty { try Self.validateFilename(filename) }
        if let directory, !directory.isEmpty {
            guard directory.hasPrefix("/"), !directory.contains("\0") else { throw CurrentError.invalid("Choose an absolute destination folder.") }
        }
        let forbidden = CharacterSet(charactersIn: "()<>@,;:\\\"/[]?={} \t").union(.controlCharacters)
        for (key, value) in headers {
            guard !key.isEmpty, key.unicodeScalars.allSatisfy({ !forbidden.contains($0) }),
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw CurrentError.invalid("A request header contains invalid characters.") }
            guard !["host", "content-length", "connection", "transfer-encoding"].contains(key.lowercased()) else { throw CurrentError.invalid("This header is managed by the download engine: \(key)") }
            guard key.lowercased() != "authorization" else { throw CurrentError.invalid("Use the username and password fields for HTTP authentication. Raw Authorization headers cannot be safely scoped across redirects by this engine.") }
        }
        guard (1...16).contains(connections), speedLimit >= 0 else { throw CurrentError.invalid("Connections must be 1–16; speed limits must be nonnegative.") }
        if let checksum, !checksum.isEmpty {
            let parts = checksum.lowercased().split(separator: "=", omittingEmptySubsequences: false)
            let sizes = ["sha-256":64, "sha-1":40, "sha-512":128, "md5":32]
            guard parts.count == 2, let size = sizes[String(parts[0])], parts[1].count == size,
                  parts[1].allSatisfy({ $0.isHexDigit }) else { throw CurrentError.invalid("Use a checksum such as sha-256=<64 hexadecimal characters>.") }
        }
        return self
    }
    public static func validateFilename(_ value: String) throws {
        guard value != ".", value != "..", !value.isEmpty, value.utf8.count <= 220,
              !value.contains("/"), !value.contains(":"), !value.contains("\\"),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw CurrentError.invalid("Use a filename without path separators or control characters.") }
    }
    public var redacted: DownloadRequest {
        var value = self; value.headers = [:]; value.username = nil; value.password = nil; value.directory = nil
        value.urls = urls.compactMap { raw in
            guard var c = URLComponents(string: raw) else { return nil }; c.user = nil; c.password = nil
            c.query = nil; c.fragment = nil; return c.string
        }
        return value
    }
}

public struct Category: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var extensions: [String]
    public var hosts: [String]
    public init(id: String, name: String, extensions: [String], hosts: [String] = []) { self.id = id; self.name = name; self.extensions = extensions; self.hosts = hosts }
    public func matches(_ url: URL) -> Bool {
        if extensions.map({ $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }).contains(url.pathExtension.lowercased()) { return true }
        let host = url.host?.lowercased() ?? ""
        return hosts.contains { let rule = $0.lowercased(); return !rule.isEmpty && (host == rule || host.hasSuffix("." + rule)) }
    }
    public var symbol: String {
        switch id { case "video": return "film"; case "audio": return "music.note"; case "archives": return "archivebox"; case "documents": return "doc.text"; case "images": return "photo"; case "applications": return "app.badge"; default: return "folder" }
    }
    public static let defaults: [Category] = [
        .init(id:"video",name:"Video",extensions:["mp4","mkv","webm","mov","avi","m3u8","mpd"]),
        .init(id:"audio",name:"Audio",extensions:["mp3","m4a","flac","wav","ogg","aac"]),
        .init(id:"archives",name:"Archives",extensions:["zip","7z","rar","gz","tar","xz","bz2"]),
        .init(id:"documents",name:"Documents",extensions:["pdf","docx","xlsx","pptx","txt","epub","csv"]),
        .init(id:"images",name:"Images",extensions:["jpg","jpeg","png","gif","svg","webp","avif","heic"]),
        .init(id:"applications",name:"Applications",extensions:["dmg","pkg","iso"]),
        .init(id:"other",name:"Other",extensions:[])
    ]
}

public struct QueueSchedule: Codable, Equatable {
    public var start: Date
    public var end: Date?
    public var daily: Bool
    public init(start: Date, end: Date? = nil, daily: Bool = false) { self.start = start; self.end = end; self.daily = daily }
    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard date >= start else { return false }
        guard daily else { return end.map { date < $0 } ?? true }
        guard let end else { return true }
        func seconds(_ date: Date) -> Int { let c = calendar.dateComponents([.hour,.minute,.second], from:date); return (c.hour ?? 0)*3600+(c.minute ?? 0)*60+(c.second ?? 0) }
        let s = seconds(start), e = seconds(end), n = seconds(date)
        return s < e ? n >= s && n < e : n >= s || n < e
    }
}

public struct DownloadQueue: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var maxConcurrent: Int
    public var enabled: Bool
    public var schedule: QueueSchedule?
    public init(id: String = UUID().uuidString, name: String = "New queue", maxConcurrent: Int = 2, enabled: Bool = true, schedule: QueueSchedule? = nil) {
        self.id = id; self.name = name; self.maxConcurrent = maxConcurrent; self.enabled = enabled; self.schedule = schedule
    }
    public func isEligible(at date: Date) -> Bool { enabled && (schedule?.contains(date) ?? true) }
}

public enum JobStatus: String, Codable { case waiting, active, paused, complete, error, cancelled }
public enum JobIntent: String, Codable { case running, paused, cancelled }
public struct DownloadJob: Codable, Equatable, Identifiable {
    public var id: String = UUID().uuidString
    public var gid: String?
    public var request: DownloadRequest
    public var filename: String
    public var directory: String
    public var categoryID: String
    public var status: JobStatus = .waiting
    public var intent: JobIntent = .running
    public var totalBytes: Int64 = 0
    public var completedBytes: Int64 = 0
    public var bytesPerSecond: Int64 = 0
    public var connections: Int = 0
    public var bitfield: String = ""
    public var error: String?
    public var createdAt: Date = Date()
    public var completedAt: Date?
    public var priority: Int = 0
    public var scanResult: String?
    public var fileDevice: UInt64?
    public var fileInode: UInt64?
    public var hasStarted: Bool? = false
    public var needsVerification: Bool?
    public init(request: DownloadRequest, filename: String, directory: String, categoryID: String) {
        self.request = request; self.filename = filename; self.directory = directory; self.categoryID = categoryID
        if request.startPaused { self.intent = .paused; self.status = .paused }
    }
    public var fileURL: URL { URL(fileURLWithPath: directory).appendingPathComponent(filename) }
    public var progress: Double { totalBytes > 0 ? min(1, Double(completedBytes)/Double(totalBytes)) : 0 }
    public var remainingSeconds: Int? { bytesPerSecond > 0 ? Int(max(0,totalBytes-completedBytes)/bytesPerSecond) : nil }
}

public struct AppSettings: Codable, Equatable {
    public var downloadDirectory: String = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/Current").path
    public var maxConcurrent: Int = 4
    public var speedLimit: Int64 = 0
    public var proxy: String = ""
    public var hourlyQuota: Int64 = 0
    public var clipboardDetection: Bool = false
    public var notifyOnCompletion: Bool = true
    public var scannerPath: String = ""
    public init() {}
    public func validated() throws -> AppSettings {
        guard (1...32).contains(maxConcurrent), speedLimit >= 0, hourlyQuota >= 0, downloadDirectory.hasPrefix("/"), !downloadDirectory.contains("\0") else { throw CurrentError.invalid("Check the download folder, concurrency and bandwidth values.") }
        if !proxy.isEmpty {
            guard let url = URL(string:proxy), ["http","https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
                  !proxy.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw CurrentError.invalid("Use an HTTP or HTTPS proxy URL.") }
        }
        if !scannerPath.isEmpty { guard scannerPath.hasPrefix("/"), FileManager.default.isExecutableFile(atPath:scannerPath) else { throw CurrentError.invalid("Choose an executable antivirus scanner. Current passes the downloaded file as its only argument.") } }
        return self
    }
}
public struct AppState: Codable, Equatable {
    public var version: Int = 1
    public var jobs: [DownloadJob] = []
    public var queues: [DownloadQueue] = [.init(id:"main",name:"Main queue",maxConcurrent:4)]
    public var categories: [Category] = Category.defaults
    public var settings: AppSettings = .init()
    public var quotaWindow: Date = Date()
    public var quotaBytes: Int64 = 0
    public init() {}
}
public enum NativeFraming {
    public static let maximumBytes = 1_048_576
    public static func encode(_ data: Data) throws -> Data {
        guard data.count <= maximumBytes else { throw CurrentError.invalid("Native message exceeds 1 MiB.") }
        var count = UInt32(data.count).littleEndian
        return withUnsafeBytes(of:&count) { Data($0) } + data
    }
    public static func decode(_ data: Data) throws -> Data {
        guard data.count >= 4 else { throw CurrentError.invalid("Truncated native message header.") }
        let size = data.prefix(4).enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
        guard size <= maximumBytes, data.count == size + 4 else { throw CurrentError.invalid("Invalid or truncated native message body.") }
        return Data(data.dropFirst(4))
    }
    public static func read(from handle: FileHandle) throws -> Data? {
        func readExactly(_ count: Int) throws -> Data {
            var result = Data()
            while result.count < count {
                guard let part = try handle.read(upToCount: count-result.count), !part.isEmpty else { break }; result.append(part)
            }
            return result
        }
        let header = try readExactly(4)
        if header.isEmpty { return nil }
        guard header.count == 4 else { throw CurrentError.invalid("Truncated native message header.") }
        let size = header.enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
        guard size <= maximumBytes else { throw CurrentError.invalid("Native message exceeds 1 MiB.") }
        return try decode(header + readExactly(size))
    }
}
