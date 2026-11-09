import CurrentCore
import SwiftUI

struct SiteGrabberView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ViewState<String> private var pageURL = ""
    @ViewState<String> private var extensions = "pdf, zip, mp4, mp3, jpg, png"
    @ViewState<Int> private var depth = 0
    @ViewState<[GrabbedLink]> private var links: [GrabbedLink] = []
    @ViewState<Set<String>> private var selected = Set<String>()
    @ViewState<String> private var queueID = "main"
    @ViewState<Bool> private var startPaused = false
    @ViewState<Bool> private var fetching = false
    @ViewState<Bool> private var saving = false
    @ViewState<Bool> private var didPreview = false
    @ViewState<String?> private var errorMessage: String?
    @ViewState<Task<Void, Never>?> private var previewTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeading(title: "Site grabber", subtitle: "Preview downloadable files on a website, then choose which ones to add.", symbol: "globe")
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    TextField("Page URL", text: $pageURL, prompt: Text("https://example.com/downloads"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { if !fetching { preview() } }
                    Button(fetching ? "Scanning…" : "Preview files") { preview() }
                        .disabled(fetching || pageURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.isConnected)
                }
                HStack {
                    TextField("Extensions", text: $extensions, prompt: Text("All downloadable types"))
                    Picker("Page depth", selection: $depth) {
                        Text("This page").tag(0)
                        Text("1 level").tag(1)
                        Text("2 levels").tag(2)
                        Text("3 levels").tag(3)
                    }
                    .frame(width: 190)
                }
                Text("Same website only; up to 50 pages and 500 files. Blank extensions include all non-page resources. Protected pages may require links sent from your browser instead.")
                    .font(.caption).foregroundColor(.secondary)
                if let errorMessage { InlineError(message: errorMessage) }
            }
            .padding(20)
            Divider()
            if fetching {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Finding matching files…").foregroundColor(.secondary)
                    Button("Stop scanning") { previewTask?.cancel() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if links.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: didPreview ? "doc.text.magnifyingglass" : "link").font(.system(size: 32, weight: .light))
                    Text(didPreview ? "No matching files found" : "Files will appear here")
                        .font(.headline)
                    Text(didPreview ? "Try different extensions or increase the page depth." : "Enter a page address and choose Preview files.")
                        .font(.callout)
                }
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Text("\(selected.count) of \(links.count) selected").font(.caption).foregroundColor(.secondary)
                        Spacer()
                        Button("Select all") { selected = Set(links.map(\.url)) }.buttonStyle(.borderless)
                        Button("Select none") { selected.removeAll() }.buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    List(links) { link in
                        Toggle(isOn: Binding(get: { selected.contains(link.url) }, set: { enabled in
                            if enabled { selected.insert(link.url) } else { selected.remove(link.url) }
                        })) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(link.filename).font(.system(size: 12, weight: .medium))
                                Text(Display.safeURL(link.url)).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            .padding(.vertical, 4)
                        }
                        .toggleStyle(.checkbox)
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                }
            }
            Divider()
            HStack {
                Picker("Queue", selection: $queueID) {
                    ForEach(model.state.queues) { queue in Text(queue.name).tag(queue.id) }
                }.frame(width: 210)
                Toggle("Add paused", isOn: $startPaused).toggleStyle(.checkbox)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saving ? "Adding…" : "Add selected") { addSelected() }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty || saving || fetching || !model.isConnected)
            }
            .padding(16)
        }
        .frame(width: 760, height: 630)
        .onDisappear { previewTask?.cancel() }
    }

    private func preview() {
        fetching = true
        errorMessage = nil
        selected.removeAll()
        previewTask = Task {
            defer { fetching = false }
            do {
                let result = try await model.send("grab", [
                    "url": .string(pageURL.trimmingCharacters(in: .whitespacesAndNewlines)),
                    "depth": .number(Double(depth)),
                    "extensions": .array(Input.list(extensions).map(JSONValue.string))
                ])
                try Task.checkCancellation()
                links = try result.decode([GrabbedLink].self)
                selected = Set(links.map(\.url))
                didPreview = true
            } catch is CancellationError {
                links = []
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func addSelected() {
        saving = true
        errorMessage = nil
        Task {
            defer { saving = false }
            do {
                let requests = links.filter { selected.contains($0.url) }.map { link in
                    var request = DownloadRequest(urls: [link.url], filename: link.filename)
                    request.queueID = queueID
                    request.startPaused = startPaused
                    return request
                }
                try await model.send("add", ["requests": try .from(requests)])
                dismiss()
            } catch { errorMessage = error.localizedDescription }
        }
    }
}
