import CurrentCore
import SwiftUI

struct QueueEditor: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ViewState<DownloadQueue> private var queue: DownloadQueue
    @ViewState<Bool> private var scheduled: Bool
    @ViewState<Bool> private var daily: Bool
    @ViewState<Date> private var start: Date
    @ViewState<Bool> private var hasEnd: Bool
    @ViewState<Date> private var end: Date
    @ViewState<Bool> private var saving = false
    @ViewState<String?> private var errorMessage: String?
    @ViewState<Bool> private var confirmDelete = false

    init(model: AppModel, queue: DownloadQueue) {
        self.model = model
        _queue = SwiftUI.State(initialValue: queue)
        _scheduled = SwiftUI.State(initialValue: queue.schedule != nil)
        _daily = SwiftUI.State(initialValue: queue.schedule?.daily ?? false)
        _start = SwiftUI.State(initialValue: queue.schedule?.start ?? Date())
        _hasEnd = SwiftUI.State(initialValue: queue.schedule?.end != nil)
        _end = SwiftUI.State(initialValue: queue.schedule?.end ?? Date().addingTimeInterval(3600))
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeading(title: model.state.queues.contains(where: { $0.id == queue.id }) ? "Edit queue" : "New queue", subtitle: "Control how many files run together and when this queue can download.", symbol: "calendar.badge.clock")
            Form {
                Section {
                    TextField("Name", text: $queue.name)
                    Toggle("Queue enabled", isOn: $queue.enabled)
                    Stepper("Simultaneous downloads: \(queue.maxConcurrent)", value: $queue.maxConcurrent, in: 1...32)
                }
                Section("Schedule") {
                    Toggle("Use a scheduled window", isOn: $scheduled)
                    if scheduled {
                        Toggle("Repeat daily", isOn: $daily)
                        DatePicker(daily ? "First start" : "Start", selection: $start, displayedComponents: [.date, .hourAndMinute])
                        Toggle("Stop at an end time", isOn: $hasEnd)
                        if hasEnd {
                            DatePicker("End", selection: $end, displayedComponents: daily ? [.hourAndMinute] : [.date, .hourAndMinute])
                        }
                        Text(daily ? "The window repeats each day from the first start. An end time earlier than the start runs overnight." : "This queue becomes eligible at the start time and stops admitting transfers at its end time.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Text("Current must be running. A download you pause manually stays paused when its schedule opens.")
                        .font(.caption).foregroundColor(.secondary)
                }
                if let errorMessage { InlineError(message: errorMessage) }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if queue.id != "main", model.state.queues.contains(where: { $0.id == queue.id }) {
                    Button("Delete queue…", role: .destructive) { confirmDelete = true }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saving ? "Saving…" : "Save queue") { save() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(saving || queue.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 570, height: 570)
        .confirmationDialog("Delete this queue?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete queue", role: .destructive) { delete() }
        } message: { Text("Downloads in this queue will move to the main queue.") }
    }

    private func save() {
        saving = true
        errorMessage = nil
        Task {
            defer { saving = false }
            do {
                queue.name = queue.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if scheduled && hasEnd && !daily && end <= start { throw CurrentError.invalid("The end of a one-time window must be after its start.") }
                var normalizedEnd = end
                if scheduled && daily && hasEnd {
                    let calendar = Calendar.current
                    let time = calendar.dateComponents([.hour, .minute], from: end)
                    normalizedEnd = calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: start) ?? end
                    if normalizedEnd <= start { normalizedEnd = calendar.date(byAdding: .day, value: 1, to: normalizedEnd) ?? normalizedEnd.addingTimeInterval(86_400) }
                }
                queue.schedule = scheduled ? QueueSchedule(start: start, end: hasEnd ? normalizedEnd : nil, daily: daily) : nil
                try await model.send("queue-save", ["queue": try .from(queue)])
                dismiss()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func delete() {
        Task {
            do {
                try await model.send("queue-delete", ["id": .string(queue.id)])
                if model.location == .queue(queue.id) { model.location = .queue("main") }
                dismiss()
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

struct CategoryEditor: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ViewState<CurrentCore.Category> private var category: CurrentCore.Category
    @ViewState<String> private var extensions: String
    @ViewState<String> private var hosts: String
    @ViewState<Bool> private var saving = false
    @ViewState<String?> private var errorMessage: String?
    @ViewState<Bool> private var confirmDelete = false

    init(model: AppModel, category: CurrentCore.Category) {
        self.model = model
        _category = SwiftUI.State(initialValue: category)
        _extensions = SwiftUI.State(initialValue: category.extensions.joined(separator: ", "))
        _hosts = SwiftUI.State(initialValue: category.hosts.joined(separator: ", "))
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
        .frame(width: 570, height: 440)
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
                try await model.send("category-save", ["category": try .from(category)])
                dismiss()
            } catch { errorMessage = error.localizedDescription }
        }
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
