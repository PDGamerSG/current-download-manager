import AppKit
import CurrentCore
import SwiftUI

struct AddDownloadView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ViewState<String> private var urlText: String
    @ViewState<Bool> private var mirrors = false
    @ViewState<String> private var directory = ""
    @ViewState<String> private var filename = ""
    @ViewState<String> private var queueID = "main"
    @ViewState<String> private var categoryID = ""
    @ViewState<Int> private var connections = 8
    @ViewState<String> private var speedLimit = ""
    @ViewState<String> private var checksum = ""
    @ViewState<String> private var username = ""
    @ViewState<String> private var password = ""
    @ViewState<String> private var headers = ""
    @ViewState<Bool> private var startPaused = false
    @ViewState<Bool> private var media = false
    @ViewState<Bool> private var advanced = false
    @ViewState<Bool> private var saving = false
    @ViewState<String?> private var errorMessage: String?

    init(model: AppModel, seed: String) {
        self.model = model
        _urlText = SwiftUI.State(initialValue: seed)
        if case .queue(let id) = model.location { _queueID = SwiftUI.State(initialValue: id) }
        if case .category(let id) = model.location { _categoryID = SwiftUI.State(initialValue: id) }
    }

    private var lines: [String] {
        urlText.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeading(title: "Add downloads", subtitle: "Paste one link per line. Current keeps partial downloads so you can resume later.", symbol: "arrow.down.circle")
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Download URLs").font(.headline)
                        TextEditor(text: $urlText)
                            .font(.system(size: 12))
                            .frame(height: 110)
                            .padding(5)
                            .background(Color(nsColor: .textBackgroundColor))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.25)))
                            .accessibilityLabel("Download URLs, one per line")
                        HStack {
                            Text("HTTP, HTTPS, FTP, or SFTP").font(.caption).foregroundColor(.secondary)
                            Spacer()
                            Button("Paste") { if let text = NSPasteboard.general.string(forType: .string) { urlText = text } }
                                .buttonStyle(.borderless)
                        }
                        if lines.count > 1 { Toggle("Use these addresses as mirrors for one file", isOn: $mirrors) }
                    }
                    Form {
                        HStack {
                            TextField("Save to", text: $directory, prompt: Text("Automatic: \(model.state.settings.downloadDirectory)"))
                            Button("Choose…") { chooseFolder() }
                        }
                        if lines.count <= 1 || mirrors {
                            TextField("Filename", text: $filename, prompt: Text("Use the server’s filename"))
                        }
                        Picker("Queue", selection: $queueID) {
                            ForEach(model.state.queues) { queue in Text(queue.name).tag(queue.id) }
                        }
                        Picker("Category", selection: $categoryID) {
                            Text("Automatic").tag("")
                            ForEach(model.state.categories) { category in Text(category.name).tag(category.id) }
                        }
                        Toggle("Add paused", isOn: $startPaused)
                    }
                    .formStyle(.columns)
                    DisclosureGroup("Advanced options", isExpanded: $advanced) {
                        Form {
                            Stepper("Connections: \(connections)", value: $connections, in: 1...16)
                            TextField("Rate limit (KiB/s)", text: $speedLimit, prompt: Text("Unlimited"))
                            if lines.count <= 1 || mirrors {
                                TextField("Checksum", text: $checksum, prompt: Text("sha-256=…"))
                            }
                            TextField("Username", text: $username)
                            SecureField("Password", text: $password)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Request headers").font(.caption).foregroundColor(.secondary)
                                TextEditor(text: $headers).font(.system(size: 12)).frame(height: 64)
                                    .padding(4)
                                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.25)))
                                    .accessibilityLabel("Request headers, Name colon Value on each line")
                                Text("One Name: Value pair per line. Headers and passwords stay private and are stripped from exports.")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Toggle("Download as media with yt-dlp", isOn: $media)
                            if media {
                                Text("Requires yt-dlp and, for merged streams, ffmpeg. Supports clear media on supported sites; unavailable tools are reported as an error.")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                        .formStyle(.columns)
                        .padding(.top, 12)
                    }
                    if let errorMessage { InlineError(message: errorMessage) }
                }
                .padding(24)
            }
            Divider()
            HStack {
                Text(lines.isEmpty ? "No links added" : "\(mirrors ? 1 : lines.count) \((mirrors ? 1 : lines.count) == 1 ? "download" : "downloads")")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saving ? "Adding…" : (startPaused ? "Add paused" : "Start downloads")) { add() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(lines.isEmpty || saving || !model.isConnected)
            }
            .padding(16)
        }
        .frame(width: 660)
        .frame(minHeight: 510, maxHeight: 760)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose download folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { directory = url.path }
    }

    private func add() {
        errorMessage = nil
        saving = true
        Task {
            defer { saving = false }
            do {
                guard !lines.isEmpty, lines.count <= 500 else { throw CurrentError.invalid("Add between 1 and 500 links at a time.") }
                let rate = try Input.bytes(speedLimit, multiplier: 1024, label: "Rate limit")
                let parsedHeaders = try Input.headers(headers)
                let sources = mirrors ? [lines] : lines.map { [$0] }
                let requests = try sources.map { urls -> DownloadRequest in
                    var request = DownloadRequest(urls: urls, filename: (lines.count <= 1 || mirrors) ? Input.optional(filename) : nil)
                    request.directory = Input.optional(directory)
                    request.queueID = queueID
                    request.categoryID = Input.optional(categoryID)
                    request.connections = connections
                    request.speedLimit = rate
                    request.checksum = (lines.count <= 1 || mirrors) ? Input.optional(checksum) : nil
                    request.username = Input.optional(username)
                    request.password = password.isEmpty ? nil : password
                    request.headers = parsedHeaders
                    request.startPaused = startPaused
                    request.kind = media ? .media : .file
                    return try request.validated()
                }
                try await model.send("add", ["requests": try .from(requests)])
                dismiss()
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

struct SheetHeading: View {
    let title: String
    let subtitle: String
    let symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: symbol).font(.system(size: 27, weight: .light)).foregroundColor(.accentColor)
                .frame(width: 34, height: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 20, weight: .semibold))
                Text(subtitle).font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}

struct InlineError: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout).foregroundColor(.red)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

