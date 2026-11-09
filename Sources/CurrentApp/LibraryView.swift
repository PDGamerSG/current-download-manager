import AppKit
import CurrentCore
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @ObservedObject var model: AppModel
    @ViewState<Bool> private var dropTargeted = false

    var body: some View {
        let pendingRemoval = model.removal
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 185, ideal: 210, max: 280)
        } detail: {
            VStack(spacing: 0) {
                if !model.isConnected && !model.isStarting { connectionBanner }
                if let candidate = model.clipboardCandidate { clipboardBanner(candidate) }
                HSplitView {
                    downloadList.frame(minWidth: 490)
                    if model.showInspector {
                        DownloadInspector(model: model)
                            .frame(minWidth: 260, idealWidth: 290, maxWidth: 360)
                    }
                }
                statusBar
            }
            .navigationTitle((model.location ?? .all).title(in: model.state))
            .searchable(text: $model.search, placement: .toolbar, prompt: "Search downloads")
            .toolbar { toolbar }
            .onDrop(of: [UTType.url.identifier, UTType.plainText.identifier], isTargeted: $dropTargeted, perform: receiveDrop)
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(0.08))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2))
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .add(let seed): AddDownloadView(model: model, seed: seed)
            case .preferences: PreferencesView(model: model)
            case .queue(let queue): QueueEditor(model: model, queue: queue)
            case .category(let category): CategoryEditor(model: model, category: category)
            case .grabber: SiteGrabberView(model: model)
            case .browsers: BrowserSetupView(model: model)
            }
        }
        .alert(item: $model.notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("OK")))
        }
        .confirmationDialog(
            model.removal?.deleteFiles == true ? "Delete the selected files?" : "Remove the selected downloads?",
            isPresented: Binding(get: { model.removal != nil }, set: { if !$0 { model.removal = nil } }),
            titleVisibility: .visible
        ) {
            Button(model.removal?.deleteFiles == true ? "Delete files" : "Remove from list", role: .destructive) {
                if let pendingRemoval {
                    model.perform(pendingRemoval.deleteFiles ? "delete-file" : "remove", ids: pendingRemoval.ids)
                }
                model.removal = nil
            }
            Button("Cancel", role: .cancel) { model.removal = nil }
        } message: {
            Text(model.removal?.deleteFiles == true
                 ? "Current will cancel these transfers and permanently delete their downloaded files and partial data."
                 : "Current will cancel these transfers and remove them from the list. Downloaded files will stay in their folders.")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $model.location) {
                Section("Library") {
                    sidebarRow("All downloads", symbol: "tray.full", location: .all)
                    sidebarRow("Active", symbol: "arrow.down.circle", location: .active)
                    sidebarRow("Paused", symbol: "pause.circle", location: .paused)
                    sidebarRow("Completed", symbol: "checkmark.circle", location: .completed)
                    sidebarRow("Failed", symbol: "exclamationmark.triangle", location: .failed)
                }
                Section {
                    ForEach(model.state.categories) { category in
                        sidebarRow(category.name, symbol: category.symbol, location: .category(category.id))
                            .contextMenu {
                                Button("Edit category…") { model.sheet = .category(category) }
                            }
                    }
                } header: {
                    HStack {
                        Text("Categories")
                        Spacer()
                        Button { newCategory() } label: { Image(systemName: "plus") }
                            .buttonStyle(.borderless)
                            .help("Add category")
                            .accessibilityLabel("Add category")
                    }
                }
                Section {
                    ForEach(model.state.queues) { queue in
                        sidebarRow(queue.name, symbol: queue.enabled ? (queue.schedule == nil ? "line.3.horizontal.decrease.circle" : "calendar.badge.clock") : "pause.circle", location: .queue(queue.id))
                            .contextMenu {
                                Button("Edit queue…") { model.sheet = .queue(queue) }
                                Button(queue.enabled ? "Disable queue" : "Enable queue") {
                                    var changed = queue
                                    changed.enabled.toggle()
                                    Task {
                                        do { try await model.send("queue-save", ["queue": try .from(changed)]) }
                                        catch { model.show(error) }
                                    }
                                }
                            }
                    }
                } header: {
                    HStack {
                        Text("Queues")
                        Spacer()
                        Button { model.sheet = .queue(DownloadQueue()) } label: { Image(systemName: "plus") }
                            .buttonStyle(.borderless)
                            .help("Add queue")
                            .accessibilityLabel("Add queue")
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack(spacing: 10) {
                Menu {
                    Button("New queue…") { model.sheet = .queue(DownloadQueue()) }
                    Button("New category…") { newCategory() }
                    Divider()
                    Button("Site grabber…") { model.sheet = .grabber }
                    Button("Browser integration…") { model.sheet = .browsers }
                    Button("Settings…") { model.sheet = .preferences }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
                .help("Library actions")
                Spacer()
                Text("Current").font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private func sidebarRow(_ title: String, symbol: String, location: LibraryLocation) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer(minLength: 6)
            let count = model.state.jobs.filter { location.includes($0) }.count
            if count > 0 { Text(count.formatted()).font(.caption).foregroundColor(.secondary).monospacedDigit() }
        }
        .tag(location)
    }

    private var downloadList: some View {
        VStack(spacing: 0) {
            if case .queue(let id) = model.location, let queue = model.state.queues.first(where: { $0.id == id }) {
                HStack(spacing: 8) {
                    Image(systemName: queue.enabled ? "line.3.horizontal.decrease.circle" : "pause.circle")
                        .foregroundColor(.secondary)
                    Text(queue.enabled ? "Up to \(queue.maxConcurrent) at once" : "Queue disabled")
                    if queue.schedule != nil { Text("Scheduled").foregroundColor(.secondary) }
                    Spacer()
                    Button("Edit queue…") { model.sheet = .queue(queue) }
                        .buttonStyle(.borderless)
                }
                .font(.caption)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                Divider()
            }
            if model.visibleJobs.isEmpty {
                emptyState
            } else {
                HStack(spacing: 14) {
                    Text("File").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Progress").frame(width: 125, alignment: .leading)
                    Text("Speed").frame(width: 74, alignment: .trailing)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                Divider()
                List(selection: $model.selectedIDs) {
                    ForEach(model.visibleJobs) { job in
                        DownloadRow(job: job)
                            .tag(job.id)
                            .contextMenu { DownloadContextMenu(model: model, job: job) }
                            .onTapGesture(count: 2) { if job.status == .complete { model.open(job) } }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .onDeleteCommand { model.requestRemoval() }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: model.isStarting ? "arrow.down.circle" : "tray")
                .font(.system(size: 42, weight: .light))
                .foregroundColor(.secondary)
            Text(model.isStarting ? "Starting Current" : (model.search.isEmpty ? "No downloads here" : "No matching downloads"))
                .font(.title3.weight(.semibold))
            Text(model.isStarting ? "Connecting to the download engine…" : (model.search.isEmpty ? "Add a link, drop one into this window, or send it from your browser." : "Try another filename or source address."))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 330)
            if model.isStarting { ProgressView().controlSize(.small) }
            else if model.search.isEmpty {
                Button("Add download…") { model.sheet = .add("") }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.isConnected)
            }
            Spacer()
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var connectionBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
            Text(model.connectionMessage).font(.callout).textSelection(.enabled)
            Spacer()
            Button("Reconnect") { model.reconnect() }
        }
        .padding(12)
        .background(Color.orange.opacity(0.09))
    }

    private func clipboardBanner(_ candidate: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.on.clipboard")
            VStack(alignment: .leading, spacing: 2) {
                Text("Download the copied link?").font(.callout.weight(.medium))
                Text(Display.safeURL(candidate)).font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Add…") { model.clipboardCandidate = nil; model.sheet = .add(candidate) }
            Button { model.clipboardCandidate = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss copied link")
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.07))
    }

    private var statusBar: some View {
        HStack(spacing: 7) {
            Circle().fill(model.isConnected ? Color.green : Color.secondary).frame(width: 5, height: 5)
            Text(model.isStarting ? "Starting…" : "\(model.visibleJobs.count) downloads")
            if !model.selectedIDs.isEmpty { Text("\(model.selectedIDs.count) selected").foregroundColor(.secondary) }
            Spacer()
            if model.state.settings.speedLimit > 0 {
                Image(systemName: "speedometer")
                Text("Limit \(Display.speed(model.state.settings.speedLimit))")
                Spacer().frame(width: 8)
            }
            Image(systemName: "arrow.down")
            Text(Display.speed(model.totalSpeed)).monospacedDigit()
        }
        .font(.system(size: 11))
        .foregroundColor(.secondary)
        .padding(.horizontal, 15)
        .frame(height: 28)
        .background(.bar)
        .help(model.connectionMessage)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.sheet = .add("") } label: { Label("Add download", systemImage: "plus") }
                .keyboardShortcut("n")
                .help("Add download (⌘N)")
                .disabled(!model.isConnected)
            ControlGroup {
                Button { model.pauseSelection() } label: { Label("Pause", systemImage: "pause.fill") }
                    .disabled(!model.canPause)
                    .help("Pause selected downloads")
                Button { model.resumeSelection() } label: { Label("Resume", systemImage: "play.fill") }
                    .disabled(!model.canResume)
                    .help("Resume or retry selected downloads")
                Button { model.cancelSelection() } label: { Label("Cancel", systemImage: "xmark") }
                    .disabled(!model.canCancel)
                    .help("Cancel selected downloads")
            }
            Menu {
                Button("Site grabber…") { model.sheet = .grabber }
                Button("Browser integration…") { model.sheet = .browsers }
                Divider()
                Button("Import downloads…") { model.importDownloads() }
                Button("Export download list…") { model.exportDownloads() }
                Divider()
                Button("Settings…") { model.sheet = .preferences }
            } label: { Label("More", systemImage: "ellipsis.circle") }
            Button { model.showInspector.toggle() } label: { Label("Toggle inspector", systemImage: "sidebar.right") }
                .help("Show or hide inspector (⌥⌘I)")
        }
    }

    private func newCategory() {
        model.sheet = .category(CurrentCore.Category(id: UUID().uuidString, name: "", extensions: []))
    }

    private func receiveDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                let text: String?
                if let url = item as? URL { text = url.absoluteString }
                else if let data = item as? Data { text = URL(dataRepresentation: data, relativeTo: nil)?.absoluteString }
                else { text = item as? String }
                if let text { Task { @MainActor in model.acceptDroppedText(text) } }
            }
        } else {
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                let text = (item as? String) ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
                if let text { Task { @MainActor in model.acceptDroppedText(text) } }
            }
        }
        return true
    }
}

