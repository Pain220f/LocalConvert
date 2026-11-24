import Foundation
import Observation
import UniformTypeIdentifiers

/// Exact before/after size comparison.
struct SizeDelta: Sendable, Equatable {
    let before: Int64
    let after: Int64

    var delta: Int64 { after - before }

    /// Signed percentage change relative to the original (negative = smaller).
    var percent: Double {
        guard before > 0 else { return 0 }
        return Double(delta) / Double(before) * 100
    }

    /// `after / before`, used for proportional bars.
    var ratio: Double {
        guard before > 0 else { return 0 }
        return Double(after) / Double(before)
    }

    var isSmaller: Bool { after < before }

    var formattedPercent: String {
        delta == 0 ? "±0.00%" : String(format: "%+.2f%%", percent)
    }

    var formattedDelta: String {
        let sign = delta < 0 ? "−" : (delta > 0 ? "+" : "±")
        return sign + ByteCount.format(abs(delta))
    }

    var formattedExactDelta: String {
        let sign = delta < 0 ? "−" : (delta > 0 ? "+" : "±")
        return sign + ByteCount.exact(abs(delta))
    }
}

enum ByteCount {
    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func exact(_ bytes: Int64) -> String {
        bytes.formatted(.number) + " bytes"
    }
}

enum JobStatus: Sendable, Equatable {
    case pending
    case queued
    case converting(Double)
    case completed
    case failed(String)
    case cancelled

    var canStart: Bool {
        switch self {
        case .pending, .failed, .cancelled: true
        default: false
        }
    }

    var isBusy: Bool {
        switch self {
        case .queued, .converting: true
        default: false
        }
    }
}

/// One unit of work in the queue: one or more source files, what to do with them, and the result.
@MainActor
@Observable
final class ConversionJob: Identifiable {
    let id = UUID()
    let sourceURLs: [URL]
    let sourceType: UTType
    let category: MediaCategory
    let originalBytes: Int64
    /// Targets for Convert Format mode (quality-preserving first).
    let convertTargets: [SupportedFormat]
    /// Targets for Compress Size mode (size-efficient first). Empty if the file can't be compressed.
    let compressionTargets: [SupportedFormat]

    private(set) var mode: ConversionMode = .convertFormat
    private(set) var convertTarget: SupportedFormat
    private(set) var compressTarget: SupportedFormat?
    private(set) var isTargetSizeEnabled = false
    /// Remembered even while the limit is switched off, so toggling doesn't lose the value.
    private(set) var targetSizeBytes: Int64
    private(set) var allowResizeToFitTarget = false

    var status: JobStatus = .pending
    private(set) var output: ConversionOutput?

    init(
        sourceURLs: [URL],
        sourceType: UTType,
        category: MediaCategory,
        originalBytes: Int64,
        availableTargets: [SupportedFormat],
        compressionTargets: [SupportedFormat] = [],
        target: SupportedFormat? = nil
    ) {
        precondition(!sourceURLs.isEmpty && !availableTargets.isEmpty)
        self.sourceURLs = sourceURLs
        self.sourceType = sourceType
        self.category = category
        self.originalBytes = originalBytes
        self.convertTargets = availableTargets
        self.compressionTargets = compressionTargets
        self.convertTarget = target ?? availableTargets[0]
        self.compressTarget = compressionTargets.first
        self.targetSizeBytes = Self.suggestedLimit(for: originalBytes)
    }

    /// Half the original, rounded down to a tidy value (at least 10 KB).
    static func suggestedLimit(for bytes: Int64) -> Int64 {
        let half = max(bytes / 2, 10_000)
        let step: Int64 = half >= 10_000_000 ? 1_000_000 : (half >= 1_000_000 ? 100_000 : 10_000)
        return max(step, (half / step) * step)
    }

    // MARK: Derived

    var primaryURL: URL { sourceURLs[0] }
    var isCombined: Bool { sourceURLs.count > 1 }
    var supportsCompression: Bool { !compressionTargets.isEmpty }

    var displayName: String {
        isCombined ? "Combined PDF (\(sourceURLs.count) images)" : primaryURL.lastPathComponent
    }

    var target: SupportedFormat {
        mode == .compressSize ? (compressTarget ?? convertTarget) : convertTarget
    }

    var availableTargets: [SupportedFormat] {
        mode == .compressSize ? compressionTargets : convertTargets
    }

    /// The strict byte limit that will be enforced, if any.
    var targetMaxBytes: Int64? {
        mode == .compressSize && isTargetSizeEnabled ? targetSizeBytes : nil
    }

    var plannedFidelity: Fidelity { target.fidelity(from: sourceType, mode: mode) }

    var sizeDelta: SizeDelta? {
        output.map { SizeDelta(before: originalBytes, after: $0.byteCount) }
    }

    var isBusy: Bool { status.isBusy }

    func options(stripMetadata: Bool) -> ConversionOptions {
        ConversionOptions(stripMetadata: stripMetadata, mode: mode,
                          targetMaxBytes: targetMaxBytes, allowResizeToFitTarget: allowResizeToFitTarget)
    }

    // MARK: Editing (every change invalidates the previous result)

    func setMode(_ newMode: ConversionMode) {
        guard newMode != mode, !isBusy, newMode == .convertFormat || supportsCompression else { return }
        mode = newMode
        reset()
    }

    func setTarget(_ newTarget: SupportedFormat) {
        guard newTarget != target, availableTargets.contains(newTarget), !isBusy else { return }
        if mode == .compressSize { compressTarget = newTarget } else { convertTarget = newTarget }
        reset()
    }

    /// `nil` switches the limit off. Values are clamped to at least 1 KB.
    func setTargetMaxBytes(_ bytes: Int64?) {
        guard !isBusy else { return }
        if let bytes {
            let clamped = max(bytes, 1_000)
            guard !isTargetSizeEnabled || clamped != targetSizeBytes else { return }
            targetSizeBytes = clamped
            isTargetSizeEnabled = true
        } else {
            guard isTargetSizeEnabled else { return }
            isTargetSizeEnabled = false
        }
        reset()
    }

    func setAllowResizeToFitTarget(_ allow: Bool) {
        guard allow != allowResizeToFitTarget, !isBusy else { return }
        allowResizeToFitTarget = allow
        reset()
    }

    /// Copies mode and size settings from another job where they apply to this file.
    func adoptSettings(from other: ConversionJob) {
        guard !isBusy, other !== self else { return }
        if other.mode == .compressSize, supportsCompression {
            mode = .compressSize
            if compressionTargets.contains(other.target) { compressTarget = other.target }
            isTargetSizeEnabled = other.isTargetSizeEnabled
            targetSizeBytes = other.targetSizeBytes
            allowResizeToFitTarget = other.allowResizeToFitTarget
        } else {
            mode = .convertFormat
            if convertTargets.contains(other.target) { convertTarget = other.target }
        }
        reset()
    }

    func reset() {
        output = nil
        status = .pending
    }

    func updateProgress(_ fraction: Double) {
        guard case .converting = status else { return }
        status = .converting(min(max(fraction, 0), 1))
    }

    func finish(with output: ConversionOutput) {
        self.output = output
        status = .completed
    }
}