enum Input {
    static func optional(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    static func bytes(_ value: String, multiplier: Int64, label: String) throws -> Int64 {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return 0 }
        guard text.range(of: #"^(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)$"#, options: .regularExpression) != nil,
              let units = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else {
            throw CurrentError.invalid("\(label) must be a nonnegative number.")
        }
        let scaled = NSDecimalNumber(decimal: units * Decimal(multiplier))
        guard scaled != .notANumber, scaled.compare(NSDecimalNumber(value: Int64.max)) != .orderedDescending else {
            throw CurrentError.invalid("\(label) is too large.")
        }
        guard scaled == .zero || scaled.compare(NSDecimalNumber.one) != .orderedAscending else {
            throw CurrentError.invalid("\(label) must be at least one byte, or 0 for unlimited.")
        }
        return scaled.int64Value
    }
    static func units(_ bytes: Int64, multiplier: Int64) -> String {
        bytes == 0 ? "" : NSDecimalNumber(value: bytes).dividing(by: NSDecimalNumber(value: multiplier)).stringValue
    }
    static func list(_ value: String) -> [String] {
        Array(Set(value.components(separatedBy: CharacterSet(charactersIn: ", \n\t"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })).sorted()
    }
    static func headers(_ value: String) throws -> [String: String] {
        var result: [String: String] = [:]
        for line in value.components(separatedBy: .newlines) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw CurrentError.invalid("Enter headers as Name: Value, one per line.") }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let content = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { throw CurrentError.invalid("A request header is missing its name.") }
            result[key] = content
        }
        return result
    }
}
