import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct JobRowView: View {
    let job: ConversionJob
    let onConvert: () -> Void
    let onCompare: () -> Void
    let onSave: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: FileIconCache.icon(for: job.isCombined ? .pdf : job.sourceType))
                .resizable()
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(job.displayName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(job.sourceURLs.map(\.path).joined(separator: "\n"))
                Text("\(job.sourceType.localizedDescription ?? job.category.displayName) · \(ByteCount.format(job.originalBytes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(ByteCount.exact(job.originalBytes))
            }
            .frame(minWidth: 160, alignment: .leading)

            Spacer(minLength: 8)

            Picker("Convert to", selection: Binding(get: { job.target }, set: { job.setTarget($0) })) {
                ForEach(job.availableTargets) { format in
                    Label(format.displayName, systemImage: format.fidelity(from: job.sourceType).symbolName)
                        .tag(format)
                }
            }
            .labelsHidden()
            .frame(width: 210)
            .disabled(job.isBusy)

            FidelityBadge(fidelity: job.output?.fidelity ?? job.plannedFidelity)
                .frame(width: 128, alignment: .leading)

            result
                .frame(width: 210, alignment: .trailing)

            actions
        }
        .padding(.vertical, 6)
        .contextMenu {
            if job.output != nil {
                Button("Compare…", action: onCompare)
                Button("Save…", action: onSave)
            }
            if job.status.canStart { Button("Convert", action: onConvert) }
            Divider()
            Button("Remove", role: .destructive, action: onRemove).disabled(job.isBusy)
        }
    }

    @ViewBuilder
    private var result: some View {
        switch job.status {
        case .pending:
            Text("Ready").foregroundStyle(.secondary)
        case .queued:
            Label("Queued", systemImage: "clock").foregroundStyle(.secondary)
        case let .converting(fraction):
            ProgressView(value: fraction) {
                EmptyView()
            } currentValueLabel: {
                Text(fraction.formatted(.percent.precision(.fractionLength(0)))).font(.caption2)
            }
            .frame(width: 150)
        case .completed:
            if let delta = job.sizeDelta, let output = job.output {
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(ByteCount.format(delta.after)).monospacedDigit()
                        Text(delta.formattedPercent)
                            .monospacedDigit()
                            .fontWeight(.semibold)
                            .foregroundStyle(delta.isSmaller ? .green : (delta.delta == 0 ? .secondary : .orange))
                    }
                    Text(delta.formattedExactDelta)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    VerificationLabel(result: output.verification)
                }
                .help("\(ByteCount.exact(delta.before)) → \(ByteCount.exact(delta.after))")
            }
        case let .failed(message):
            VStack(alignment: .trailing, spacing: 2) {
                Label("Failed", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            .help(message)
        case .cancelled:
            Label("Cancelled", systemImage: "stop.circle").foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack(spacing: 4) {
            if job.output != nil {
                Button(action: onCompare) { Image(systemName: "rectangle.split.2x1") }
                    .help("Compare before / after")
                Button(action: onSave) { Image(systemName: "square.and.arrow.down") }
                    .help("Save…")
            } else {
                Button(action: onConvert) { Image(systemName: "play.fill") }
                    .help("Convert")
                    .disabled(!job.status.canStart)
            }
            Button(action: onRemove) { Image(systemName: "xmark") }
                .help("Remove from list")
                .disabled(job.isBusy)
        }
        .buttonStyle(.borderless)
        .frame(width: 70, alignment: .trailing)
    }
}

/// Icons are looked up once per content type instead of on every row render.
@MainActor
enum FileIconCache {
    private static var icons: [String: NSImage] = [:]

    static func icon(for type: UTType) -> NSImage {
        if let cached = icons[type.identifier] { return cached }
        let icon = NSWorkspace.shared.icon(for: type)
        icons[type.identifier] = icon
        return icon
    }
}

struct FidelityBadge: View {
    let fidelity: Fidelity

    var body: some View {
        Label(fidelity.label, systemImage: fidelity.symbolName)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
            .help(fidelity.detail)
    }

    private var color: Color {
        switch fidelity {
        case .bitExact: .blue
        case .lossless: .green
        case .nearLossless: .orange
        case .lossy: .red
        }
    }
}

struct VerificationLabel: View {
    let result: VerificationResult

    var body: some View {
        switch result {
        case .notApplicable:
            EmptyView()
        case .pixelIdentical:
            Label("Pixel-identical", systemImage: "checkmark.circle.fill")
                .font(.caption2).foregroundStyle(.green)
                .help("Source and output were decoded and compared at 16 bits per channel.")
        case let .identicalFrames(compared, sourceFrames):
            Label("\(compared)/\(sourceFrames) frames identical", systemImage: "square.stack.3d.down.right")
                .font(.caption2).foregroundStyle(.orange)
                .help(result.summary)
        case .differs:
            Label("Pixels differ", systemImage: "exclamationmark.circle.fill")
                .font(.caption2).foregroundStyle(.orange)
                .help(result.summary)
        case .skipped:
            Label("Not verified", systemImage: "questionmark.circle")
                .font(.caption2).foregroundStyle(.secondary)
                .help(result.summary)
        }
    }
}
