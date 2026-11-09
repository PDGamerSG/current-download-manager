import AppKit
import CurrentCore
import SwiftUI

struct BrowserSetupView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ViewState<Int> private var browser = 0
    @ViewState<Bool> private var installing = false
    @ViewState<String?> private var result: String?
    @ViewState<String?> private var errorMessage: String?
    @ViewState<Bool> private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            SheetHeading(title: "Browser integration", subtitle: "Send download links, selected links, and supported media straight to Current.", symbol: "puzzlepiece.extension")
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("1. Install the browser connection").font(.headline)
                        Text("Register Current’s native messaging host for this macOS account. Keep the app in a permanent location before installing.")
                            .font(.callout).foregroundColor(.secondary)
                        Button(installing ? "Installing…" : "Install browser connection") { install() }
                            .disabled(installing || !model.isConnected)
                        if let result {
                            Label(result, systemImage: "checkmark.circle.fill")
                                .font(.caption).foregroundColor(.green).textSelection(.enabled)
                        }
                        if let errorMessage { InlineError(message: errorMessage) }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        Text("2. Load the Current extension").font(.headline)
                        Picker("Browser family", selection: $browser) {
                            Text("Chrome, Edge, Brave").tag(0)
                            Text("Firefox").tag(1)
                        }
                        .pickerStyle(.segmented)
                        if browser == 0 {
                            Text("Open chrome://extensions, turn on Developer mode, choose Load unpacked, and select the chromium folder from the extension archive.")
                                .font(.callout)
                            Text("Edge uses edge://extensions; Brave uses brave://extensions.")
                                .font(.caption).foregroundColor(.secondary)
                        } else {
                            Text("Open about:debugging#/runtime/this-firefox, choose Load Temporary Add-on, and select manifest.json in the firefox folder from the extension archive.")
                                .font(.callout)
                            Text("Temporary add-ons must be loaded again after Firefox restarts. Permanent installation requires a Mozilla-signed extension.")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        HStack {
                            Button(copied ? "Address copied" : "Copy extension page address") { copyAddress() }
                            Button("Open extension files…") { revealExtensions() }
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 9) {
                        Text("3. Choose what to capture").font(.headline)
                        Text("Pin Current to the browser toolbar. Use its popup or right-click a link to send a download. Automatic browser-download capture is off until you enable it in the extension.")
                            .font(.callout)
                        Text("Supported media includes directly downloadable files and clear streams handled by optional yt-dlp and ffmpeg. Some websites and protected media cannot be downloaded.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Text("Safari requires a separately signed Safari Web Extension container. It is not included in this release.")
                        .font(.caption).foregroundColor(.secondary)
                }
                .padding(24)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 670, height: 650)
        .onChange(of: browser) { _ in copied = false }
    }

    private func install() {
        installing = true
        errorMessage = nil
        result = nil
        Task {
            defer { installing = false }
            do { result = try await model.send("install-browser-host").string }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func copyAddress() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(browser == 0 ? "chrome://extensions" : "about:debugging#/runtime/this-firefox", forType: .string)
        copied = true
    }

    private func revealExtensions() {
        let manager = FileManager.default
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Extensions", isDirectory: true),
            Bundle.main.resourceURL?.appendingPathComponent("extensions", isDirectory: true),
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("extensions", isDirectory: true),
            URL(fileURLWithPath: manager.currentDirectoryPath).appendingPathComponent("extensions", isDirectory: true)
        ].compactMap { $0 }
        if let directory = candidates.first(where: { manager.fileExists(atPath: $0.path) }) {
            NSWorkspace.shared.open(directory)
        } else {
            errorMessage = "Extension files were not found beside this app. Extract the extension archive from the Current release, then load its chromium or firefox folder in your browser."
        }
    }
}
