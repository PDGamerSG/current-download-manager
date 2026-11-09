import CurrentCore
import AppKit
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
    @ViewState<String> private var workflow = "files"
    @ViewState<[WebsiteProject]> private var projects = []
    @ViewState<String?> private var editingProjectID: String?
    @ViewState<String> private var projectName = ""
    @ViewState<String> private var outputFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
    @ViewState<String> private var captureMode = "site"
    @ViewState<Int> private var projectDepth = 1
    @ViewState<String> private var includePatterns = ""
    @ViewState<String> private var excludePatterns = ""
    @ViewState<Int> private var repeatMinutes = 0
    @ViewState<Bool> private var scheduleEnabled = false
    @ViewState<Date> private var scheduledAt = Date().addingTimeInterval(3600)
    @ViewState<Bool> private var projectBusy = false
    @ViewState<Int> private var maximumFiles = 300
    @ViewState<Int> private var resourceMiB = 8
    @ViewState<Int> private var totalMiB = 64
    @ViewState<Int> private var durationSeconds = 120

    var body: some View {
        VStack(spacing: 0) {
            SheetHeading(title: "Site grabber", subtitle: "Find downloadable files or save a static website for offline reading.", symbol: "globe")
            Picker("Workflow", selection: $workflow) {
                Text("Download files").tag("files")
                Text("Offline website projects").tag("projects")
            }.pickerStyle(.segmented).padding(.horizontal, 20).padding(.bottom, 12)
            if workflow == "projects" {
                projectPane
            } else {
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
        }
        .frame(width: workflow == "projects" ? 820 : 760, height: workflow == "projects" ? 790 : 630)
        .onDisappear { previewTask?.cancel() }
    }

    private var projectPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Project name", text: $projectName)
                Button("New project") { resetProject() }
            }
            TextField("Source page URL", text: $pageURL, prompt: Text("https://example.com/docs/"))
            HStack {
                TextField("Snapshot folder", text: $outputFolder)
                Button("Choose folder…") { chooseProjectFolder() }
            }
            HStack {
                Picker("Capture", selection: $captureMode) {
                    Text("Linked pages and resources").tag("site")
                    Text("This page and its resources").tag("page")
                }
                Picker("Page depth", selection: $projectDepth) {
                    ForEach(0...5, id: \.self) { Text($0 == 0 ? "This page" : "\($0) levels").tag($0) }
                }.frame(width: 190).disabled(captureMode == "page")
            }
            HStack {
                TextField("Include pages (e.g. /docs/*)", text: $includePatterns)
                TextField("Exclude URLs (e.g. */logout*)", text: $excludePatterns)
            }
            Text("Separate URL patterns with commas; * matches any text. Include patterns filter linked pages; exclusions apply to pages and resources. Captures stay on the exact source origin.")
                .font(.caption).foregroundColor(.secondary)
            HStack {
                Picker("Repeat", selection: $repeatMinutes) {
                    Text("Manual").tag(0)
                    Text("Every minute").tag(1)
                    Text("Every 15 minutes").tag(15)
                    Text("Hourly").tag(60)
                    Text("Daily").tag(1440)
                }.frame(width: 240)
                Toggle("Start at", isOn: $scheduleEnabled).toggleStyle(.checkbox)
                if scheduleEnabled { DatePicker("", selection: $scheduledAt).labelsHidden() }
                Spacer()
            }
            DisclosureGroup("Capture limits") {
                HStack {
                    Stepper("\(maximumFiles) files", value: $maximumFiles, in: 1...500, step: 25)
                    Stepper("\(resourceMiB) MiB / file", value: $resourceMiB, in: 1...16)
                    Stepper("\(totalMiB) MiB total", value: $totalMiB, in: 1...128)
                    Stepper("\(durationSeconds) seconds", value: $durationSeconds, in: 15...300, step: 15)
                }.font(.caption).padding(.top, 8)
            }
            HStack {
                Text("Each successful run creates a new snapshot. Existing snapshots are retained; scripts and forms are disabled. JavaScript-generated pages may be incomplete.")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Button(editingProjectID == nil ? "Save project" : "Save changes") { saveProject() }
                    .buttonStyle(.borderedProminent)
                    .disabled(projectBusy || !model.isConnected || projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pageURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let errorMessage { InlineError(message: errorMessage) }
            Divider()
            HStack {
                Text("Saved projects").font(.headline)
                Spacer()
                Text("\(projects.count) projects").font(.caption).foregroundColor(.secondary)
            }
            if projects.isEmpty {
                Text("Save a project, then choose Run to create its first offline snapshot.")
                    .foregroundColor(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(projects) { project in projectRow(project) }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
            }
            HStack {
                Text("Stopping a project also pauses its scheduled runs. Run resumes them.").font(.caption).foregroundColor(.secondary)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(.horizontal, 20).padding(.bottom, 16)
        .task {
            while !Task.isCancelled {
                await refreshProjects()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func projectRow(_ project: WebsiteProject) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if project.status == "running" { ProgressView().controlSize(.small) }
                Text(project.name).fontWeight(.medium)
                Text(project.status.capitalized).font(.caption).foregroundColor(project.status == "error" ? .red : .secondary)
                Spacer()
                Button("Edit") { editProject(project) }.disabled(projectBusy || project.status == "running")
                Button("Run") { projectCommand("run", project: project) }.disabled(projectBusy || project.status == "running")
                Button("Stop") { projectCommand("stop", project: project) }
                    .disabled(projectBusy || (project.status != "running" && project.nextRunAt == nil))
                Button("Remove") { projectCommand("delete", project: project) }
                    .help("Remove this project; its offline snapshots are retained.").disabled(projectBusy)
            }
            Text(Display.safeURL(project.sourceURL)).font(.caption).foregroundColor(.secondary).lineLimit(1)
            HStack {
                if let success = project.lastSuccessAt {
                    Text("\(project.fileCount) files · \(ByteCountFormatter.string(fromByteCount: Int64(project.totalBytes), countStyle: .file)) · \(success.formatted(date: .abbreviated, time: .shortened))")
                }
                if let next = project.nextRunAt { Text("Next: \(next.formatted(date: .abbreviated, time: .shortened))") }
                Spacer()
                if let directory = project.outputDirectory, project.entryPath == "index.html" {
                    Button("Open website") { NSWorkspace.shared.open(URL(fileURLWithPath: directory).appendingPathComponent("index.html")) }
                    Button("Show folder") { NSWorkspace.shared.open(URL(fileURLWithPath: directory)) }
                }
            }.font(.caption).foregroundColor(.secondary)
            if let error = project.lastError { Text(error).font(.caption).foregroundColor(.red).textSelection(.enabled) }
        }.padding(.vertical, 6)
    }

    private func refreshProjects() async {
        guard model.isConnected else { return }
        do { projects = try await model.send("web-project-list")["projects"].decode([WebsiteProject].self) }
        catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
    }

    private func projectCommand(_ action: String, project: WebsiteProject) {
        projectBusy = true; errorMessage = nil
        Task {
            defer { projectBusy = false }
            do {
                _ = try await model.send("web-project-" + action, ["id": .string(project.id)])
                if action == "delete", editingProjectID == project.id { resetProject() }
                await refreshProjects()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func saveProject() {
        projectBusy = true; errorMessage = nil
        Task {
            defer { projectBusy = false }
            do {
                func patterns(_ raw: String) -> JSONValue {
                    .array(raw.components(separatedBy: CharacterSet(charactersIn: ",\n")).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.map(JSONValue.string))
                }
                var definition: [String: JSONValue] = [
                    "name": .string(projectName), "sourceURL": .string(pageURL), "destinationDirectory": .string(outputFolder),
                    "maxDepth": .number(Double(projectDepth)), "mode": .string(captureMode),
                    "includePatterns": patterns(includePatterns), "excludePatterns": patterns(excludePatterns),
                    "intervalSeconds": .number(Double(repeatMinutes * 60)),
                    "scheduledAt": scheduleEnabled ? try .from(scheduledAt) : .null,
                    "maxFiles": .number(Double(maximumFiles)), "maxResourceBytes": .number(Double(resourceMiB * 1024 * 1024)),
                    "maxTotalBytes": .number(Double(totalMiB * 1024 * 1024)), "maxDurationSeconds": .number(Double(durationSeconds))
                ]
                if let editingProjectID { definition["id"] = .string(editingProjectID) }
                let saved = try await model.send("web-project-save", ["project": .object(definition)])["project"].decode(WebsiteProject.self)
                editingProjectID = saved.id
                await refreshProjects()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func editProject(_ project: WebsiteProject) {
        editingProjectID = project.id; projectName = project.name; pageURL = project.sourceURL
        outputFolder = project.destinationDirectory; projectDepth = project.maxDepth; captureMode = project.mode
        includePatterns = project.includePatterns.joined(separator: ", "); excludePatterns = project.excludePatterns.joined(separator: ", ")
        repeatMinutes = (project.intervalSeconds ?? 0) / 60
        scheduleEnabled = project.scheduledAt != nil; scheduledAt = project.scheduledAt ?? Date().addingTimeInterval(3600)
        maximumFiles = project.maxFiles; resourceMiB = max(1, project.maxResourceBytes / 1024 / 1024)
        totalMiB = max(1, project.maxTotalBytes / 1024 / 1024); durationSeconds = project.maxDurationSeconds
        errorMessage = nil
    }

    private func resetProject() {
        editingProjectID = nil; projectName = ""; pageURL = ""; projectDepth = 1; captureMode = "site"
        includePatterns = ""; excludePatterns = ""; repeatMinutes = 0; scheduleEnabled = false
        maximumFiles = 300; resourceMiB = 8; totalMiB = 64; durationSeconds = 120; errorMessage = nil
    }

    private func chooseProjectFolder() {
        let panel = NSOpenPanel(); panel.title = "Choose a folder for offline website snapshots"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { outputFolder = url.path }
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
