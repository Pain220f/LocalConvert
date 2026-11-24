import Foundation
import ImageIO
import UniformTypeIdentifiers

/// ImageIO-based raster conversion.
///
/// Strategy, in order of preference:
/// 1. **Bitstream copy** — same lossy format (JPEG→JPEG, HEIC→HEIC): `CGImageDestinationCopyImageSource`
///    rewrites only metadata, compressed image data is never decoded.
/// 2. **Lossless re-encode** — PNG / TIFF (LZW) / BMP targets, with PNG using every row filter for
///    the best entropy coding ImageIO offers.
/// 3. **Max-quality lossy** — JPEG/HEIC from other formats at quality 1.0, flagged in the UI.
///
/// Every output is decoded again and compared against the source by `PixelVerifier`.
struct ImageConversionEngine: ConversionEngineProtocol {
    let identifier = "imageio"
    let displayName = "ImageIO"

    static let readableTypes: Set<String> = Set((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [])
    static let writableTypes: Set<String> = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])

    /// Formats whose compressed bitstream can be carried over verbatim when only metadata changes.
    private static let bitstreamCopyTypes: Set<String> = [
        UTType.jpeg.identifier, UTType.heic.identifier, UTType.heif.identifier,
    ]

    /// `IMAGEIO_PNG_ALL_FILTERS` (NONE|SUB|UP|AVG|PAETH). The macro does not import into Swift.
    private static let pngAllFilters = 0xF8
    /// TIFF compression tag value for LZW.
    private static let tiffLZW = 5

    static func canRead(_ type: UTType) -> Bool {
        type.conforms(to: .image) && readableTypes.contains(type.identifier)
    }

    func supportedTargets(for sourceType: UTType) -> [SupportedFormat] {
        guard Self.canRead(sourceType) else { return [] }
        let preferred: [SupportedFormat]
        if sourceType.conforms(to: .jpeg) {
            preferred = [.jpeg, .png, .tiff, .heic, .bmp, .gif]
        } else if sourceType.conforms(to: .heic) {
            // Only true HEIC can be rewritten bit-exact. Note: on current SDKs `public.heic` does not
            // conform to `public.heif`, and plain HEIF / AVIF fall through to a lossless PNG default.
            preferred = [.heic, .png, .tiff, .jpeg, .bmp, .gif]
        } else if sourceType.conforms(to: .gif) {
            preferred = [.gif, .png, .tiff, .heic, .jpeg, .bmp]
        } else {
            preferred = [.png, .tiff, .heic, .jpeg, .bmp, .gif]
        }
        return preferred.filter { format in
            format.imageIOTypeIdentifier.map(Self.writableTypes.contains) ?? false
        }
    }

    func compressionTargets(for sourceType: UTType) -> [SupportedFormat] {
        guard Self.canRead(sourceType) else { return [] }
        let preferred: [SupportedFormat]
        if sourceType.conforms(to: .jpeg) {
            preferred = [.jpeg, .heic, .png]
        } else if sourceType.conforms(to: .heic) {
            preferred = [.heic, .jpeg, .png]
        } else if sourceType.conforms(to: .png) {
            preferred = [.heic, .jpeg, .png]
        } else {
            preferred = [.heic, .jpeg]
        }
        return preferred.filter { format in
            format.imageIOTypeIdentifier.map(Self.writableTypes.contains) ?? false
        }
    }

    func convert(_ request: ConversionRequest, progress: @escaping ProgressHandler) async throws -> ConversionOutput {
        if request.options.mode == .compressSize {
            return try compress(request, progress: progress)
        }
        let start = ContinuousClock.now
        guard let destinationType = request.target.imageIOTypeIdentifier,
              let pathExtension = request.target.fileExtension
        else {
            throw ConversionError.unsupportedConversion(from: request.sourceType, to: request.target)
        }
        guard let source = CGImageSourceCreateWithURL(request.sourceURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetCount(source) > 0
        else {
            throw ConversionError.unreadableSource(request.sourceURL)
        }

        let sourceTypeID = (CGImageSourceGetType(source) as String?) ?? request.sourceType.identifier
        let outputURL = FileStorageService.uniqueURL(
            in: request.outputDirectory, baseName: request.baseName, pathExtension: pathExtension
        )
        var notes: [String] = []
        let fidelity: Fidelity

        if sourceTypeID == destinationType, Self.bitstreamCopyTypes.contains(destinationType) {
            try Self.copyBitstream(source, from: request.sourceURL, to: outputURL, type: destinationType, strip: request.options.stripMetadata)
            fidelity = .bitExact
            notes.append(request.options.stripMetadata
                ? "Metadata removed without decoding or re-compressing image data."
                : "Compressed image data copied verbatim.")
        } else {
            try reencode(source, to: outputURL, type: destinationType, request: request, notes: &notes, progress: progress)
            fidelity = sourceTypeID == destinationType
                ? min(request.target.fidelity(from: request.sourceType), .lossless)
                : request.target.fidelity(from: request.sourceType)
            if request.target == .png { notes.append("PNG encoded with all row filters for best lossless compression.") }
            if request.target == .tiff { notes.append("TIFF encoded with lossless LZW compression.") }
        }
        if request.options.stripMetadata { notes.append("EXIF, GPS, IPTC and XMP metadata stripped (orientation kept).") }

        progress(0.9)
        try Task.checkCancellation()
        let verification = PixelVerifier.compare(original: request.sourceURL, converted: outputURL)
        progress(1)

        return try OutputBuilder.make(
            url: outputURL, fidelity: fidelity, verification: verification,
            notes: notes, engineName: displayName, startedAt: start
        )
    }

    // MARK: - Bitstream copy

    /// Writes a copy of a JPEG/HEIC/PNG/TIFF file with EXIF, GPS, IPTC and XMP removed, without
    /// decoding or re-compressing the image data. Used by other engines (PDF) that embed or extract
    /// original image streams.
    static func writeMetadataStrippedCopy(of url: URL, to destination: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?
        else { throw ConversionError.unreadableSource(url) }
        try copyBitstream(source, from: url, to: destination, type: type, strip: true)
    }

    private static func copyBitstream(_ source: CGImageSource, from sourceURL: URL, to url: URL, type: String, strip: Bool) throws {
        // Nothing to change: the honest bit-exact result is the original bytes. (ImageIO's
        // CopyImageSource also fails with OSStatus 4 when handed no operations.)
        guard strip else {
            try FileManager.default.copyItem(at: sourceURL, to: url)
            return
        }
        let count = CGImageSourceGetCount(source)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, count, nil) else {
            throw ConversionError.encoderUnavailable(type)
        }
        var options: [CFString: Any] = [:]
        if strip {
            let metadata = CGImageMetadataCreateMutable()
            let frame = Self.frameProperties(source, at: 0)
            if let orientation = frame[kCGImagePropertyOrientation] as? NSNumber {
                CGImageMetadataSetValueMatchingImageProperty(
                    metadata, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, orientation
                )
            }
            options[kCGImageDestinationMetadata] = metadata
            options[kCGImageDestinationMergeMetadata] = false
            options[kCGImageMetadataShouldExcludeGPS] = true
            options[kCGImageMetadataShouldExcludeXMP] = true
        }
        var error: Unmanaged<CFError>?
        // Note: CGImageDestinationCopyImageSource finalizes the destination itself.
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error) else {
            let reason = error?.takeRetainedValue().localizedDescription ?? "ImageIO could not rewrite this file in place"
            try? FileManager.default.removeItem(at: url)
            throw ConversionError.cannotPreserveLosslessly(
                "\(reason). Choose PNG or TIFF to keep every pixel while changing metadata."
            )
        }
    }

    // MARK: - Re-encode

    private func reencode(
        _ source: CGImageSource,
        to url: URL,
        type: String,
        request: ConversionRequest,
        notes: inout [String],
        progress: ProgressHandler
    ) throws {
        let target = request.target
        let strip = request.options.stripMetadata
        let sourceCount = CGImageSourceGetCount(source)
        let frameCount = target.supportsMultipleFrames ? sourceCount : 1
        if sourceCount > 1, frameCount == 1 {
            notes.append("Only the first of \(sourceCount) frames was converted; \(target.displayName) holds a single image.")
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, frameCount, nil) else {
            throw ConversionError.encoderUnavailable(target.displayName)
        }
        if target == .gif,
           let container = CGImageSourceCopyProperties(source, nil) as? [CFString: Any],
           let gif = container[kCGImagePropertyGIFDictionary] {
            CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: gif] as CFDictionary)
        }

        let firstFrame = Self.frameProperties(source, at: 0)
        if [.jpeg, .bmp].contains(target), (firstFrame[kCGImagePropertyHasAlpha] as? Bool) == true {
            notes.append("\(target.displayName) has no usable alpha channel; transparency is flattened.")
        }
        // BMP and GIF cannot store an orientation flag, so the rotation is applied to the pixels
        // instead (an exact 90°/180° transform, no resampling).
        let bakesOrientation = [.bmp, .gif].contains(target)
        if bakesOrientation, Self.orientation(of: firstFrame) != 1 {
            notes.append("\(target.displayName) cannot store an orientation flag; rotation was applied to the pixels losslessly.")
        }

        for index in 0..<frameCount {
            try Task.checkCancellation()
            let frame = Self.frameProperties(source, at: index)
            if bakesOrientation, Self.orientation(of: frame) != 1 {
                guard let image = Self.orientedImage(source, at: index) else {
                    throw ConversionError.unreadableSource(request.sourceURL)
                }
                var properties = strip ? Self.essentialProperties(from: frame, target: target) : frame
                properties[kCGImagePropertyOrientation] = 1
                properties[kCGImagePropertyPixelWidth] = nil
                properties[kCGImagePropertyPixelHeight] = nil
                if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                    tiff[kCGImagePropertyTIFFOrientation] = 1
                    properties[kCGImagePropertyTIFFDictionary] = tiff
                }
                CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            } else if strip {
                guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else {
                    throw ConversionError.unreadableSource(request.sourceURL)
                }
                var properties = Self.essentialProperties(from: frame, target: target)
                properties.merge(Self.encoderProperties(for: target, frame: frame, strip: true)) { _, new in new }
                CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            } else {
                let properties = Self.encoderProperties(for: target, frame: frame, strip: false)
                CGImageDestinationAddImageFromSource(destination, source, index, properties as CFDictionary)
            }
            progress(0.8 * Double(index + 1) / Double(frameCount))
        }
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: url)
            throw ConversionError.writeFailed("ImageIO could not finalize the \(target.displayName) file.")
        }
    }

    static func frameProperties(_ source: CGImageSource, at index: Int) -> [CFString: Any] {
        (CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]) ?? [:]
    }

    static func orientation(of properties: [CFString: Any]) -> Int {
        (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    }

    /// Frame `index` as it is meant to be displayed (EXIF orientation applied), at full resolution.
    static func orientedImage(_ source: CGImageSource, at index: Int) -> CGImage? {
        let properties = frameProperties(source, at: index)
        guard orientation(of: properties) != 1 else {
            return CGImageSourceCreateImageAtIndex(source, index, [kCGImageSourceShouldCache: false] as CFDictionary)
        }
        let maxSide = max(
            (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0,
            (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        )
        guard maxSide > 0 else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, index, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceShouldCache: false,
        ] as CFDictionary)
    }

    /// Non-identifying properties that affect how the image is displayed.
    static func essentialProperties(from frame: [CFString: Any], target: SupportedFormat) -> [CFString: Any] {
        var result: [CFString: Any] = [:]
        for key in [kCGImagePropertyOrientation, kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
            if let value = frame[key] { result[key] = value }
        }
        if target == .gif, let gif = frame[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
            result[kCGImagePropertyGIFDictionary] = gif.filter {
                $0.key == kCGImagePropertyGIFDelayTime || $0.key == kCGImagePropertyGIFUnclampedDelayTime
            }
        }
        return result
    }

    private static func encoderProperties(for target: SupportedFormat, frame: [CFString: Any], strip: Bool) -> [CFString: Any] {
        switch target {
        case .jpeg, .heic:
            return [kCGImageDestinationLossyCompressionQuality: 1.0]
        case .png:
            var png = strip ? [:] : (frame[kCGImagePropertyPNGDictionary] as? [CFString: Any]) ?? [:]
            png[kCGImagePropertyPNGCompressionFilter] = pngAllFilters
            return [kCGImagePropertyPNGDictionary: png]
        case .tiff:
            var tiff: [CFString: Any] = strip ? [:] : (frame[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]
            if strip, let orientation = frame[kCGImagePropertyOrientation] {
                tiff[kCGImagePropertyTIFFOrientation] = orientation
            }
            tiff[kCGImagePropertyTIFFCompression] = tiffLZW
            return [kCGImagePropertyTIFFDictionary: tiff]
        default:
            return [:]
        }
    }
}