struct DownloadRow: View {
    let job: DownloadJob

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(nsImage: Display.icon(for: job))
                    .resizable().frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.filename).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 4) {
                        Image(systemName: job.status.symbol)
                        Text(job.status.title)
                        if let host = job.request.urls.first.flatMap({ URL(string: $0)?.host }) { Text("· \(host)").lineLimit(1) }
                    }
                    .font(.system(size: 11))
                    .foregroundColor(job.status == .error ? .red : .secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) {
                ProgressView(value: job.status == .complete ? 1 : job.progress)
                    .tint(job.status == .error ? .red : (job.status == .paused ? .gray : .accentColor))
                Text(job.totalBytes > 0 ? "\(Display.bytes(job.completedBytes)) of \(Display.bytes(job.totalBytes))" : Display.bytes(job.completedBytes))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: 125)
            Text(Display.speed(job.bytesPerSecond))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundColor(job.status == .active ? .primary : .secondary)
                .frame(width: 74, alignment: .trailing)
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(job.filename), \(job.status.title), \(Int(job.progress * 100)) percent, \(Display.speed(job.bytesPerSecond))")
    }
}

struct DownloadContextMenu: View {
    @ObservedObject var model: AppModel
    let job: DownloadJob

    private var ids: [String] { model.selectedIDs.contains(job.id) ? Array(model.selectedIDs) : [job.id] }
    private func ids(with statuses: [JobStatus]) -> [String] {
        model.state.jobs.filter { ids.contains($0.id) && statuses.contains($0.status) }.map(\.id)
    }

