import Foundation
import UniformTypeIdentifiers

/// Broad family of an input file. Drives icons, preview strategy and which engines are consulted.
enum MediaCategory: String, Sendable, CaseIterable {
    case image, audio, video, document

    init?(type: UTType) {
        if type.conforms(to: .pdf) {
            self = .document
        } else if type.conforms(to: .image) {
            self = .image
        } else if type.conforms(to: .movie) {
            self = .video
        } else if type.conforms(to: .audio) {
            self = .audio
        } else {
            return nil
        }
    }

    var symbolName: String {
        switch self {
        case .image: "photo"
        case .audio: "waveform"
        case .video: "film"
        case .document: "doc.richtext"
        }
    }

    var displayName: String {
        switch self {
        case .image: "Image"
        case .audio: "Audio"
        case .video: "Video"
        case .document: "Document"
        }
    }
}

/// How faithfully a conversion preserves the source. Ordered from best to worst.
enum Fidelity: Int, Sendable, Comparable, CaseIterable {
    /// The original encoded bitstream is copied unchanged (container remux, metadata-only rewrite).
    case bitExact = 0
    /// The data is re-encoded with a lossless codec; decoded output is identical to the decoded input.
    case lossless
    /// Re-encoded with a lossy codec at maximum quality. Not pixel/sample identical.
    case nearLossless
    /// Lossy by design (palette reduction, HEVC re-encode, …).
    case lossy

    static func < (lhs: Fidelity, rhs: Fidelity) -> Bool { lhs.rawValue < rhs.rawValue }

    var isLossless: Bool { self <= .lossless }

    var label: String {
        switch self {
        case .bitExact: "Bit-exact"
        case .lossless: "Lossless"
        case .nearLossless: "Max-quality lossy"
        case .lossy: "Lossy"
        }
    }

    var detail: String {
        switch self {
        case .bitExact: "The original encoded data is copied byte-for-byte; only the container or metadata changes."
        case .lossless: "Re-encoded with a lossless codec. Decoded content is identical to the source."
        case .nearLossless: "Re-encoded with a lossy codec at maximum quality. Visually transparent but not identical."
        case .lossy: "This target cannot represent the source exactly. Some information will be discarded."
        }
    }

    var symbolName: String {
        switch self {
        case .bitExact: "equal.circle.fill"
        case .lossless: "checkmark.seal.fill"
        case .nearLossless: "exclamationmark.triangle.fill"
        case .lossy: "exclamationmark.octagon.fill"
        }
    }
}

/// Every output the app can produce. Engines advertise which of these they support for a given input `UTType`.
enum SupportedFormat: String, CaseIterable, Identifiable, Sendable {
    // Images (ImageIO)
    case png, tiff, heic, bmp, gif, jpeg
    // Documents (Quartz / PDFKit)
    case pdf, pdfPages, pdfImages
    // Video (AVFoundation)
    case mov, mp4, hevcMOV
    // Audio (AVFoundation)
    case m4a, alac, wav

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .png: "PNG"
        case .tiff: "TIFF (LZW)"
        case .heic: "HEIC"
        case .bmp: "BMP"
        case .gif: "GIF"
        case .jpeg: "JPEG"
        case .pdf: "PDF"
        case .pdfPages: "Split into single-page PDFs"
        case .pdfImages: "Extract embedded images"
        case .mov: "MOV (remux)"
        case .mp4: "MP4 (remux)"
        case .hevcMOV: "MOV · HEVC re-encode"
        case .m4a: "M4A (audio passthrough)"
        case .alac: "ALAC (Apple Lossless)"
        case .wav: "WAV (PCM)"
        }
    }

    /// File extension of the produced file, or `nil` when the conversion produces a folder.
    var fileExtension: String? {
        switch self {
        case .png: "png"
        case .tiff: "tiff"
        case .heic: "heic"
        case .bmp: "bmp"
        case .gif: "gif"
        case .jpeg: "jpg"
        case .pdf: "pdf"
        case .pdfPages, .pdfImages: nil
        case .mov, .hevcMOV: "mov"
        case .mp4: "mp4"
        case .m4a, .alac: "m4a"
        case .wav: "wav"
        }
    }

    var producesDirectory: Bool { fileExtension == nil }

    /// Content type used for save panels.
    var contentType: UTType? {
        switch self {
        case .png: .png
        case .tiff: .tiff
        case .heic: .heic
        case .bmp: .bmp
        case .gif: .gif
        case .jpeg: .jpeg
        case .pdf: .pdf
        case .pdfPages, .pdfImages: .folder
        case .mov, .hevcMOV: .quickTimeMovie
        case .mp4: .mpeg4Movie
        case .m4a, .alac: UTType(filenameExtension: "m4a") ?? .mpeg4Audio
        case .wav: .wav
        }
    }

    /// ImageIO destination type identifier for raster targets.
    var imageIOTypeIdentifier: String? {
        switch self {
        case .png: UTType.png.identifier
        case .tiff: UTType.tiff.identifier
        case .heic: UTType.heic.identifier
        case .bmp: UTType.bmp.identifier
        case .gif: UTType.gif.identifier
        case .jpeg: UTType.jpeg.identifier
        default: nil
        }
    }

    /// Whether the target container can hold every frame of an animated / multi-page source.
    var supportsMultipleFrames: Bool { self == .gif || self == .tiff }

    /// Expected fidelity when converting from `sourceType`. Engines may report a better or worse
    /// actual result in `ConversionOutput.fidelity`; pixel verification is reported separately.
    func fidelity(from sourceType: UTType) -> Fidelity {
        switch self {
        case .png, .tiff, .bmp:
            return .lossless
        case .heic:
            return sourceType.conforms(to: .heic) ? .bitExact : .nearLossless
        case .jpeg:
            return sourceType.conforms(to: .jpeg) ? .bitExact : .nearLossless
        case .gif:
            return sourceType.conforms(to: .gif) ? .lossless : .lossy
        case .pdf:
            return sourceType.conforms(to: .jpeg) ? .bitExact : .lossless
        case .pdfPages:
            return .lossless
        case .pdfImages:
            return .bitExact
        case .mov, .mp4, .m4a:
            return .bitExact
        case .hevcMOV:
            return .lossy
        case .alac, .wav:
            return .lossless
        }
    }
}
