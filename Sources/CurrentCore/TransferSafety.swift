import Foundation
import Darwin

enum TransferSafety {
    /// Reserve the output before enqueueing, so every future write has a known owner.
    static func reserve(_ job: inout DownloadJob) throws -> Bool {
        guard job.request.kind == .file else { return true }
        let fd = Darwin.open(job.fileURL.path,O_CREAT|O_EXCL|O_RDWR|O_NOFOLLOW|O_CLOEXEC,0o600)
        if fd < 0 {
            if errno == EEXIST { return false }
            throw CurrentError.invalid("Cannot reserve the destination file. Check folder permissions and free disk space.")
        }
        defer { Darwin.close(fd) }
        var value = stat(); guard fstat(fd,&value) == 0 else { throw CurrentError.invalid("Cannot inspect the reserved download file.") }
        job.fileDevice = UInt64(UInt32(bitPattern:value.st_dev)); job.fileInode = UInt64(value.st_ino); job.hasStarted = false
        return true
    }
    static func verifyOwnership(_ job: DownloadJob) throws {
        var value = stat()
        guard lstat(job.fileURL.path,&value) == 0,
              value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1,
              UInt64(UInt32(bitPattern:value.st_dev)) == job.fileDevice, UInt64(value.st_ino) == job.fileInode else {
            throw CurrentError.invalid("The destination was moved or replaced. Current left it untouched. Add the URL again with a new filename.")
        }
        if job.hasStarted != true && value.st_size != 0 {
            throw CurrentError.invalid("Another file was written to this reserved destination. Current left it untouched. Choose a new filename.")
        }
    }
    static func recordOwnership(_ job: inout DownloadJob) {
        var value = stat()
        if lstat(job.fileURL.path,&value) == 0, value.st_mode & S_IFMT == S_IFREG {
            job.fileDevice = UInt64(UInt32(bitPattern:value.st_dev)); job.fileInode = UInt64(value.st_ino); job.hasStarted = true
        }
    }
    static func releaseEmptyReservation(_ job: DownloadJob) {
        guard job.request.kind == .file, (try? verifyOwnership(job)) != nil,
              let size = try? FileManager.default.attributesOfItem(atPath:job.fileURL.path)[.size] as? NSNumber, size.int64Value == 0 else { return }
        try? FileManager.default.removeItem(at:job.fileURL)
    }
    /// aria2 only loads cookies at process start. A changed jar triggers a managed
    /// engine restart, preserving control files; raw Cookie headers are never used.
    static func cookieJar(_ jobs: [DownloadJob]) throws -> String {
        var cookies: [String:String] = [:]
        for job in jobs where job.request.kind == .file && ![.complete,.error,.cancelled].contains(job.status) {
            guard let url = job.request.urls.first.flatMap(URL.init(string:)), let host = url.host else { continue }
            for (key,header) in job.request.headers where key.lowercased() == "cookie" {
                for pair in header.split(separator:";") {
                    let parts = pair.split(separator:"=",maxSplits:1,omittingEmptySubsequences:false)
                    guard parts.count == 2 else { throw CurrentError.invalid("The Cookie header is invalid. Capture a fresh browser link.") }
                    let name = parts[0].trimmingCharacters(in:.whitespaces), value = parts[1].trimmingCharacters(in:.whitespaces)
                    guard !name.isEmpty, !name.contains("\t"), !value.contains("\t") else { throw CurrentError.invalid("The Cookie header is invalid.") }
                    let secure = url.scheme?.lowercased() == "https" ? "TRUE" : "FALSE"
                    let cookieKey = host.lowercased()+"\tFALSE\t/\t"+secure+"\t0\t"+name
                    if let previous = cookies[cookieKey], previous != value { throw CurrentError.invalid("Two unfinished downloads use different sessions for the same website. Finish or cancel one session before adding the other.") }
                    cookies[cookieKey] = value
                }
            }
        }
        return "# Netscape HTTP Cookie File\n"+cookies.keys.sorted().map{$0+"\t"+cookies[$0]!}.joined(separator:"\n")+"\n"
    }
}
