import Foundation
import Darwin

public struct StateStore {
    public let directory: URL
    public init(directory: URL? = nil) throws {
        let override = ProcessInfo.processInfo.environment["CURRENT_STATE_DIR"].map { URL(fileURLWithPath:$0) }
        self.directory = directory ?? override ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Current")
        try FileManager.default.createDirectory(at:self.directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:self.directory.path)
    }
    public func load() throws -> AppState {
        let file = directory.appendingPathComponent("state.json")
        guard FileManager.default.fileExists(atPath:file.path) else { return AppState() }
        let state = try JSONDecoder.current.decode(AppState.self,from:Data(contentsOf:file))
        guard state.version == 1 else { throw CurrentError.invalid("This state file was created by a newer version of Current.") }
        return state
    }
    public func save(_ state: AppState) throws { try write(JSONEncoder.current.encode(state), name:"state.json") }
    public func write(_ data: Data, name: String) throws {
        let file = directory.appendingPathComponent(name)
        try data.write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
}
public final class ProcessLock {
    private var descriptor: Int32 = -1
    public init(at url: URL) throws {
        descriptor = Darwin.open(url.path,O_CREAT|O_RDWR,0o600)
        guard descriptor >= 0 else { throw CurrentError.invalid("Cannot open the application lock.") }
        var lock = flock(); lock.l_type = Int16(F_WRLCK); lock.l_whence = Int16(SEEK_SET)
        guard fcntl(descriptor,F_SETLK,&lock) != -1 else { Darwin.close(descriptor); descriptor = -1; throw CurrentError.invalid("Current is already running. Open its existing window or use currentctl request.") }
    }
    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }
}
public enum ToolLocator {
    public static func find(_ name: String) -> URL? {
        let envKey = "CURRENT_" + name.uppercased().replacingOccurrences(of:"-",with:"_")
        let executableFolder = URL(fileURLWithPath:CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent()
        var candidates = [ProcessInfo.processInfo.environment[envKey] ?? "", executableFolder.appendingPathComponent(name).path,
                          executableFolder.deletingLastPathComponent().appendingPathComponent("Resources/bin/"+name).path]
        candidates += ["/opt/homebrew/bin/","/usr/local/bin/","/usr/bin/"].map { $0+name }
        candidates += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator:":").map { String($0)+"/"+name }
        return candidates.first(where: { !$0.isEmpty && FileManager.default.isExecutableFile(atPath:$0) }).map { URL(fileURLWithPath:$0) }
    }
    public static func randomSecret() -> String { UUID().uuidString.replacingOccurrences(of:"-",with:"") + UUID().uuidString.replacingOccurrences(of:"-",with:"") }
    public static func freePort() throws -> UInt16 {
        let fd = socket(AF_INET,SOCK_STREAM,0); guard fd >= 0 else { throw CurrentError.invalid("Cannot allocate a local socket.") }; defer { Darwin.close(fd) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = 0; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0 else { throw CurrentError.invalid("Cannot bind a local socket.") }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { getsockname(fd,$0,&size) } }
        return UInt16(bigEndian:address.sin_port)
    }
}
