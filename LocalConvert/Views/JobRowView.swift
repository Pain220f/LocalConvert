import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A calm, spacious card for one file: what it is, how big it is, and how it turned out.
/// All controls live in the inspector; the card only shows state and a remove button.
struct JobRowView: View {
    let job: ConversionJob
    let isSelected: Bool
    let onRemove: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: FileIconCache.icon(for: job.isCombined ? .pdf : job.sourceType))
                .resizable()
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(job.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(typeName) · \(ByteCount.format(job.originalBytes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(ByteCount.exact(job.originalBytes))
            }

            Spacer(minLength: 12)

            status
                .frame(maxWidth: 220, alignment: .trailing)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .opacity(isHovering || isSelected ? 1 : 0.35)
            .disabled(job.isBusy)
            .help("Remove from list")
            .accessibilityLabel("Remove \(job.displayName)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.06))
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { isHovering = $0 }
    }

    private var typeName: String {
        job.isCombined ? "\(job.sourceURLs.count) images" : (job.sourceType.preferredFilenameExtension?.uppercased() ?? job.category.displayName)
    }

    @ViewBuilder
    private var status: some View {
        switch job.status {
        case .pending:
            Text(plan)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .queued:
            Label("Waiting", systemImage: "clock").font(.callout).foregroundStyle(.secondary)
        case let .converting(fraction):
            HStack(spacing: 8) {
                ProgressView(value: fraction).frame(width: 110)
                Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .completed:
            if let delta = job.sizeDelta, let output = job.output {
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(ByteCount.format(delta.after)).monospacedDigit()
                        Text("·").foregroundStyle(.tertiary)
                        Text(String(format: "%+.0f%%", delta.percent))
                            .monospacedDigit()
                            .fontWeight(.semibold)
                            .foregroundStyle(delta.isSmaller ? .green : (delta.delta == 0 ? .secondary : .orange))
                    }
                    .font(.callout)
                    if let limit = output.targetMaxBytes {
                        Label("Under \(ByteCount.format(limit))", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        VerificationLabel(result: output.verification)
                    }
                }
                .help("\(ByteCount.exact(delta.before)) → \(ByteCount.exact(delta.after))")
            }
        case let .failed(message):
            VStack(alignment: .trailing, spacing: 2) {
                Label("Failed", systemImage: "xmark.octagon.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
            }
            .help(message)
        case .cancelled:
            Label("Cancelled", systemImage: "stop.circle").font(.callout).foregroundStyle(.secondary)
        }
    }

    /// One-line summary of what will happen, e.g. "Compress → JPEG ≤ 200 KB".
    private var plan: String {
        var text = "\(job.mode.verb) → \(job.target.shortName)"
        if let limit = job.targetMaxBytes { text += " ≤ \(ByteCount.format(limit))" }
        return text
    }
}

/// Icons are looked up once per content type instead of on every redraw.
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

/// Quiet pill describing how faithful a conversion is.
struct FidelityBadge: View {
    let fidelity: Fidelity

    var body: some View {
        Label(fidelity.label, systemImage: fidelity.symbolName)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
            .foregroundStyle(color)
            .help(fidelity.detail)
    }

    private var color: Color {
        switch fidelity {
        case .bitExact: .blue
        case .lossless: .green
        case .nearLossless: .orange
        case .lossy: .orange
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
                .font(.caption).foregroundStyle(.green)
                .help("Source and output were decoded and compared at 16 bits per channel.")
        case let .identicalFrames(compared, sourceFrames):
            Label("\(compared)/\(sourceFrames) frames identical", systemImage: "square.stack.3d.down.right")
                .font(.caption).foregroundStyle(.orange)
                .help(result.summary)
        case .differs:
            Label("Pixels differ", systemImage: "exclamationmark.circle.fill")
                .font(.caption).foregroundStyle(.orange)
                .help(result.summary)
        case .skipped:
            Label("Not verified", systemImage: "questionmark.circle")
                .font(.caption).foregroundStyle(.secondary)
                .help(result.summary)
        }
    }
}
