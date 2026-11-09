import AppKit
import CurrentCore
import SwiftUI

struct DownloadInspector: View {
    @ObservedObject var model: AppModel
    @ViewState<Bool> private var refreshExpanded = false
    @ViewState<String> private var refreshURL = ""
    @ViewState<String?> private var refreshError: String?
    @ViewState<Bool> private var refreshing = false

    var body: some View {
        Group {
            if let job = model.selectedJob {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header(job)
                        if let error = job.error, !error.isEmpty {
                            Label {
                                Text(error).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                            .font(.callout)
                            .foregroundColor(.red)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                        }
                        transfer(job)
                        Divider()
                        location(job)
                        Divider()
                        source(job)
                        Divider()
                        organization(job)
                        if let scan = job.scanResult, !scan.isEmpty {
                            Divider()
                            VStack(alignment: .leading, spacing: 6) {
                                Text("File scan").font(.headline)
                                Text(scan).font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                            }
                        }
                        Divider()
                        Button("Remove from list…") { model.requestRemoval(ids: [job.id]) }
                            .buttonStyle(.borderless)
                        Button("Delete downloaded file…", role: .destructive) { model.requestRemoval(ids: [job.id], deleteFiles: true) }
                            .buttonStyle(.borderless)
                    }
                    .padding(20)
                }
                .onChange(of: job.id) { _ in resetRefresh() }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: model.selectedIDs.isEmpty ? "info.circle" : "square.stack")
                        .font(.system(size: 30, weight: .light))
                    Text(model.selectedIDs.isEmpty ? "Select a download" : "\(model.selectedIDs.count) downloads selected")
                        .font(.headline)
                    Text(model.selectedIDs.isEmpty ? "Its source, progress, and file actions will appear here." : "Use the toolbar to pause, resume, or cancel these downloads together.")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 230)
                }
                .foregroundColor(.secondary)
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func header(_ job: DownloadJob) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(nsImage: Display.icon(for: job))
                .resizable().frame(width: 48, height: 48)
                .accessibilityHidden(true)
            Text(job.filename)
                .font(.system(size: 17, weight: .semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Label(job.status.title, systemImage: job.status.symbol)
                .font(.callout)
                .foregroundColor(job.status == .error ? .red : (job.status == .complete ? .green : .secondary))
            HStack {
                if [.active, .waiting].contains(job.status) {
                    Button("Pause") { model.perform("pause", ids: [job.id]) }
                } else if job.status == .paused {
                    Button("Resume") { model.perform("resume", ids: [job.id]) }.buttonStyle(.borderedProminent)
                } else if [.error, .cancelled].contains(job.status) {
                    Button("Retry") { model.perform("retry", ids: [job.id]) }.buttonStyle(.borderedProminent)
                }
                if [.active, .waiting, .paused].contains(job.status) {
                    Button("Cancel") { model.perform("cancel", ids: [job.id]) }
                }
                if job.status == .complete {
                    Button("Open file") { model.open(job) }.buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func transfer(_ job: DownloadJob) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Transfer").font(.headline)
                Spacer()
                Text("\(Int(job.progress * 100))%")
                    .font(.caption).foregroundColor(.secondary).monospacedDigit()
            }
            ProgressView(value: job.status == .complete ? 1 : job.progress)
            metadata("Downloaded", Display.bytes(job.completedBytes))
            metadata("File size", job.totalBytes > 0 ? Display.bytes(job.totalBytes) : "Unknown")
            metadata("Speed", Display.speed(job.bytesPerSecond))
            metadata("Time remaining", Display.remaining(job.remainingSeconds))
            metadata("Connections", "\(job.connections) of \(job.request.connections)")
            metadata("Added", job.createdAt.formatted(date: .abbreviated, time: .shortened))
            if let completed = job.completedAt { metadata("Completed", completed.formatted(date: .abbreviated, time: .shortened)) }
            if let checksum = job.request.checksum, !checksum.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Checksum").foregroundColor(.secondary)
                    Text(checksum).textSelection(.enabled).lineLimit(4)
                }.font(.caption)
            }
        }
    }

    private func location(_ job: DownloadJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Saved to").font(.headline)
            Text(job.directory).font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Button { model.reveal(job) } label: { Label("Reveal in Finder", systemImage: "folder") }
                .buttonStyle(.borderless)
        }
    }

    private func source(_ job: DownloadJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Source").font(.headline)
            ForEach(Array(job.request.urls.enumerated()), id: \.offset) { _, url in
                Text(Display.safeURL(url)).font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if job.request.urls.count > 1 { Text("\(job.request.urls.count) mirrors").font(.caption).foregroundColor(.secondary) }
            if job.status != .complete {
              DisclosureGroup("Refresh download URL", isExpanded: $refreshExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Replace an expired source address while keeping the same destination. Resume only if the new address serves the same file.")
                        .font(.caption).foregroundColor(.secondary)
                    TextField("New URL", text: $refreshURL)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Replacement download URL")
                    if let refreshError { Text(refreshError).font(.caption).foregroundColor(.red) }
                    Button(refreshing ? "Updating…" : "Update URL") { refresh(job) }
                        .disabled(refreshing || refreshURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.top, 8)
            }
              .font(.callout)
            }
        }
    }

    private func organization(_ job: DownloadJob) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Organization").font(.headline)
            Picker("Queue", selection: Binding(get: { job.request.queueID }, set: { id in
                model.perform("move", ids: [job.id], extra: ["queueID": .string(id)])
            })) {
                ForEach(model.state.queues) { queue in Text(queue.name).tag(queue.id) }
            }
            .pickerStyle(.menu)
            Picker("Priority", selection: Binding(get: { job.priority }, set: { priority in
                model.perform("priority", ids: [job.id], extra: ["priority": .number(Double(priority))])
            })) {
                Text("High").tag(10)
                Text("Normal").tag(0)
                Text("Low").tag(-10)
                if ![10, 0, -10].contains(job.priority) { Text("\(job.priority)").tag(job.priority) }
            }
            .pickerStyle(.menu)
            metadata("Category", model.state.categories.first(where: { $0.id == job.categoryID })?.name ?? job.categoryID)
        }
        .font(.callout)
    }

    private func metadata(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundColor(.secondary)
            Spacer(minLength: 12)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.caption)
    }

    private func refresh(_ job: DownloadJob) {
        refreshing = true
        refreshError = nil
        Task {
            defer { refreshing = false }
            do {
                try await model.send("refresh", ["id": .string(job.id), "url": .string(refreshURL.trimmingCharacters(in: .whitespacesAndNewlines))])
                resetRefresh()
            } catch { refreshError = error.localizedDescription }
        }
    }

    private func resetRefresh() {
        refreshURL = ""
        refreshError = nil
        refreshExpanded = false
    }
}
