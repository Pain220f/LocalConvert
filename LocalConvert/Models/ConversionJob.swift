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

/// One unit of work in the queue: one or more source files, a chosen target and the result.
@MainActor
@Observable
final class ConversionJob: Identifiable {
    let id = UUID()
    let sourceURLs: [URL]
    let sourceType: UTType
    let category: MediaCategory
    let originalBytes: Int64
    let availableTargets: [SupportedFormat]

    private(set) var target: SupportedFormat
    var status: JobStatus = .pending
    private(set) var output: ConversionOutput?

    init(
        sourceURLs: [URL],
        sourceType: UTType,
        category: MediaCategory,
        originalBytes: Int64,
        availableTargets: [SupportedFormat],
        target: SupportedFormat? = nil
    ) {
        precondition(!sourceURLs.isEmpty && !availableTargets.isEmpty)
        self.sourceURLs = sourceURLs
        self.sourceType = sourceType
        self.category = category
        self.originalBytes = originalBytes
        self.availableTargets = availableTargets
        self.target = target ?? availableTargets[0]
    }

    var primaryURL: URL { sourceURLs[0] }
    var isCombined: Bool { sourceURLs.count > 1 }

    var displayName: String {
        isCombined ? "Combined PDF (\(sourceURLs.count) images)" : primaryURL.lastPathComponent
    }

    var plannedFidelity: Fidelity { target.fidelity(from: sourceType) }

    var sizeDelta: SizeDelta? {
        output.map { SizeDelta(before: originalBytes, after: $0.byteCount) }
    }

    var isBusy: Bool { status.isBusy }

    func setTarget(_ newTarget: SupportedFormat) {
        guard newTarget != target, availableTargets.contains(newTarget), !isBusy else { return }
        target = newTarget
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
