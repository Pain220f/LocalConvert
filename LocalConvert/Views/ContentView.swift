import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var queue: ConversionQueueManager
    @State private var selection: ConversionJob.ID?
    @State private var comparisonJob: ConversionJob?
    @State private var isDropTargeted = false

    /// The selected job, falling back to the first one so a single file shows its controls at once.
    private var selectedJob: ConversionJob? {
        queue.jobs.first { $0.id == selection } ?? queue.jobs.first
    }

    var body: some View {
        VStack(spacing: 0) {
            if queue.jobs.isEmpty {
                EmptyStateView(isTargeted: isDropTargeted) { queue.addFromOpenPanel() }
            } else {
                HStack(spacing: 0) {
                    FileListView(queue: queue, selectedID: selectedJob?.id, isDropTargeted: isDropTargeted) { job in
                        selection = job.id
                    }
                    .frame(minWidth: 360, maxWidth: .infinity)

                    Divider()

                    if let job = selectedJob {
                        JobInspectorView(
                            job: job,
                            queue: queue,
                            onCompare: { comparisonJob = job },
                            onSave: { Task { await queue.save(job) } }
                        )
                        .id(job.id)
                        .frame(width: 380)
                    }
                }
            }
            Divider()
            StatusBar(queue: queue)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .dropDestination(for: URL.self) { urls, _ in
            Task { await queue.add(urls) }
            return !urls.isEmpty
        } isTargeted: { isDropTargeted = $0 }
        .toolbar { toolbar }
        .sheet(item: $comparisonJob) { job in
            ComparisonSheetView(job: job)
        }
        .alert(queue.notice?.title ?? "", isPresented: Binding(
            get: { queue.notice != nil },
            set: { if !$0 { queue.notice = nil } }
        )) {
            Button("OK") { queue.notice = nil }
        } message: {
            Text(queue.notice?.message ?? "")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { queue.addFromOpenPanel() } label: {
                Label("Add", systemImage: "plus")
            }
            .labelStyle(.titleAndIcon)
            .help("Add files or folders (⌘O)")
        }
        if !queue.jobs.isEmpty {
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: $queue.stripMetadata) {
                    Label("Strip Metadata", systemImage: queue.stripMetadata ? "location.slash.fill" : "location.slash")
                }
                .toggleStyle(.button)
                .labelStyle(.titleAndIcon)
                .help("Remove EXIF, GPS, IPTC and XMP (images) or container metadata (media)")

                Button { Task { await queue.exportAll() } } label: {
                    Label("Export All", systemImage: "square.and.arrow.down.on.square")
                }
                .labelStyle(.titleAndIcon)
                .disabled(queue.completedJobs.isEmpty)
                .help("Save every finished file into a folder (⇧⌘E)")

                Button { queue.clear() } label: {
                    Label("Clear", systemImage: "xmark.circle")
                }
                .labelStyle(.titleAndIcon)
                .help("Remove all files from the list")

                if queue.isRunning {
                    Button { queue.cancelAll() } label: {
                        Label("Cancel", systemImage: "stop.fill")
                    }
                    .labelStyle(.titleAndIcon)
                    .help("Cancel running jobs (⌘.)")
                } else {
                    Button { queue.convertAll() } label: {
                        Label(queue.runAllTitle, systemImage: "play.fill")
                    }
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(.borderedProminent)
                    .disabled(!queue.canConvert)
                    .help("Run every pending file (⌘↩)")
                }
            }
        }
    }
}

// MARK: - Empty state

private struct EmptyStateView: View {
    let isTargeted: Bool
    let onChoose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
                .symbolEffect(.bounce, value: isTargeted)
            Text("Drop files to convert or compress")
                .font(.title2.weight(.semibold))
            Button("Choose Files…", action: onChoose)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Text("Images · PDF · Audio · Video")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 460, maxHeight: 320)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                              style: StrokeStyle(lineWidth: 1.5, dash: [8, 6]))
                .background(RoundedRectangle(cornerRadius: 20).fill(isTargeted ? Color.accentColor.opacity(0.06) : .clear))
                .frame(maxWidth: 560, maxHeight: 360)
        }
        .padding(32)
    }
}

// MARK: - File list

private struct FileListView: View {
    let queue: ConversionQueueManager
    let selectedID: ConversionJob.ID?
    let isDropTargeted: Bool
    let onSelect: (ConversionJob) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(queue.jobs.count == 1 ? "1 file" : "\(queue.jobs.count) files")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if queue.imageJobs.count >= 2 {
                        Button("Combine Images into PDF") { queue.combineImagesIntoPDF() }
                            .buttonStyle(.link)
                            .help("Add a job that compiles every image into one PDF")
                    }
                }
                .padding(.horizontal, 4)

                LazyVStack(spacing: 8) {
                    ForEach(queue.jobs) { job in
                        JobRowView(job: job, isSelected: job.id == selectedID) { queue.remove(job) }
                            .onTapGesture { onSelect(job) }
                    }
                }
            }
            .padding(16)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Status bar

private struct StatusBar: View {
    let queue: ConversionQueueManager

    var body: some View {
        HStack(spacing: 14) {
            Label("100% on-device · Network blocked by App Sandbox", systemImage: "lock.shield.fill")
                .foregroundStyle(.green)
                .help("LocalConvert has no network entitlements. macOS refuses any connection attempt.")
            Spacer()
            if let activity = queue.activity {
                ProgressView().controlSize(.small)
                Text(activity).foregroundStyle(.secondary).lineLimit(1)
            }
            if let totals = queue.totals {
                Text("\(ByteCount.format(totals.before)) → \(ByteCount.format(totals.after))")
                    .monospacedDigit()
                    .help("\(ByteCount.exact(totals.before)) → \(ByteCount.exact(totals.after))")
                Text(totals.formattedPercent)
                    .monospacedDigit()
                    .fontWeight(.semibold)
                    .foregroundStyle(totals.isSmaller ? .green : (totals.delta == 0 ? .secondary : .orange))
                    .help(totals.formattedExactDelta)
            }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
