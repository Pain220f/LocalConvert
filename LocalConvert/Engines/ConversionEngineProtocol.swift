import Foundation
import UniformTypeIdentifiers

struct ConversionOptions: Sendable, Equatable {
    /// Remove EXIF / GPS / IPTC / XMP (images) or container metadata (media).
    var stripMetadata = false
}

struct ConversionRequest: Sendable {
    /// One file for normal jobs; several images for a combined PDF.
    let sourceURLs: [URL]
    let sourceType: UTType
    let target: SupportedFormat
    let options: ConversionOptions
    /// Private, per-job temporary directory the engine must write into.
    let outputDirectory: URL

    var sourceURL: URL { sourceURLs[0] }
    var baseName: String { sourceURL.deletingPathExtension().lastPathComponent }
}

typealias ProgressHandler = @Sendable (Double) -> Void

/// Result of decoding source and output and comparing them sample by sample.
enum VerificationResult: Sendable, Equatable {
    case notApplicable
    case pixelIdentical
    /// Every frame present in the output is identical, but the output kept fewer frames than the source.
    case identicalFrames(compared: Int, sourceFrames: Int)
    /// `maxChannelDelta` is expressed on an 8-bit (0–255) scale.
    case differs(maxChannelDelta: Double, differingPixels: Int, totalPixels: Int)
    case skipped(String)

    var summary: String {
        switch self {
        case .notApplicable:
            return "Not verified"
        case .pixelIdentical:
            return "Pixel-identical"
        case let .identicalFrames(compared, sourceFrames):
            return "\(compared) of \(sourceFrames) frames kept, each pixel-identical"
        case let .differs(maxDelta, differing, total):
            let share = total > 0 ? Double(differing) / Double(total) * 100 : 0
            return String(format: "Differs: %.2f%% of pixels, max Δ %.1f/255", share, maxDelta)
        case let .skipped(reason):
            return "Verification skipped: \(reason)"
        }
    }
}

struct ConversionOutput: Sendable {
    /// File or directory inside the job's temporary directory.
    let url: URL
    let isDirectory: Bool
    /// Exact logical size in bytes (summed for directories).
    let byteCount: Int64
    let fileCount: Int
    let fidelity: Fidelity
    let verification: VerificationResult
    let notes: [String]
    let engineName: String
    let elapsed: Duration
}

enum ConversionError: LocalizedError {
    case unreadableSource(URL)
    case unsupportedConversion(from: UTType, to: SupportedFormat)
    case encoderUnavailable(String)
    case cannotPreserveLosslessly(String)
    case incompatibleContainer(String)
    case writeFailed(String)
    case noAudioTrack
    case encryptedPDF
    case nothingToExtract
    case engineFailure(String)

    var errorDescription: String? {
        switch self {
        case let .unreadableSource(url):
            "Could not read “\(url.lastPathComponent)”."
        case let .unsupportedConversion(from, to):
            "Converting \(from.localizedDescription ?? from.identifier) to \(to.displayName) is not supported."
        case let .encoderUnavailable(name):
            "No \(name) encoder is available on this Mac."
        case let .cannotPreserveLosslessly(reason):
            "Refusing to lose quality: \(reason)"
        case let .incompatibleContainer(reason):
            reason
        case let .writeFailed(reason):
            "Writing the output failed: \(reason)"
        case .noAudioTrack:
            "The source has no audio track."
        case .encryptedPDF:
            "The PDF is password protected."
        case .nothingToExtract:
            "No extractable raster images were found in this PDF."
        case let .engineFailure(reason):
            reason
        }
    }
}

/// Unified interface for every conversion backend.
///
/// Implementations must be `Sendable`, must only write inside `request.outputDirectory`,
/// must honour `Task` cancellation, and must never touch the network. The queue manager and the
/// UI only talk to this protocol, so new backends (e.g. a bundled, code-signed `oxipng` or
/// `ffmpeg` — see `BundledToolEngine`) can be registered in `EngineRegistry` without UI changes.
protocol ConversionEngineProtocol: Sendable {
    var identifier: String { get }
    var displayName: String { get }

    /// Targets this engine can produce for `sourceType`, best (default) first. Empty if unsupported.
    func supportedTargets(for sourceType: UTType) -> [SupportedFormat]

    func convert(_ request: ConversionRequest, progress: @escaping ProgressHandler) async throws -> ConversionOutput
}

/// Ordered collection of engines. The first engine that supports a (source, target) pair wins.
struct EngineRegistry: Sendable {
    let engines: [any ConversionEngineProtocol]

    static let standard = EngineRegistry(engines: [
        ImageConversionEngine(),
        PDFConversionEngine(),
        MediaConversionEngine(),
    ])

    func targets(for sourceType: UTType) -> [SupportedFormat] {
        var result: [SupportedFormat] = []
        for engine in engines {
            for target in engine.supportedTargets(for: sourceType) where !result.contains(target) {
                result.append(target)
            }
        }
        return result
    }

    func engine(for target: SupportedFormat, sourceType: UTType) -> (any ConversionEngineProtocol)? {
        engines.first { $0.supportedTargets(for: sourceType).contains(target) }
    }
}

/// Shared helper to package an engine result with exact byte measurement.
enum OutputBuilder {
    static func make(
        url: URL,
        fidelity: Fidelity,
        verification: VerificationResult = .notApplicable,
        notes: [String] = [],
        engineName: String,
        startedAt start: ContinuousClock.Instant
    ) throws -> ConversionOutput {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        return ConversionOutput(
            url: url,
            isDirectory: isDirectory,
            byteCount: try FileStorageService.byteCount(at: url),
            fileCount: isDirectory ? FileStorageService.fileCount(at: url) : 1,
            fidelity: fidelity,
            verification: verification,
            notes: notes,
            engineName: engineName,
            elapsed: ContinuousClock.now - start
        )
    }
}
