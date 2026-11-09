import AppKit
import CurrentCore
import SwiftUI

@main
struct CurrentDesktopApp: App {
    @NSApplicationDelegateAdaptor(CurrentAppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            LibraryView(model: model)
                .frame(minWidth: 1050, minHeight: 610)
                .accentColor(.blue)
                .onAppear { delegate.model = model }
                .task { await model.start() }
        }
        .defaultSize(width: 1260, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add download…") { model.sheet = .add("") }
                    .keyboardShortcut("n")
                Button("Import downloads…") { model.importDownloads() }
                    .keyboardShortcut("o")
                Button("Export download list…") { model.exportDownloads() }
                    .disabled(!model.isConnected)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.sheet = .preferences }
                    .keyboardShortcut(",")
            }
            CommandMenu("Downloads") {
                Button("Pause selected") { model.pauseSelection() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(!model.canPause)
                Button("Resume selected") { model.resumeSelection() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(!model.canResume)
                Button("Cancel selected") { model.cancelSelection() }
                    .disabled(!model.canCancel)
                Divider()
                Button("Reveal in Finder") { if let job = model.selectedJob { model.reveal(job) } }
                    .keyboardShortcut("r")
                    .disabled(model.selectedJob == nil)
                Button("Open file") { if let job = model.selectedJob { model.open(job) } }
                    .keyboardShortcut(.downArrow)
                    .disabled(model.selectedJob?.status != .complete)
                Button("Remove from list…") { model.requestRemoval() }
                    .keyboardShortcut(.delete)
                    .disabled(model.selectedIDs.isEmpty)
                Divider()
                Button("Site grabber…") { model.sheet = .grabber }
                Button("Browser integration…") { model.sheet = .browsers }
            }
            CommandGroup(after: .sidebar) {
                Button(model.showInspector ? "Hide inspector" : "Show inspector") { model.showInspector.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
    }
}

@MainActor
final class CurrentAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating, let model else { return .terminateNow }
        terminating = true
        Task {
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