    var body: some View {
        if [.active, .waiting].contains(job.status) {
            Button("Pause") { model.perform("pause", ids: ids(with: [.active, .waiting])) }
        }
        if job.status == .paused { Button("Resume") { model.perform("resume", ids: ids(with: [.paused])) } }
        if [.error, .cancelled].contains(job.status) { Button("Retry") { model.perform("retry", ids: ids(with: [.error, .cancelled])) } }
        if [.active, .waiting, .paused].contains(job.status) { Button("Cancel download") { model.perform("cancel", ids: ids(with: [.active, .waiting, .paused])) } }
        Divider()
        Button("Open file") { model.open(job) }.disabled(job.status != .complete)
        Button("Reveal in Finder") { model.reveal(job) }
        Menu("Move to queue") {
            ForEach(model.state.queues) { queue in
                Button(queue.name) { model.perform("move", ids: ids, extra: ["queueID": .string(queue.id)]) }
            }
        }
        Menu("Priority") {
            Button("High") { model.perform("priority", ids: ids, extra: ["priority": .number(10)]) }
            Button("Normal") { model.perform("priority", ids: ids, extra: ["priority": .number(0)]) }
            Button("Low") { model.perform("priority", ids: ids, extra: ["priority": .number(-10)]) }
        }
        Divider()
        Button("Remove from list…") { model.requestRemoval(ids: ids) }
        Button("Delete downloaded files…", role: .destructive) { model.requestRemoval(ids: ids, deleteFiles: true) }
    }
}
