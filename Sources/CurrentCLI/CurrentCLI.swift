import Foundation
import CurrentCore
import Darwin

@main
struct CurrentCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        do {
            switch args.first ?? "help" {
            case "serve": try await serve()
            case "native-host": try await nativeHost()
            case "install-browser-host": print(try BrowserInstaller.install())
            case "request":
                let data = args.count > 1 ? Data(args[1].utf8) : FileHandle.standardInput.readDataToEndOfFile()
                let input = try JSONDecoder.current.decode(JSONValue.self,from:data)
                printJSON(try await BridgeClient.request(input))
            case "list": printJSON(try await BridgeClient.request(.object(["action":.string("status")])))
            case "add":
                guard args.count > 1 else { throw CurrentError.invalid("Usage: currentctl add <URL> [URL...]") }
                printJSON(try await BridgeClient.request(.object(["action":.string("add"),"urls":.array(args.dropFirst().map{.string($0)})])))
            case "version", "--version": print("Current 0.1.0")
            default:
                print("""
                Current 0.1.0 — native macOS download manager
                Usage: currentctl serve                  Run the local engine
                       currentctl add <URL> [URL...]     Add downloads to a running app/service
                       currentctl list                   Print private local state as JSON
                       currentctl request '<JSON>'       Execute a local command
                       currentctl install-browser-host   Set up per-user browser integration
                       currentctl native-host            Browser native messaging entry point
                Set CURRENT_STATE_DIR to isolate configuration and download history.
                """)
            }
        } catch {
            FileHandle.standardError.write(Data(("Current: "+error.localizedDescription+"\n").utf8)); exit(1)
        }
    }
    static func printJSON(_ value: JSONValue) { if let data = try? JSONEncoder.current.encode(value), let text = String(data:data,encoding:.utf8) { print(text) } }
    static func serve() async throws {
        let runtime = try ServiceRuntime(); try await runtime.start()
        print("Current service ready (loopback only).")
        fflush(stdout)
        signal(SIGINT,SIG_IGN); signal(SIGTERM,SIG_IGN)
        let (stream,continuation) = AsyncStream<Void>.makeStream()
        let sources = [SIGINT,SIGTERM].map { number -> DispatchSourceSignal in
            let source = DispatchSource.makeSignalSource(signal:number,queue:.global()); source.setEventHandler { continuation.yield(()) }; source.resume(); return source
        }
        for await _ in stream { break }
        sources.forEach{$0.cancel()}; continuation.finish(); await runtime.stop()
    }
    static func nativeHost() async throws {
        while let data = try NativeFraming.read(from:.standardInput) {
            let response: JSONValue
            do {
                let input = try JSONDecoder.current.decode(JSONValue.self,from:data)
                guard ["status","add","pause","resume","cancel"].contains(input["action"].string) else { throw CurrentError.invalid("This command is not available to browser extensions.") }
                do { _ = try await BridgeClient.request(.object(["action":.string("status")])) }
                catch {
                    // Never autostart an unrelated application for isolated integration runs.
                    if ProcessInfo.processInfo.environment["CURRENT_STATE_DIR"] != nil && ProcessInfo.processInfo.environment["CURRENT_APP_PATH"] == nil { throw error }
                    try launchApp()
                    var connected = false
                    for _ in 0..<80 {
                        try await Task.sleep(nanoseconds:150_000_000)
                        if (try? await BridgeClient.request(.object(["action":.string("status")]))) != nil { connected = true; break }
                    }
                    guard connected else { throw CurrentError.invalid("Open Current and try again. The local service did not become available.") }
                }
                // Submit a mutating command exactly once after readiness. Validation failures
                // must not launch another app or replay a partially accepted batch.
                let result = try await BridgeClient.request(input)
                response = .object(["ok":.bool(true),"result":publicResult(result,action:input["action"].string)])
            } catch { response = .object(["ok":.bool(false),"error":.string(error.localizedDescription)]) }
            let encoded = try JSONEncoder.current.encode(response)
            try FileHandle.standardOutput.write(contentsOf:NativeFraming.encode(encoded))
        }
    }
    static func publicResult(_ result: JSONValue, action: String) -> JSONValue {
        // Extensions need progress and acceptance IDs, never other downloads' credentials.
        func job(_ value: JSONValue) -> JSONValue {
            let keys = ["id","filename","directory","status","totalBytes","completedBytes","bytesPerSecond","createdAt","error"]
            return .object(value.object.filter{keys.contains($0.key)})
        }
        if action == "status" { return .object(["jobs":.array(result["jobs"].array.suffix(500).map(job)),"version":.string("0.1.0"),"connected":.bool(true)]) }
        if action == "add" { return .array(result.array.map(job)) }
        return result
    }
    static func launchApp() throws {
        let path = ProcessInfo.processInfo.environment["CURRENT_APP_PATH"]
        let executable = URL(fileURLWithPath:CommandLine.arguments[0]).standardizedFileURL
        let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app = path ?? (bundle.pathExtension == "app" ? bundle.path : "Current")
        let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/bin/open"); process.arguments = ["-g","-a",app]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CurrentError.invalid("Install and open Current.app before using the browser extension.") }
    }
}
