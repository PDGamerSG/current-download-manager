import AppKit
import CurrentCore
import SwiftUI

struct PreferencesView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ViewState<AppSettings> private var draft: AppSettings
    @ViewState<String> private var rate: String
    @ViewState<String> private var quota: String
    @ViewState<Bool> private var saving = false
    @ViewState<String?> private var errorMessage: String?
    @ViewState<CurrentCore.Category?> private var editingCategory: CurrentCore.Category?
    @ViewState<Bool> private var showBrowserSetup = false

    init(model: AppModel) {
        self.model = model
        _draft = SwiftUI.State(initialValue: model.state.settings)
        _rate = SwiftUI.State(initialValue: Input.units(model.state.settings.speedLimit, multiplier: 1024))
        _quota = SwiftUI.State(initialValue: Input.units(model.state.settings.hourlyQuota, multiplier: 1_048_576))
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                general.tabItem { Label("General", systemImage: "gearshape") }
                network.tabItem { Label("Network", systemImage: "network") }
                categories.tabItem { Label("Categories", systemImage: "folder") }
                integration.tabItem { Label("Integration", systemImage: "puzzlepiece.extension") }
            }
            .padding(20)
            if let errorMessage { InlineError(message: errorMessage).padding(.horizontal, 24).padding(.bottom, 12) }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saving ? "Saving…" : "Save settings") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || !model.isConnected)
            }
            .padding(16)
        }
        .frame(width: 650, height: 590)
        .sheet(item: $editingCategory) { category in CategoryEditor(model: model, category: category) }
        .sheet(isPresented: $showBrowserSetup) { BrowserSetupView(model: model) }
    }

    private var general: some View {
        Form {
            Section("Downloads") {
                HStack {
                    TextField("Default folder", text: $draft.downloadDirectory)
                    Button("Choose…") { chooseFolder() }
                }
                Text("Automatic categories use subfolders inside this folder. A custom destination on a download takes precedence.")
                    .font(.caption).foregroundColor(.secondary)
                Stepper("Simultaneous downloads: \(draft.maxConcurrent)", value: $draft.maxConcurrent, in: 1...32)
            }
            Section("Notifications") {
                Toggle("Notify when a download completes", isOn: $draft.notifyOnCompletion)
                HStack {
                    Button("Allow notifications…") { model.requestNotificationPermission() }
                    Text(model.notificationStatus).font(.caption).foregroundColor(.secondary)
                }
                Text("Current sends completion alerts only when macOS has allowed notifications.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("Service") {
                LabeledContent("Connection", value: model.connectionMessage)
                Text(model.isAttached ? "Another Current process owns the running service. Quitting this window will leave that service running." : "Keep Current open to continue downloads and run scheduled queues. Closing the window keeps the app running.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var network: some View {
        Form {
            Section("Bandwidth") {
                TextField("Global rate limit (KiB/s)", text: $rate, prompt: Text("Unlimited"))
                TextField("Hourly quota (MiB)", text: $quota, prompt: Text("Unlimited"))
                Text("Leave blank or enter 0 for no limit. Individual downloads can also have their own rate limits.")
                    .font(.caption).foregroundColor(.secondary)
                if model.state.settings.hourlyQuota > 0 {
                    LabeledContent("Used this hour", value: Display.bytes(model.state.quotaBytes))
                }
            }
            Section("Proxy") {
                TextField("HTTP or HTTPS proxy", text: $draft.proxy, prompt: Text("http://proxy.example:8080"))
                Text("Leave blank to connect directly. Optional proxy credentials remain in private local settings.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var categories: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sort downloads automatically").font(.headline)
            Text("Rules match filename extensions or source domains. Edit a category to change its rules.")
                .font(.callout).foregroundColor(.secondary)
            List(model.state.categories) { category in
                HStack {
                    Image(systemName: category.symbol).foregroundColor(.accentColor).frame(width: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(category.name)
                        Text(category.extensions.isEmpty && category.hosts.isEmpty ? "Fallback category" : (category.extensions + category.hosts).joined(separator: ", "))
                            .font(.caption).foregroundColor(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button("Edit…") { editingCategory = category }
                }
                .padding(.vertical, 3)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            Button { editingCategory = CurrentCore.Category(id: UUID().uuidString, name: "", extensions: []) } label: {
                Label("Add category…", systemImage: "plus")
            }
            Text("Category edits save immediately.").font(.caption).foregroundColor(.secondary)
        }
        .padding(16)
    }

    private var integration: some View {
        Form {
            Section("Browser") {
                Button("Set up browser integration…") { showBrowserSetup = true }
                Text("Send links and supported media from Chrome, Edge, Brave, or Firefox using the Current extension.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("Clipboard") {
                Toggle("Offer to download copied links", isOn: $draft.clipboardDetection)
                Text("When Current is active, copied download links appear as an optional prompt. Nothing is added automatically.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("File scanning") {
                HStack {
                    TextField("Scanner executable", text: $draft.scannerPath, prompt: Text("Optional absolute path"))
                    Button("Choose…") { chooseScanner() }
                }
                Text("Current runs this executable after each completed download, passing the saved file as its only argument. Configure a scanner that supports this usage.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: draft.downloadDirectory)
        if panel.runModal() == .OK, let url = panel.url { draft.downloadDirectory = url.path }
    }

    private func chooseScanner() {
        let panel = NSOpenPanel()
        panel.title = "Choose scanner executable"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { draft.scannerPath = url.path }
    }

    private func save() {
        saving = true
        errorMessage = nil
        Task {
            defer { saving = false }
            do {
                draft.speedLimit = try Input.bytes(rate, multiplier: 1024, label: "Rate limit")
                draft.hourlyQuota = try Input.bytes(quota, multiplier: 1_048_576, label: "Hourly quota")
                _ = try draft.validated()
                try await model.send("settings", ["settings": try .from(draft)])
                dismiss()
            } catch { errorMessage = error.localizedDescription }
        }
    }
}
