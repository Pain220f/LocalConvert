import SwiftUI

/// Focused controls for the selected file: mode, output format, size limit, result and actions.
struct JobInspectorView: View {
    let job: ConversionJob
    let queue: ConversionQueueManager
    let onCompare: () -> Void
    let onSave: () -> Void

    @State private var unit: SizeUnit

    init(job: ConversionJob, queue: ConversionQueueManager, onCompare: @escaping () -> Void, onSave: @escaping () -> Void) {
        self.job = job
        self.queue = queue
        self.onCompare = onCompare
        self.onSave = onSave
        _unit = State(initialValue: job.targetSizeBytes >= 1_000_000 ? .mb : .kb)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                if job.supportsCompression {
                    Picker("Mode", selection: Binding(get: { job.mode }, set: { job.setMode($0) })) {
                        ForEach(ConversionMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(job.isBusy)
                }

                formatSection

                if job.mode == .compressSize {
                    sizeLimitSection
                }

                resultSection

                actions
            }
            .padding(20)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: FileIconCache.icon(for: job.isCombined ? .pdf : job.sourceType))
                .resizable()
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.displayName)
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text("\(ByteCount.format(job.originalBytes)) · \(ByteCount.exact(job.originalBytes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Format

    private var formatSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(job.mode == .compressSize ? "Output format" : "Convert to")
            Picker("Output format", selection: Binding(get: { job.target }, set: { job.setTarget($0) })) {
                ForEach(job.availableTargets) { format in
                    Text(format.displayName).tag(format)
                }
            }
            .labelsHidden()
            .disabled(job.isBusy)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                FidelityBadge(fidelity: job.plannedFidelity)
                Text(fidelityHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var fidelityHint: String {
        if job.mode == .compressSize {
            if job.target.isLossyCapable {
                return job.targetMaxBytes == nil
                    ? "Smaller file at a balanced quality."
                    : "Highest quality that fits under your limit."
            }
            return "Lossless. Fails instead of losing quality if it can't fit."
        }
        return job.plannedFidelity.detail
    }

    // MARK: Size limit

    private var sizeLimitSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { job.targetMaxBytes != nil },
                set: { job.setTargetMaxBytes($0 ? job.targetSizeBytes : nil) }
            )) {
                SectionTitle("Keep under")
            }
            .toggleStyle(.switch)
            .disabled(job.isBusy)

            HStack(spacing: 8) {
                TextField("Size", value: Binding(
                    get: { Double(job.targetSizeBytes) / unit.bytes },
                    set: { value in
                        // Typed/pasted values are clamped before converting; non-finite input is ignored.
                        let bytes = (value * unit.bytes).rounded()
                        guard bytes.isFinite else { return }
                        job.setTargetMaxBytes(Int64(min(max(bytes, 0), Double(SafetyLimits.maxTargetBytes))))
                    }
                ), format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 96)

                Picker("Unit", selection: $unit) {
                    ForEach(SizeUnit.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 96)
            }
            .disabled(job.targetMaxBytes == nil || job.isBusy)

            presetChips

            if job.category == .image || job.category == .document || job.isCombined {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Allow downscaling dimensions if needed", isOn: Binding(
                        get: { job.allowResizeToFitTarget },
                        set: { job.setAllowResizeToFitTarget($0) }
                    ))
                    .disabled(job.targetMaxBytes == nil || job.isBusy)
                    if job.sourceType.conforms(to: .pdf) {
                        Text("For PDFs this rasterizes pages; text will no longer be selectable.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let limit = job.targetMaxBytes {
                Label(limitHelper(limit), systemImage: job.originalBytes <= limit ? "checkmark.circle" : "arrow.down.right.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func limitHelper(_ limit: Int64) -> String {
        if job.originalBytes <= limit {
            return "Already under \(ByteCount.format(limit)). The output will stay ≤ \(ByteCount.exact(limit))."
        }
        return "Output will be strictly ≤ \(ByteCount.format(limit)) (\(ByteCount.exact(limit))). Original: \(ByteCount.format(job.originalBytes))."
    }

    private var presetChips: some View {
        let presets = SizePreset.presets(for: job.originalBytes)
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(presets) { preset in
                let isCurrent = job.targetMaxBytes == preset.bytes
                Button {
                    unit = preset.bytes >= 1_000_000 ? .mb : .kb
                    job.setTargetMaxBytes(preset.bytes)
                } label: {
                    Text(preset.label)
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(isCurrent ? .accentColor : nil)
                .disabled(job.isBusy)
            }
        }
    }

    // MARK: Result

    @ViewBuilder
    private var resultSection: some View {
        switch job.status {
        case .pending, .cancelled:
            EmptyView()
        case .queued:
            Label("Waiting to start…", systemImage: "clock").foregroundStyle(.secondary)
        case let .converting(fraction):
            VStack(alignment: .leading, spacing: 6) {
                SectionTitle(job.mode == .compressSize ? "Compressing" : "Converting")
                ProgressView(value: fraction)
            }
        case .completed:
            if let output = job.output, let delta = job.sizeDelta {
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle("Result")
                    SizeComparisonView(delta: delta, limit: output.targetMaxBytes, compact: true)
                    HStack(spacing: 8) {
                        FidelityBadge(fidelity: output.fidelity)
                        VerificationLabel(result: output.verification)
                    }
                    ForEach(output.notes, id: \.self) { note in
                        Text(note).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case let .failed(message):
            VStack(alignment: .leading, spacing: 6) {
                Label("Couldn't finish", systemImage: "xmark.octagon.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text(message)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: Actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if job.output != nil {
                    Button("Compare", systemImage: "rectangle.split.2x1", action: onCompare)
                    Button("Save…", systemImage: "square.and.arrow.down", action: onSave)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(job.mode.verb, systemImage: "play.fill") { queue.convert(job) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!job.status.canStart)
                }
            }
            .controlSize(.large)

            if job.output != nil, job.status.canStart || job.status == .completed {
                Button("Run again with these settings") { job.reset(); queue.convert(job) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            if queue.jobs.count > 1 {
                Button("Apply these settings to all files") { queue.applySettingsToAll(from: job) }
                    .buttonStyle(.link)
                    .font(.caption)
                    .disabled(queue.isRunning)
            }
        }
    }
}

// MARK: - Supporting types

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

enum SizeUnit: String, CaseIterable, Identifiable {
    case kb, mb
    var id: String { rawValue }
    var label: String { self == .kb ? "KB" : "MB" }
    /// Decimal units, matching Finder and the sizes shown everywhere else in the app.
    var bytes: Double { self == .kb ? 1_000 : 1_000_000 }
}

/// One-click limits scaled to the file: proportional ones plus common caps below the original.
struct SizePreset: Identifiable, Hashable {
    let label: String
    let bytes: Int64
    var id: Int64 { bytes }

    static let commonCaps: [Int64] = [
        100_000, 250_000, 500_000, 1_000_000, 2_000_000, 5_000_000, 10_000_000, 25_000_000, 50_000_000, 100_000_000,
    ]

    static func presets(for original: Int64) -> [SizePreset] {
        var result: [SizePreset] = []
        for percent in [50, 25] {
            let bytes = original * Int64(percent) / 100
            if bytes >= 1_000 { result.append(SizePreset(label: "\(percent)%", bytes: bytes)) }
        }
        let caps = commonCaps.filter { $0 < original }.suffix(4)
        for cap in caps where !result.contains(where: { $0.bytes == cap }) {
            result.append(SizePreset(label: ByteCount.format(cap), bytes: cap))
        }
        return result
    }
}
