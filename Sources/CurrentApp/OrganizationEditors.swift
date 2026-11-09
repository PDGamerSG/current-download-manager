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
    @ViewState<Set<Int>> private var weekdays: Set<Int>
    @ViewState<Bool> private var synchronizing: Bool
    @ViewState<Int> private var synchronizationMinutes: Int
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
        _weekdays = SwiftUI.State(initialValue: Set(queue.schedule?.weekdays ?? Array(1...7)))
        _synchronizing = SwiftUI.State(initialValue: queue.synchronizationIntervalSeconds != nil)
        _synchronizationMinutes = SwiftUI.State(initialValue: max(1, (queue.synchronizationIntervalSeconds ?? 3600) / 60))
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
                        Toggle("Repeat on selected days", isOn: $daily)
                        if daily {
                            HStack {
                                ForEach(1...7, id: \.self) { day in
                                    Toggle(Calendar.current.shortWeekdaySymbols[day - 1], isOn: Binding(get: { weekdays.contains(day) }, set: { selected in
                                        if selected { weekdays.insert(day) } else { weekdays.remove(day) }
                                    }))
                                    .toggleStyle(.button)
                                }
                            }
                            .accessibilityLabel("Days when the scheduled window starts")
                        }
                        DatePicker(daily ? "First start" : "Start", selection: $start, displayedComponents: [.date, .hourAndMinute])
                        Toggle("Stop at an end time", isOn: $hasEnd)
                        if hasEnd {
                            DatePicker("End", selection: $end, displayedComponents: daily ? [.hourAndMinute] : [.date, .hourAndMinute])
                        }
                        Text(daily ? "The window repeats on the selected days from the first start. Overnight windows belong to the day they start." : "This queue becomes eligible at the start time and stops admitting transfers at its end time.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Text("Current must be running. A download you pause manually stays paused when its schedule opens.")
                        .font(.caption).foregroundColor(.secondary)
                }
                Section("File updates") {
                    Toggle("Periodically check completed files", isOn: $synchronizing)
                    if synchronizing {
                        Stepper("Check every \(synchronizationMinutes) minutes", value: $synchronizationMinutes, in: 1...525600)
                    }
                    Text("Checks files with one HTTP or HTTPS source while this queue is eligible. Each verified update is saved as a new version; earlier files are kept. The first check downloads a version to establish server validators.")
                        .font(.caption).foregroundColor(.secondary)
                    Text("Servers without usable validators, and transfers through a configured proxy, may download a version on every check.")
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
        .frame(width: 620, height: 700)
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
                if scheduled && daily { queue.schedule?.weekdays = weekdays.sorted() }
                queue.synchronizationIntervalSeconds = synchronizing ? synchronizationMinutes * 60 : nil
                try queue.validate()
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
