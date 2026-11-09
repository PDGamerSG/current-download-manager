import Foundation

/// Registers a per-user native messaging host for local Chromium and Firefox extensions.
public enum BrowserInstaller {
    public static let hostName = "io.current.downloadmanager"
    public static let chromiumExtensionID = "ljmcdchlnbjjjbeljjlhdinmdcimngmm"
    public static let firefoxExtensionID = "current@current-downloadmanager.local"

    @discardableResult
    public static func install() throws -> String {
        let manager = FileManager.default
        let store = try StateStore()
        let executable = Bundle.main.executableURL
        let candidates: [URL?] = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/currentctl"),
            executable?.deletingLastPathComponent().appendingPathComponent("currentctl"),
            ToolLocator.find("currentctl")
        ]
        guard let tool = candidates.compactMap({ $0 }).first(where: { manager.isExecutableFile(atPath: $0.path) })?.resolvingSymlinksInPath() else {
            throw CurrentError.invalid("Cannot locate currentctl. Run install-browser-host from the installed Current app or its bundled currentctl.")
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.directory.path)
        let hostDirectory = store.directory.appendingPathComponent("browser-host", isDirectory: true)
        try manager.createDirectory(at: hostDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hostDirectory.path)
        let wrapper = hostDirectory.appendingPathComponent("current-native-host")
        let quotedTool = "'" + tool.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = "#!/bin/sh\nexec \(quotedTool) native-host \"$@\"\n"
        try Data(script.utf8).write(to: wrapper, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)

        let support = manager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let chromiumDirectories = [
            "Google/Chrome/NativeMessagingHosts",
            "Google/Chrome Canary/NativeMessagingHosts",
            "Google/Chrome for Testing/NativeMessagingHosts",
            "Chromium/NativeMessagingHosts",
            "Microsoft Edge/NativeMessagingHosts",
            "BraveSoftware/Brave-Browser/NativeMessagingHosts"
        ]
        let base: [String: Any] = [
            "name": hostName, "description": "Current download manager browser bridge",
            "path": wrapper.path, "type": "stdio"
        ]
        var chromiumManifest = base
        chromiumManifest["allowed_origins"] = ["chrome-extension://\(chromiumExtensionID)/"]
        var firefoxManifest = base
        firefoxManifest["allowed_extensions"] = [firefoxExtensionID]
        let encoder: ([String: Any]) throws -> Data = { value in
            try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        }
        let chromeData = try encoder(chromiumManifest)
        let firefoxData = try encoder(firefoxManifest)
        for directory in chromiumDirectories {
            try installManifest(chromeData, directory: support.appendingPathComponent(directory, isDirectory: true))
        }
        try installManifest(firefoxData, directory: support.appendingPathComponent("Mozilla/NativeMessagingHosts", isDirectory: true))
        return "Browser host installed for Chrome, Chromium, Edge, Brave and Firefox at \(wrapper.path). Load the matching Current extension, then open its toolbar popup."
    }

    private static func installManifest(_ data: Data, directory: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let manifest = directory.appendingPathComponent(hostName + ".json")
        try data.write(to: manifest, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
    }
}
