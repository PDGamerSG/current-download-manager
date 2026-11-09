import Foundation
import CryptoKit
import Darwin

public enum FileVerifier {
    public static func finish(_ job: DownloadJob, scannerPath: String) async throws -> String? {
        let verification = Task.detached(priority:.utility) { () throws -> String? in
            try Task.checkCancellation()
            try TransferSafety.verifyOwnership(job)
            guard FileManager.default.fileExists(atPath:job.fileURL.path) else { throw CurrentError.invalid("The downloaded file is missing from its destination.") }
            if let checksum = job.request.checksum, !checksum.isEmpty {
                let parts = checksum.lowercased().split(separator:"="); let handle = try FileHandle(forReadingFrom:job.fileURL); defer { try? handle.close() }
                var sha256 = SHA256(), sha512 = SHA512(), sha1 = Insecure.SHA1(), md5 = Insecure.MD5()
                while let data = try handle.read(upToCount:1_048_576), !data.isEmpty {
                    try Task.checkCancellation()
                    switch parts[0] { case "sha-256": sha256.update(data:data); case "sha-512": sha512.update(data:data); case "sha-1": sha1.update(data:data); default: md5.update(data:data) }
                }
                let digest: String
                switch parts[0] { case "sha-256": digest = sha256.finalize().map{String(format:"%02x",$0)}.joined(); case "sha-512": digest = sha512.finalize().map{String(format:"%02x",$0)}.joined(); case "sha-1": digest = sha1.finalize().map{String(format:"%02x",$0)}.joined(); default: digest = md5.finalize().map{String(format:"%02x",$0)}.joined() }
                guard digest == String(parts[1]) else { throw CurrentError.invalid("Checksum mismatch. The file failed integrity verification.") }
            }
            let quarantine = "0081;\(String(Int(Date().timeIntervalSince1970),radix:16));Current;\(UUID().uuidString)"
            _ = job.fileURL.path.withCString { path in quarantine.withCString { value in setxattr(path,"com.apple.quarantine",value,strlen(value),0,0) } }
            guard !scannerPath.isEmpty else { return nil }
            let process = Process(); process.executableURL = URL(fileURLWithPath:scannerPath); process.arguments = [job.fileURL.path]
            process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run()
            defer { if process.isRunning { process.terminate() } }
            let deadline = Date().addingTimeInterval(300)
            while process.isRunning && Date() < deadline { try await Task.sleep(nanoseconds:100_000_000) }
            if process.isRunning { process.terminate(); throw CurrentError.invalid("The antivirus scanner timed out. Run a scan manually before opening this file.") }
            guard process.terminationStatus == 0 else { throw CurrentError.invalid("The antivirus scanner rejected this file (exit \(process.terminationStatus)).") }
            return "Scanner passed"
        }
        return try await withTaskCancellationHandler(operation:{ try await verification.value },onCancel:{ verification.cancel() })
    }
}
