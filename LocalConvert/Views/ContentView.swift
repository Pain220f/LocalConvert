import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var queue: ConversionQueueManager
    @State private var comparisonJob: ConversionJob?
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if queue.jobs.isEmpty {
                DropZoneView(isTargeted: isDropTargeted) { queue.addFromOpenPanel() }
            } else {
                List {
                    ForEach(queue.jobs) { job in
                        JobRowView(
                            job: job,
                            onConvert: { queue.convert(job) },
                            onCompare: { comparisonJob = job },
                            onSave: { Task { await queue.save(job) } },
                            onRemove: { queue.remove(job) }
                        )
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .overlay {
                    if isDropTargeted {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                            .padding(6)
                            .allowsHitTesting(false)
                    }
                }
            }
            Divider()
            SummaryBar(queue: queue)
        }
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
        ToolbarItemGroup(placement: .navigation) {
            Button { queue.addFromOpenPanel() } label: {
                Label("Add Files", systemImage: "plus")
            }
            .help("Add files or folders (⌘O)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $queue.stripMetadata) {
                Label("Strip Metadata", systemImage: queue.stripMetadata ? "location.slash.fill" : "location.slash")
            }
            .help("Remove EXIF, GPS, IPTC and XMP metadata (images) or container metadata (media)")

            Button { queue.combineImagesIntoPDF() } label: {
                Label("Combine into PDF", systemImage: "doc.on.doc")
            }
            .disabled(queue.imageJobs.isEmpty)
            .help("Compile every image in the list into one PDF without re-compressing")

            if queue.isRunning {
                Button { queue.cancelAll() } label: {
                    Label("Cancel", systemImage: "stop.fill")
                }
                .help("Cancel running conversions (⌘.)")
            } else {
                Button { queue.convertAll() } label: {
                    Label("Convert All", systemImage: "play.fill")
                }
                .disabled(!queue.canConvert)
                .help("Convert every pending file (⌘↩)")
            }

            Button { Task { await queue.exportAll() } } label: {
                Label("Export All", systemImage: "square.and.arrow.down.on.square")
            }
            .disabled(queue.completedJobs.isEmpty)
            .help("Save every converted file into a folder (⇧⌘E)")

            Button(role: .destructive) { queue.clear() } label: {
                Label("Clear", systemImage: "trash")
            }
            .disabled(queue.jobs.isEmpty)
            .help("Remove all files from the list")
        }
    }
}

// MARK: - Drop zone

private struct DropZoneView: View {
    let isTargeted: Bool
    let onChoose: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
                .symbolEffect(.bounce, value: isTargeted)
            Text("Drop files or folders here")
                .font(.title2.weight(.semibold))
            Text("Images · PDF · Audio · Video — converted entirely on this Mac.")
                .foregroundStyle(.secondary)
            Button("Choose Files…", action: onChoose)
                .controlSize(.large)
                .keyboardShortcut("o")
            VStack(alignment: .leading, spacing: 6) {
                formatLine("photo", "PNG · TIFF · HEIC · JPEG · BMP · GIF (+ RAW, WebP input)")
                formatLine("doc.richtext", "Images → PDF, PDF → pages, PDF → embedded images")
                formatLine("film", "MOV ⇄ MP4 remux, HEVC re-encode")
                formatLine("waveform", "ALAC · WAV · M4A passthrough")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 8)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                              style: StrokeStyle(lineWidth: 2, dash: [10, 6]))
                .background(RoundedRectangle(cornerRadius: 18).fill(isTargeted ? Color.accentColor.opacity(0.06) : .clear))
                .padding(24)
        }
    }

    private func formatLine(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
    }
}

// MARK: - Summary bar

private struct SummaryBar: View {
    let queue: ConversionQueueManager

    var body: some View {
        HStack(spacing: 16) {
            Label("100% on-device · network access blocked by App Sandbox", systemImage: "lock.shield.fill")
                .foregroundStyle(.green)
                .help("This app has no network entitlements. The operating system refuses any connection attempt.")
            Spacer()
            if let activity = queue.activity {
                ProgressView().controlSize(.small)
                Text(activity).foregroundStyle(.secondary).lineLimit(1)
                Divider().frame(height: 14)
            }
            Text("\(queue.jobs.count) file(s)")
                .foregroundStyle(.secondary)
            if let totals = queue.totals {
                Divider().frame(height: 14)
                Text("\(ByteCount.format(totals.before)) → \(ByteCount.format(totals.after))")
                    .monospacedDigit()
                    .help("\(ByteCount.exact(totals.before)) → \(ByteCount.exact(totals.after))")
                Text("\(totals.formattedDelta) (\(totals.formattedPercent))")
                    .monospacedDigit()
                    .fontWeight(.semibold)
                    .foregroundStyle(totals.isSmaller ? .green : (totals.delta == 0 ? .secondary : .orange))
                    .help(totals.formattedExactDelta)
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
