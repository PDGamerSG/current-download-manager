import Foundation

private struct PolicyFailure: Error, CustomStringConvertible {
    var description: String
}

@main
struct NetworkPolicyChecks {
    static var assertions = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        assertions += 1
        guard condition() else { throw PolicyFailure(description: message) }
    }

    static func settings(_ fields: [String: JSONValue]) throws -> AppSettings {
        var raw = try JSONValue.from(AppSettings()).object
        for (key, value) in fields { raw[key] = value }
        return try JSONValue.object(raw).decode(AppSettings.self)
    }

    static func rule(_ id: String, _ host: String, _ limit: Int) -> JSONValue {
        .object(["id": .string(id), "host": .string(host), "maxConnections": .number(Double(limit))])
    }

    static func rejects(_ fields: [String: JSONValue], _ message: String) throws {
        do { _ = try settings(fields).validated() }
        catch { assertions += 1; return }
        throw PolicyFailure(description: "Expected rejection: \(message)")
    }

    static func job(_ urls: [String], in folder: URL, connections: Int = 8) -> DownloadJob {
        var request = DownloadRequest(urls: urls)
        request.connections = connections
        return DownloadJob(request: request, filename: UUID().uuidString + ".bin", directory: folder.path, categoryID: "other")
    }

    static func checkOptions(_ engine: Aria2Engine, settings: AppSettings, urls: [String], requested: Int = 8, expected: Int, folder: URL) async throws {
        let gid = try await engine.add(job(urls, in: folder, connections: requested), settings: settings)
        let options = try await engine.call("getOption", [.string(gid)])
        try check(options["split"].string == String(expected), "split for \(urls) should be \(expected), got \(options["split"])")
        try check(options["max-connection-per-server"].string == String(expected), "server cap for \(urls) should be \(expected)")
        _ = try await engine.call("forceRemove", [.string(gid)])
    }

    static func download(_ engine: Aria2Engine, job: DownloadJob, settings: AppSettings, expected: Data, cap: Int) async throws {
        let gid = try await engine.add(job, settings: settings)
        let options = try await engine.call("getOption", [.string(gid)])
        try check(options["max-connection-per-server"].string == String(cap), "real download should receive its server cap")
        _ = try await engine.call("unpause", [.string(gid)])
        var complete = false
        var sawConnections = false
        for _ in 0..<300 {
            let status = try await engine.call("tellStatus", [.string(gid)])
            try check(status["connections"].int <= cap, "real transfer exceeded the configured per-server cap")
            sawConnections = sawConnections || status["connections"].int > 0
            if status["status"].string == "error" { throw PolicyFailure(description: "Real transfer failed: \(status)") }
            if status["status"].string == "complete" { complete = true; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try check(complete, "real download timed out")
        try check(sawConnections, "fixture should expose a running transfer")
        let actual = try Data(contentsOf: job.fileURL)
        try check(actual == expected, "downloaded bytes differ from the independent fixture")
    }

    static func main() async throws {
        guard CommandLine.arguments.count == 4 else { fatalError("usage: network-policy-checks STATE-DIR FIXTURE-URL EXPECTED-FILE") }
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        let fixture = CommandLine.arguments[2]
        let expected = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
        let store = try StateStore(directory: folder)
        let engine = Aria2Engine(store: store)
        do {
            let caps = try settings(["serverRules": .array([
                rule("broad", "*.example.org", 2),
                rule("nested", "*.cdn.example.org", 1),
                rule("exact", "images.cdn.example.org", 3),
                rule("large", "fast.example.net", 12)
            ])])
            try await engine.start(settings: caps, cookieJar: "# Netscape HTTP Cookie File\n127.0.0.1\tFALSE\t/\tFALSE\t2147483647\tsession\tfixture\n")
            for (url, requested, limit) in [
                ("https://cdn.example.org/file", 8, 2),
                ("https://example.org/file", 8, 8),
                ("https://images.cdn.example.org/file", 8, 3),
                ("https://a.cdn.example.org/file", 8, 1),
                ("https://notexample.org/file", 8, 8),
                ("https://example.org.evil.invalid/file", 8, 8),
                ("https://fast.example.net/file", 4, 4)
            ] {
                try await checkOptions(engine, settings: caps, urls: [url], requested: requested, expected: limit, folder: folder)
            }
            try await checkOptions(engine, settings: caps, urls: ["https://cdn.example.org/file", "https://a.cdn.example.org/file"], expected: 1, folder: folder)

            let exact = try settings(["serverRules": .array([rule("exact", "example.org", 2)])])
            try await checkOptions(engine, settings: exact, urls: ["https://example.org/file"], expected: 2, folder: folder)
            try await checkOptions(engine, settings: exact, urls: ["https://cdn.example.org/file"], expected: 8, folder: folder)

            for host in ["", "https://example.org", "user@example.org", "example.org/path", "example.org:443", "a.*.example.org", "*example.org", "*", "example..org", "-example.org", "example-.org", "example.org\n", "*.127.0.0.1"] {
                try rejects(["serverRules": .array([rule("invalid", host, 2)])], host)
            }
            for limit in [0, 17] { try rejects(["serverRules": .array([rule("invalid", "example.org", limit)])], "connection limit \(limit)") }
            try rejects(["serverRules": .array([rule("same", "example.org", 1), rule("same", "other.org", 2)])], "duplicate rule identity")
            try rejects(["serverRules": .array([rule("one", "Example.org", 1), rule("two", "example.org", 2)])], "duplicate host")
            for period in [-1, 0, 31_536_001] { try rejects(["quotaPeriodSeconds": .number(Double(period))], "quota period \(period)") }
            try rejects(["userAgent": .string("Client\r\nInjected: yes")], "User-Agent injection")

            let legacy = try JSONValue.object([
                "downloadDirectory": .string(folder.path), "maxConcurrent": .number(4), "speedLimit": .number(0), "proxy": .string(""),
                "hourlyQuota": .number(0), "clipboardDetection": .bool(false), "notifyOnCompletion": .bool(true), "scannerPath": .string("")
            ]).decode(AppSettings.self)
            _ = try legacy.validated()
            try check(legacy.effectiveQuotaPeriodSeconds == 3600, "old settings should retain the one-hour quota window")
            try await checkOptions(engine, settings: legacy, urls: ["https://example.org/file"], expected: 8, folder: folder)
            let legacyCategory = try JSONValue.object(["id": .string("old"), "name": .string("Old"), "extensions": .array([]), "hosts": .array([])]).decode(Category.self)
            let oldCategoryRaw = try JSONValue.from(legacyCategory)
            try check(oldCategoryRaw["directory"] == .null, "old categories should retain their default destination")

            let normalized = try settings(["serverRules": .array([rule("canonical", "  CDN.Example.ORG. ", 2)])])
            let normalizedRules = try normalized.validatedServerRules()
            try check(normalizedRules.first?.host == "cdn.example.org", "rules should normalize hostname case and trailing DNS dot")
            try check(normalized.connectionLimit(for: URL(string: "https://CDN.EXAMPLE.ORG./file")!) == 2, "absolute DNS hosts should match canonical rules")

            var manualSettings = try settings(["serverRules": .array([rule("loopback", "127.0.0.1", 2)]), "userAgent": .string("CurrentPolicyFixture/1"), "quotaPeriodSeconds": .number(14400)])
            let serialized = try JSONValue.from(manualSettings)
            try check(serialized["quotaPeriodSeconds"].int == 14400, "quota window must survive encoding")
            try check(serialized["userAgent"].string == "CurrentPolicyFixture/1", "User-Agent must survive encoding")
            var state = AppState()
            state.settings = manualSettings
            var category = legacyCategory
            category.directory = folder.appendingPathComponent("category-destination").path
            state.categories = [category]
            try store.save(state)
            let reloaded = try store.load()
            try check(reloaded.settings == manualSettings && reloaded.categories == [category], "policy and custom category destination must survive a private-state restart")
            state.settings = legacy
            state.categories = [legacyCategory]
            try store.save(state)
            let oldState = try store.load()
            try check(oldState.settings.effectiveQuotaPeriodSeconds == 3600 && oldState.categories.first?.directory == nil, "old state should decode with policy and category defaults")

            let queued = job([fixture + "/updated"], in: folder)
            let queuedID = try await engine.add(queued, settings: manualSettings)
            let updated = try settings(["serverRules": .array([rule("loopback", "127.0.0.1", 1)]), "userAgent": .string("UpdatedPolicyFixture/2"), "proxy": .string("http://127.0.0.1:65432")])
            _ = try await engine.call("changeOption", [.string(queuedID), .object(try engine.requestOptions(for: queued, settings: updated))])
            let changed = try await engine.call("getOption", [.string(queuedID)])
            try check(changed["split"].string == "1" && changed["max-connection-per-server"].string == "1", "queued engine requests must accept changed connection caps")
            try check(changed["user-agent"].string == "UpdatedPolicyFixture/2", "queued requests must accept a changed manual User-Agent")
            let changedProxy = URL(string: changed["all-proxy"].string)
            try check(changedProxy?.scheme == "http" && changedProxy?.host == "127.0.0.1" && changedProxy?.port == 65432, "network policy must retain the configured proxy endpoint")
            let defaults = try await engine.call("getGlobalOption")
            _ = try await engine.call("changeOption", [.string(queuedID), .object(try engine.requestOptions(for: queued, settings: legacy))])
            let reset = try await engine.call("getOption", [.string(queuedID)])
            try check(reset["user-agent"] == defaults["user-agent"], "clearing the manual User-Agent must restore the engine default")
            _ = try await engine.call("forceRemove", [.string(queuedID)])

            try await download(engine, job: job([fixture + "/manual"], in: folder), settings: manualSettings, expected: expected, cap: 2)
            var browser = job([fixture + "/browser"], in: folder)
            browser.request.headers = ["uSeR-aGeNt": "BrowserFixture/12", "Cookie": "must-not-forward=1"]
            try await download(engine, job: browser, settings: manualSettings, expected: expected, cap: 2)
            // A running engine must use new settings on the next admitted request.
            manualSettings = try settings(["serverRules": .array([rule("loopback", "127.0.0.1", 1)]), "userAgent": .string("UpdatedPolicyFixture/2")])
            try await download(engine, job: job([fixture + "/updated"], in: folder), settings: manualSettings, expected: expected, cap: 1)
            await engine.stop()
            print("Network policy: \(assertions) assertions passed")
        } catch {
            await engine.stop()
            throw error
        }
    }
}
