import AppKit
import CurrentCore
import SwiftUI

struct CategoryEditor: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ViewState<CurrentCore.Category> private var category: CurrentCore.Category
    @ViewState<String> private var extensions: String
    @ViewState<String> private var hosts: String
    @ViewState<String> private var directory: String
    @ViewState<Bool> private var saving = false
    @ViewState<String?> private var errorMessage: String?
    @ViewState<Bool> private var confirmDelete = false

    init(model: AppModel, category: CurrentCore.Category) {
        self.model = model
        _category = SwiftUI.State(initialValue: category)
        _extensions = SwiftUI.State(initialValue: category.extensions.joined(separator: ", "))
        _hosts = SwiftUI.State(initialValue: category.hosts.joined(separator: ", "))
        _directory = SwiftUI.State(initialValue: category.directory ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeading(title: model.state.categories.contains(where: { $0.id == category.id }) ? "Edit category" : "New category", subtitle: "Group matching downloads and give them a folder of their own.", symbol: "folder")
            Form {
                TextField("Name", text: $category.name)
                TextField("File extensions", text: $extensions, prompt: Text("pdf, epub, txt"))
                Text("Separate extensions with commas. Omit the leading dot.").font(.caption).foregroundColor(.secondary)
                TextField("Source domains", text: $hosts, prompt: Text("example.com, downloads.example.org"))
                Text("Domain rules include subdomains. A file matches when either its extension or domain matches.")
                    .font(.caption).foregroundColor(.secondary)
                Section("Destination") {
                    HStack {
                        TextField("Custom folder", text: $directory, prompt: Text("Use default category folder"))
                        Button("Choose…") { chooseFolder() }
                    }
                    if !directory.isEmpty { Button("Use default folder") { directory = "" } }
                    Text("Leave blank to use a subfolder inside the default downloads folder. This applies to new downloads; saved files stay in their current folders.")
                        .font(.caption).foregroundColor(.secondary)
                }
                if category.id == "other" { Text("Other is the fallback category for files that do not match a rule.").font(.caption).foregroundColor(.secondary) }
                if let errorMessage { InlineError(message: errorMessage) }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if category.id != "other", model.state.categories.contains(where: { $0.id == category.id }) {
                    Button("Delete category…", role: .destructive) { confirmDelete = true }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saving ? "Saving…" : "Save category") { save() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(saving || category.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 570, height: 560)
        .confirmationDialog("Delete this category?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete category", role: .destructive) { delete() }
        } message: { Text("Existing downloads will stay in their current folders.") }
    }

    private func save() {
        saving = true
        errorMessage = nil
        Task {
            defer { saving = false }
            do {
                category.name = category.name.trimmingCharacters(in: .whitespacesAndNewlines)
                category.extensions = Input.list(extensions).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }.filter { !$0.isEmpty }
                category.hosts = Input.list(hosts)
                category.directory = Input.optional(directory)
                if let directory = category.directory {
                    guard directory.hasPrefix("/"), !directory.contains("\0") else {
                        throw CurrentError.invalid("Choose an absolute destination folder.")
                    }
                }
                try await model.send("category-save", ["category": try .from(category)])
                dismiss()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose category destination"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: Input.optional(directory) ?? model.state.settings.downloadDirectory)
        if panel.runModal() == .OK, let url = panel.url { directory = url.path }
    }

    private func delete() {
        Task {
            do {
                try await model.send("category-delete", ["id": .string(category.id)])
                if model.location == .category(category.id) { model.location = .all }
                dismiss()
            } catch { errorMessage = error.localizedDescription }
        }
    }
}
