import Foundation
import Darwin

@main struct WebsiteProjectChecks {
    static var assertions = 0
    static var failures = 0
    static func expect(_ condition: Bool, _ message: String) {
        assertions += 1
        if !condition { failures += 1; print("FAIL: \(message)") }
    }
    static func send(_ manager: WebsiteProjectManager, _ action: String, _ fields: [String: JSONValue] = [:]) async throws -> JSONValue {
        var fields = fields; fields["action"] = .string("web-project-" + action)
        return try await manager.command(.object(fields))
    }
    static func settled(_ manager: WebsiteProjectManager, id: String, timeout: TimeInterval = 15) async throws -> JSONValue {
        let began = Date()
        while Date().timeIntervalSince(began) < timeout {
            let response = try await send(manager, "list")
            if let project = response["projects"].array.first(where: { $0["id"].string == id }), project["status"].string != "running" { return project }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw CurrentError.invalid("Website project did not settle.")
    }
    static func rejected(_ message: String, _ operation: () async throws -> Void) async {
        do { try await operation(); expect(false, message) } catch { expect(true, message) }
    }
    static func automatic(_ manager: WebsiteProjectManager, id: String, after date: Date, timeout: TimeInterval) async throws -> JSONValue {
        let began = Date()
        while Date().timeIntervalSince(began) < timeout {
            let project = try await send(manager, "list")["projects"].array.first { $0["id"].string == id } ?? .null
            if let success = try? project["lastSuccessAt"].decode(Date.self), success > date { return project }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw CurrentError.invalid("A scheduled project did not run automatically.")
    }
    static func main() async throws {
        let base = CommandLine.arguments[1]
        let misleadingHead = "<!doctype html><html><title>Example <head> text</title><body><object data='data:text/html,example'></object></body></html>"
        let hardened = OfflineMarkup.rewrite(misleadingHead, kind: .html, base: URL(string: base)!, mapping: [:])
        expect(hardened.range(of: "Content-Security-Policy")!.lowerBound < hardened.range(of: "<title>")!.lowerBound, "offline security policy precedes untrusted markup even when head-like text appears in a title")
        let root = URL(fileURLWithPath: CommandLine.arguments[2])
        let destination = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let sentinel = destination.appendingPathComponent("index.html")
        try Data("unrelated-index".utf8).write(to: sentinel)
        var manager = try WebsiteProjectManager(stateDirectory: root.appendingPathComponent("state"))
        try await manager.start()
        let definition: [String: JSONValue] = ["name": .string("Fixture site"), "sourceURL": .string(base + "/redirect"), "destinationDirectory": .string(destination.path), "maxDepth": .number(1), "mode": .string("site"), "excludePatterns": .array([.string("*/excluded.html")]), "headers": .object(["Cookie": .string("fixture=session")])]
        try await manager.start()
        await rejected("relative destinations are rejected before URL normalization") {
            var bad = definition; bad["destinationDirectory"] = .string(".")
            _ = try await send(manager, "save", ["project": .object(bad)])
        }
        let recoveryState = root.appendingPathComponent("recovery-state")
        let recoveryStore = try WebsiteProjectStore(stateDirectory: recoveryState)
        var interrupted = WebsiteProject(name: "Interrupted periodic capture", sourceURL: base + "/slow", destinationDirectory: destination.path)
        interrupted.destinationIdentity = try OfflineDirectory.open(destination).identity
        interrupted.status = "running"; interrupted.intervalSeconds = 60
        try recoveryStore.save([interrupted])
        let recoveredManager = try WebsiteProjectManager(stateDirectory: recoveryState)
        try await recoveredManager.start()
        let recovered = try await send(recoveredManager, "list")["projects"].array.first
        expect(recovered?["status"].string == "idle" && recovered?["nextRunAt"] != .null, "an interrupted periodic capture retains an automatic retry after restart")
        await recoveredManager.stop()
        var saved: JSONValue
        do { saved = try await send(manager, "save", ["project": .object(definition)])["project"] }
        catch { expect(false, "a static website project can be saved: \(error.localizedDescription)"); exit(1) }
        let id = saved["id"].string
        expect(!id.isEmpty, "saved projects receive a stable identifier")
        _ = try await send(manager, "run", ["id": .string(id)])
        let first = try await settled(manager, id: id)
        expect(first["status"].string == "complete", "capture succeeds: \(first["lastError"].string)")
        let output = URL(fileURLWithPath: first["outputDirectory"].string)
        let entry = output.appendingPathComponent(first["entryPath"].string)
        let html = (try? String(contentsOf: entry, encoding: .utf8)) ?? ""
        expect(html.contains("Revision 1") && !html.contains("<base") && !html.contains("<script") && !html.contains("onclick="), "offline HTML contains server content with base, scripts and event handlers removed")
        expect(html.contains("script-src 'none'"), "offline HTML disables script execution")
        let manifest = try JSONDecoder.current.decode(JSONValue.self, from: Data(contentsOf: output.appendingPathComponent("manifest.json")))
        let files = manifest["resources"].array
        func local(_ suffix: String) -> String { files.first { $0["url"].string.hasSuffix(suffix) }?["path"].string ?? "" }
        let child = local("/site/child.html")
        let cssPath = local("/assets/main.css")
        expect(!child.isEmpty && html.contains(child + "#part"), "navigation links point to captured local pages and preserve fragments")
        expect(html.contains("/site/grandchild.html") == false, "root HTML is retained independently of deeper documents")
        let childHTML = (try? String(contentsOf: output.appendingPathComponent(child), encoding: .utf8)) ?? ""
        expect(childHTML.contains(base + "/site/grandchild.html"), "links beyond the depth bound retain an absolute source URL")
        let css = (try? String(contentsOf: output.appendingPathComponent(cssPath), encoding: .utf8)) ?? ""
        expect(!cssPath.isEmpty && html.contains(cssPath), "HTML stylesheet references resolve locally")
        expect(css.contains(local("/assets/nested.css")) && css.contains(local("/assets/font.woff2")) && !local("/assets/nested.css").isEmpty, "CSS imports and font URLs resolve locally")
        expect(files.contains { $0["url"].string.hasSuffix("/assets/deep.css") }, "nested CSS imports are captured recursively")
        expect(files.contains { $0["url"].string.hasSuffix("/assets/retina.png") } && html.contains(local("/assets/retina.png") + " 2x"), "srcset candidates are captured and rewritten")
        expect(files.contains { $0["url"].string.hasSuffix("/assets/style.png") } && files.contains { $0["url"].string.hasSuffix("/assets/inline.png") }, "inline CSS discovers assets in style elements and attributes")
        expect(files.contains { $0["url"].string.hasSuffix("/site/query.html?x=1&y=2") }, "HTML entities in query URLs are decoded")
        for item in files where item["url"].string.contains("/assets/") && item["url"].string.contains(".png") {
            let original = URL(string: item["url"].string)!
            let expected = "fixture-bytes:" + original.path + (original.query.map { "?" + $0 } ?? "")
            expect((try? Data(contentsOf: output.appendingPathComponent(item["path"].string))) == Data(expected.utf8), "offline image bytes match independently known fixture bytes")
        }
        expect((try? Data(contentsOf: sentinel)) == Data("unrelated-index".utf8), "capture never overwrites a pre-existing destination file")
        for (mode, includes) in [("page", [String]()), ("site", ["/site/child.html"])] {
            var filtered = definition; filtered["sourceURL"] = .string(base + "/site/index.html"); filtered["mode"] = .string(mode); filtered["includePatterns"] = .array(includes.map(JSONValue.string))
            let project = try await send(manager, "save", ["project": .object(filtered)])["project"]
            _ = try await send(manager, "run", ["id": project["id"]])
            let result = try await settled(manager, id: project["id"].string)
            let manifestURL = URL(fileURLWithPath: result["outputDirectory"].string).appendingPathComponent("manifest.json")
            let manifest = try JSONDecoder.current.decode(JSONValue.self, from: Data(contentsOf: manifestURL))
            let urls = Set(manifest["resources"].array.map { $0["url"].string })
            expect(result["status"].string == "complete" && !urls.contains(base + "/site/query.html?x=1&y=2"), "\(mode) mode and page includes limit navigation")
            expect(urls.contains(base + "/assets/main.css") && urls.contains(base + "/assets/picture.png"), "page filters preserve stylesheet and image dependencies")
            if mode == "site" { expect(urls.contains(base + "/site/child.html"), "matching included pages are captured") }
        }
        var disguisedResource = definition; disguisedResource["sourceURL"] = .string(base + "/resource-depth")
        let disguised = try await send(manager, "save", ["project": .object(disguisedResource)])["project"]
        _ = try await send(manager, "run", ["id": disguised["id"]])
        let disguisedResult = try await settled(manager, id: disguised["id"].string)
        let disguisedManifest = try JSONDecoder.current.decode(JSONValue.self, from: Data(contentsOf: URL(fileURLWithPath: disguisedResult["outputDirectory"].string).appendingPathComponent("manifest.json")))
        expect(!disguisedManifest["resources"].array.contains { $0["url"].string.hasSuffix("/unexpected-depth.html") }, "HTML returned for a non-document asset cannot bypass the page-depth limit")
        _ = try await URLSession.shared.data(from: URL(string: base + "/control/fail")!)
        _ = try await send(manager, "run", ["id": .string(id)])
        let failed = try await settled(manager, id: id)
        expect(failed["status"].string == "error" && failed["outputDirectory"] == first["outputDirectory"], "failed update retains the last successful snapshot")
        expect((try? String(contentsOf: entry, encoding: .utf8)) == html, "failed update preserves previous offline bytes")
        _ = try await URLSession.shared.data(from: URL(string: base + "/control/update")!)
        _ = try await send(manager, "run", ["id": .string(id)])
        var updated = try await settled(manager, id: id)
        expect(updated["status"].string == "complete" && updated["outputDirectory"] != first["outputDirectory"], "successful updates publish a new immutable snapshot")
        expect((try? String(contentsOf: entry, encoding: .utf8)) == html, "successful updates retain old snapshot content")
        await manager.stop()
        manager = try WebsiteProjectManager(stateDirectory: root.appendingPathComponent("state"))
        try await manager.start()
        let restored = try await send(manager, "list")["projects"].array.first { $0["id"].string == id }
        expect(restored?["outputDirectory"] == updated["outputDirectory"], "project definitions and current snapshots survive restart")
        let replacedEntry = URL(fileURLWithPath: updated["outputDirectory"].string).appendingPathComponent("index.html")
        try FileManager.default.moveItem(at: replacedEntry, to: replacedEntry.appendingPathExtension("original"))
        try Data("someone-elses-replacement".utf8).write(to: replacedEntry)
        _ = try await send(manager, "run", ["id": .string(id)])
        let afterReplacement = try await settled(manager, id: id)
        expect(afterReplacement["status"].string == "complete" && afterReplacement["outputDirectory"] != updated["outputDirectory"], "a later run never adopts a replacement file in an older snapshot")
        expect((try? Data(contentsOf: replacedEntry)) == Data("someone-elses-replacement".utf8), "later runs leave a replaced snapshot file untouched")
        updated = afterReplacement

        var slow = definition; slow["name"] = .string("Cancellation"); slow["sourceURL"] = .string(base + "/slow"); slow["intervalSeconds"] = .number(60)
        saved = try await send(manager, "save", ["project": .object(slow)])["project"]
        let slowID = saved["id"].string
        _ = try await send(manager, "run", ["id": .string(slowID)])
        try await Task.sleep(nanoseconds: 200_000_000)
        let stopBegan = Date()
        _ = try await send(manager, "stop", ["id": .string(slowID)])
        let stopped = try await settled(manager, id: slowID)
        expect(Date().timeIntervalSince(stopBegan) < 2 && stopped["status"].string == "paused", "stop cancels an in-flight response promptly")
        expect(stopped["outputDirectory"].string.isEmpty && stopped["nextRunAt"] == .null, "manual stop suppresses periodic runs and publishes no incomplete snapshot")
        await manager.stop()
        manager = try WebsiteProjectManager(stateDirectory: root.appendingPathComponent("state"))
        try await manager.start()
        let stoppedAgain = try await send(manager, "list")["projects"].array.first { $0["id"].string == slowID }
        expect(stoppedAgain?["status"].string == "paused", "manual stop survives a service restart")

        var periodic = definition
        periodic["name"] = .string("Scheduled periodic fixture")
        periodic["sourceURL"] = .string(base + "/site/query.html")
        periodic["intervalSeconds"] = .number(60)
        periodic["scheduledAt"] = try .from(Date().addingTimeInterval(2))
        let periodicProject = try await send(manager, "save", ["project": .object(periodic)])["project"]
        let periodicID = periodicProject["id"].string
        expect(periodicProject["status"].string == "idle" && periodicProject["lastRunAt"] == .null, "scheduled captures wait until their requested start")
        let automaticFirst = try await automatic(manager, id: periodicID, after: Date().addingTimeInterval(-1), timeout: 6)
        expect(automaticFirst["status"].string == "complete" && automaticFirst["fileCount"].int == 1, "the saved start schedule triggers a real offline capture")
        let firstSuccess = try automaticFirst["lastSuccessAt"].decode(Date.self)
        let nextDue = try automaticFirst["nextRunAt"].decode(Date.self)
        expect((59...61).contains(nextDue.timeIntervalSince(firstSuccess)), "periodic timing is based on the completed capture")
        await manager.stop()
        manager = try WebsiteProjectManager(stateDirectory: root.appendingPathComponent("state"))
        try await manager.start()
        let scheduledRestored = try await send(manager, "list")["projects"].array.first { $0["id"].string == periodicID }
        expect(scheduledRestored?["nextRunAt"] == automaticFirst["nextRunAt"], "the next periodic run time survives restart")
        if !CommandLine.arguments.contains("--quick") {
            let automaticSecond = try await automatic(manager, id: periodicID, after: firstSuccess, timeout: 65)
            expect(automaticSecond["outputDirectory"] != automaticFirst["outputDirectory"], "a periodic run publishes fresh offline bytes without a manual command")
            let (pauseStatsData, _) = try await URLSession.shared.data(from: URL(string: base + "/stats")!)
            let pauseStats = try JSONSerialization.jsonObject(with: pauseStatsData) as! [[String]]
            expect(pauseStats.filter { $0[0] == "/slow" }.count == 1, "manual stop remains paused beyond its automatic interval")
        }
        _ = try await send(manager, "stop", ["id": .string(periodicID)])

        for (path, additions) in [("/outside", [:]), ("/oversize", [:]), ("/stream-limit", ["maxResourceBytes": JSONValue.number(4096)]), ("/site/index.html", ["maxFiles": .number(1)]), ("/slow", ["maxDurationSeconds": .number(1)]), ("/site/index.html", ["maxTotalBytes": .number(1024)])] {
            var invalid = definition; invalid["sourceURL"] = .string(base + path); invalid.merge(additions) { _, value in value }
            let project = try await send(manager, "save", ["project": .object(invalid)])["project"]
            _ = try await send(manager, "run", ["id": project["id"]])
            let result = try await settled(manager, id: project["id"].string)
            expect(result["status"].string == "error" && result["outputDirectory"].string.isEmpty, "\(path) is rejected without publishing output")
        }
        let raceDestination = root.appendingPathComponent("race-output")
        try FileManager.default.createDirectory(at: raceDestination, withIntermediateDirectories: true)
        var race = definition; race["name"] = .string("Destination race"); race["sourceURL"] = .string(base + "/delay"); race["destinationDirectory"] = .string(raceDestination.path)
        let raceProject = try await send(manager, "save", ["project": .object(race)])["project"]
        _ = try await send(manager, "run", ["id": raceProject["id"]])
        try await Task.sleep(nanoseconds: 200_000_000)
        try FileManager.default.moveItem(at: raceDestination, to: raceDestination.appendingPathExtension("original"))
        try FileManager.default.createSymbolicLink(at: raceDestination, withDestinationURL: destination)
        let raced = try await settled(manager, id: raceProject["id"].string)
        expect(raced["status"].string == "error" && raced["outputDirectory"].string.isEmpty, "replacing the destination with a symlink during capture prevents publication")
        expect(try FileManager.default.contentsOfDirectory(atPath: raceDestination.appendingPathExtension("original").path).isEmpty, "a destination changed during capture receives no snapshot files")
        let linked = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: destination)
        await rejected("symlink destinations are rejected") {
            var bad = definition; bad["destinationDirectory"] = .string(linked.path)
            _ = try await send(manager, "save", ["project": .object(bad)])
        }
        let moved = root.appendingPathComponent("original-output")
        try FileManager.default.moveItem(at: destination, to: moved)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try Data("replacement-directory".utf8).write(to: destination.appendingPathComponent("sentinel"))
        _ = try await send(manager, "run", ["id": .string(id)])
        let replaced = try await settled(manager, id: id)
        expect(replaced["status"].string == "error" && replaced["outputDirectory"] == updated["outputDirectory"], "a replaced destination directory is never adopted on a later run")
        expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["sentinel"], "replacement destination is untouched")
        _ = try await send(manager, "delete", ["id": .string(id)])
        expect(FileManager.default.fileExists(atPath: moved.appendingPathComponent(output.lastPathComponent + "/index.html").path), "deleting a project retains its snapshots")
        let (statsData, _) = try await URLSession.shared.data(from: URL(string: base + "/stats")!)
        let stats = try JSONSerialization.jsonObject(with: statsData) as! [[String]]
        expect(!stats.contains { ["/foreign", "/site/excluded.html", "/site/grandchild.html", "/assets/danger.js", "/assets/fake.png"].contains($0[0]) }, "origin, exclude, depth and script restrictions prevent unwanted requests")
        expect(stats.filter { $0[0].hasPrefix("/assets/") }.allSatisfy { $0[1] == "fixture=session" }, "captured resources receive exact-origin scoped session headers")
        await manager.stop()
        await rejected("commands are rejected after shutdown") { _ = try await send(manager, "list") }
        print("Website project checks: \(assertions) assertions, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
