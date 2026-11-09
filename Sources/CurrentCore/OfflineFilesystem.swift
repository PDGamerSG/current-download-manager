import Foundation
import Darwin

struct OfflineFileIdentity: Codable, Equatable {
    let device: UInt64
    let inode: UInt64
    init(_ info: stat) { device = UInt64(UInt32(bitPattern: info.st_dev)); inode = UInt64(info.st_ino) }
}

/// Every output operation is relative to an opened directory. No output path is
/// resolved through symlinks, and publication always uses exclusive creation.
final class OfflineDirectory: @unchecked Sendable {
    let fd: Int32
    let url: URL
    let identity: OfflineFileIdentity

    private init(fd: Int32, url: URL) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            Darwin.close(fd); throw CurrentError.invalid("Cannot inspect the website destination folder.")
        }
        self.fd = fd; self.url = url; self.identity = OfflineFileIdentity(info)
    }
    deinit { Darwin.close(fd) }

    static func open(_ url: URL) throws -> OfflineDirectory {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0") else {
            throw CurrentError.invalid("Choose an absolute website destination folder.")
        }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw CurrentError.invalid("Cannot open the website destination folder.") }
        for component in url.pathComponents.dropFirst() {
            guard component != ".", component != ".." else { Darwin.close(descriptor); throw CurrentError.invalid("Use a destination folder without relative path components.") }
            let child = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            Darwin.close(descriptor)
            guard child >= 0 else { throw CurrentError.invalid("Choose an existing destination folder without symbolic links.") }
            descriptor = child
        }
        return try OfflineDirectory(fd: descriptor, url: url)
    }

    func verifyPath() throws {
        guard try OfflineDirectory.open(url).identity == identity else {
            throw CurrentError.invalid("The website destination folder was moved or replaced. Current left the replacement untouched; save the project to a new folder.")
        }
    }

    func child(_ name: String, create: Bool) throws -> OfflineDirectory {
        guard Self.validLeaf(name) else { throw CurrentError.invalid("Invalid website snapshot name.") }
        if create, mkdirat(fd, name, 0o700) != 0 {
            throw CurrentError.invalid("Cannot exclusively create the website snapshot folder.")
        }
        let descriptor = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CurrentError.invalid("Cannot open the private website folder without following symbolic links.") }
        return try OfflineDirectory(fd: descriptor, url: url.appendingPathComponent(name, isDirectory: true))
    }

    @discardableResult
    func writeExclusive(_ data: Data, name: String) throws -> OfflineFileIdentity {
        guard Self.validLeaf(name) else { throw CurrentError.invalid("Invalid offline resource filename.") }
        let file = openat(fd, name, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw CurrentError.invalid("The offline resource already exists or cannot be created. Current left it untouched.") }
        defer { Darwin.close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            throw CurrentError.invalid("Cannot inspect an offline resource.")
        }
        try data.withUnsafeBytes { bytes in
            var position = 0
            while position < bytes.count {
                let count = Darwin.write(file, bytes.baseAddress!.advanced(by: position), bytes.count - position)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw CurrentError.invalid("Cannot write the offline website; check free disk space.") }
                position += count
            }
        }
        guard fsync(file) == 0 else { throw CurrentError.invalid("Cannot save the offline website to disk.") }
        return OfflineFileIdentity(info)
    }

    func read(_ name: String, maximumBytes: Int) throws -> Data {
        guard Self.validLeaf(name) else { throw CurrentError.invalid("Invalid website state filename.") }
        let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw CurrentError.invalid("Cannot open saved website project state.") }
        defer { Darwin.close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_size >= 0, info.st_size <= maximumBytes else {
            throw CurrentError.invalid("The saved website project state is invalid or too large.")
        }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(file, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw CurrentError.invalid("Cannot read saved website project state.") }
            if count == 0 { return data }
            guard data.count <= maximumBytes - count else { throw CurrentError.invalid("The saved website project state is too large.") }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    private static func validLeaf(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }
}

struct WebsiteProjectState: Codable {
    var version = 1
    var projects: [WebsiteProject]
}

/// Immutable, exclusive state generations also avoid replacing someone else's
/// state file after a crash or user move. A generation appears only when complete.
final class WebsiteProjectStore {
    let directory: OfflineDirectory
    private var generation: UInt64 = 0
    init(stateDirectory: URL) throws {
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let canonical = realpath(stateDirectory.path, nil) else { throw CurrentError.invalid("Cannot resolve the private website state folder.") }
        let canonicalPath = String(cString: canonical); free(canonical)
        let root = try OfflineDirectory.open(URL(fileURLWithPath: canonicalPath))
        let name = "website-projects"
        var info = stat()
        if fstatat(root.fd, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            directory = try root.child(name, create: true)
        } else {
            directory = try root.child(name, create: false)
        }
    }
    func load() throws -> [WebsiteProject] {
        try directory.verifyPath()
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.url.path).filter {
            $0.hasPrefix("state-") && $0.hasSuffix(".json") && $0.count < 90
        }.sorted()
        guard let latest = names.last else { return [] }
        let parts = latest.split(separator: "-")
        guard parts.count >= 3, let number = UInt64(parts[1]) else { throw CurrentError.invalid("Saved website state has an invalid generation.") }
        generation = number
        let state = try JSONDecoder.current.decode(WebsiteProjectState.self, from: directory.read(latest, maximumBytes: 4 * 1024 * 1024))
        guard state.version == 1, state.projects.count <= 100 else { throw CurrentError.invalid("This website project state is not supported by this version of Current.") }
        return state.projects
    }
    func save(_ projects: [WebsiteProject]) throws {
        try directory.verifyPath()
        guard generation < UInt64.max else { throw CurrentError.invalid("Website state generation limit reached.") }
        let data = try JSONEncoder.current.encode(WebsiteProjectState(projects: projects))
        guard data.count <= 4 * 1024 * 1024 else { throw CurrentError.invalid("Saved website project state is too large.") }
        let next = generation + 1
        let token = String(format: "%020llu", next) + "-" + UUID().uuidString.lowercased()
        let temporary = "pending-" + token
        try directory.writeExclusive(data, name: temporary)
        let final = "state-" + token + ".json"
        // A completed generation is published without replacing any directory entry.
        guard renameatx_np(directory.fd, temporary, directory.fd, final, UInt32(RENAME_EXCL)) == 0 else {
            throw CurrentError.invalid("Cannot exclusively publish saved website project state.")
        }
        _ = fsync(directory.fd)
        generation = next
    }
}
