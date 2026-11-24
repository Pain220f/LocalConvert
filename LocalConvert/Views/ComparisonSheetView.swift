import AppKit
import SwiftUI

/// Before/after inspection: exact size comparison, visual comparison (side by side, slider,
/// CoreImage difference) and a technical metadata diff.
struct ComparisonSheetView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case sideBySide = "Side by Side"
        case slider = "Slider"
        case difference = "Difference"
        var id: String { rawValue }
    }

    let job: ConversionJob
    @Environment(\.dismiss) private var dismiss

    @State private var mode: Mode = .slider
    @State private var before: CGImage?
    @State private var after: CGImage?
    @State private var difference: CGImage?
    @State private var isLoading = true
    @State private var rows: [MetadataDiffRow] = []
    @State private var showOnlyChanges = true
    @State private var sliderPosition = 0.5

    private var isRasterComparison: Bool {
        job.category == .image && !job.isCombined && job.target.imageIOTypeIdentifier != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let delta = job.sizeDelta { SizeComparisonView(delta: delta) }
            visual
            metadata
            footer
        }
        .padding(20)
        .frame(minWidth: 860, idealWidth: 1000, minHeight: 720, idealHeight: 820)
        .task { await load() }
        .task(id: mode) { await loadDifferenceIfNeeded() }
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(job.displayName).font(.title2.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 8) {
                    Text("\(job.sourceType.preferredFilenameExtension?.uppercased() ?? job.category.displayName) → \(job.target.displayName)")
                        .foregroundStyle(.secondary)
                    if let output = job.output {
                        FidelityBadge(fidelity: output.fidelity)
                        VerificationLabel(result: output.verification)
                    }
                }
            }
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private var visual: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isRasterComparison {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 380)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .underPageBackgroundColor))
                if isLoading {
                    ProgressView("Rendering previews…")
                } else if let before, let after {
                    switch (isRasterComparison ? mode : .sideBySide) {
                    case .sideBySide:
                        HStack(spacing: 12) {
                            ImagePanel(title: "Before", image: before)
                            ImagePanel(title: "After", image: after)
                        }
                        .padding(10)
                    case .slider:
                        SliderComparisonView(before: before, after: after, position: $sliderPosition)
                            .padding(10)
                    case .difference:
                        if let difference {
                            ImagePanel(title: "|After − Before| × 8   (black = identical)", image: difference)
                                .padding(10)
                        } else {
                            ProgressView("Computing difference…")
                        }
                    }
                } else {
                    ContentUnavailableView("No preview available", systemImage: "eye.slash",
                                           description: Text("Quick Look could not render this file type."))
                }
            }
            .frame(minHeight: 340)
            if isRasterComparison, mode == .slider {
                Slider(value: $sliderPosition, in: 0...1) { Text("Split") }
                    .labelsHidden()
            }
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Metadata").font(.headline)
                Spacer()
                Toggle("Show only differences", isOn: $showOnlyChanges).toggleStyle(.checkbox)
            }
            let visible = showOnlyChanges ? rows.filter { $0.change != .same } : rows
            Table(visible) {
                TableColumn("Key") { row in
                    Text(row.key).foregroundStyle(color(for: row.change))
                }
                .width(min: 160, ideal: 240)
                TableColumn("Before") { row in Text(row.before ?? "—").textSelection(.enabled) }
                TableColumn("After") { row in Text(row.after ?? "—").textSelection(.enabled) }
            }
            .frame(minHeight: 160)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let output = job.output {
                ForEach(output.notes, id: \.self) { note in
                    Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }
                Text("Engine: \(output.engineName) · \(output.fileCount) file(s) · \(output.elapsed.formatted(.units(allowed: [.seconds, .milliseconds], width: .abbreviated)))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func color(for change: MetadataDiffRow.Change) -> Color {
        switch change {
        case .same: .primary
        case .changed: .orange
        case .added: .green
        case .removed: .red
        }
    }

    // MARK: Loading

    private func load() async {
        guard let output = job.output else { isLoading = false; return }
        let source = job.primaryURL
        let raster = isRasterComparison
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        async let beforeImage = raster ? PreviewLoader.image(at: source) : PreviewLoader.thumbnail(for: source)
        async let afterImage = raster ? PreviewLoader.image(at: output.url) : PreviewLoader.thumbnail(for: output.url)
        async let beforeMeta = MetadataInspector.inspect(source)
        async let afterMeta = MetadataInspector.inspect(output.url)

        before = await beforeImage
        after = await afterImage
        isLoading = false
        rows = MetadataInspector.diff(before: await beforeMeta, after: await afterMeta)
    }

    private func loadDifferenceIfNeeded() async {
        guard mode == .difference, difference == nil else { return }
        while isLoading { try? await Task.sleep(for: .milliseconds(50)) }
        guard let before, let after else { return }
        difference = await PreviewLoader.difference(before, after)
    }
}

// MARK: - Components

private struct ImagePanel: View {
    let title: String
    let image: CGImage

    var body: some View {
        VStack(spacing: 6) {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
        }
    }
}

private struct SliderComparisonView: View {
    let before: CGImage
    let after: CGImage
    @Binding var position: Double

    var body: some View {
        GeometryReader { geometry in
            let fitted = fittedSize(for: CGSize(width: after.width, height: after.height), in: geometry.size)
            ZStack(alignment: .topLeading) {
                Image(decorative: after, scale: 1)
                    .resizable().interpolation(.none)
                    .frame(width: fitted.width, height: fitted.height)
                Image(decorative: before, scale: 1)
                    .resizable().interpolation(.none)
                    .frame(width: fitted.width, height: fitted.height)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: fitted.width * position)
                    }
                Rectangle()
                    .fill(.white)
                    .frame(width: 2, height: fitted.height)
                    .shadow(radius: 2)
                    .offset(x: fitted.width * position - 1)
                tag("BEFORE").padding(8)
                tag("AFTER")
                    .padding(8)
                    .frame(width: fitted.width, alignment: .trailing)
            }
            .frame(width: fitted.width, height: fitted.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                position = min(max(value.location.x / max(fitted.width, 1), 0), 1)
            })
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.black.opacity(0.55), in: Capsule())
            .foregroundStyle(.white)
    }

    private func fittedSize(for image: CGSize, in bounds: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return .zero }
        let scale = min(bounds.width / image.width, bounds.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }
}

/// Proportional before/after bars with exact byte counts.
struct SizeComparisonView: View {
    let delta: SizeDelta

    var body: some View {
        let maximum = Double(max(delta.before, delta.after, 1))
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            bar(label: "Before", bytes: delta.before, fraction: Double(delta.before) / maximum, color: .secondary)
            bar(label: "After", bytes: delta.after, fraction: Double(delta.after) / maximum,
                color: delta.isSmaller ? .green : (delta.delta == 0 ? .secondary : .orange))
            GridRow {
                Text("Δ").foregroundStyle(.secondary)
                Text("\(delta.formattedExactDelta)  (\(delta.formattedPercent))")
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(delta.isSmaller ? .green : (delta.delta == 0 ? .secondary : .orange))
                    .gridCellColumns(2)
            }
        }
    }

    private func bar(label: String, bytes: Int64, fraction: Double, color: Color) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: 4)
                    .fill(color.opacity(0.7))
                    .frame(width: max(2, geometry.size.width * fraction))
            }
            .frame(height: 14)
            Text("\(ByteCount.format(bytes))  ·  \(ByteCount.exact(bytes))")
                .font(.callout.monospacedDigit())
                .frame(width: 260, alignment: .trailing)
        }
    }
}
