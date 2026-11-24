import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Compress Size mode for raster images.
///
/// Every candidate is encoded **in memory** and only the winning bytes are written, so the file on
/// disk is exactly the size that was measured. With a byte limit:
/// - JPEG / HEIC: binary search over quality for the *highest* quality whose encoding fits.
/// - PNG: encoded losslessly; if it doesn't fit, nothing is silently made lossy.
/// - If even the smallest encoding is too large, dimensions are reduced only when the user allowed it
///   (binary search over scale, then quality); otherwise `cannotMeetTargetSize` is thrown.
extension ImageConversionEngine {
    static let minimumQuality = 0.05
    /// Quality used when compressing without a byte limit.
    static let defaultCompressionQuality = 0.8

    enum SearchResult {
        case fits(data: Data, quality: Double)
        case tooLarge(smallest: Int64)
    }

    func compress(_ request: ConversionRequest, progress: ProgressHandler) throws -> ConversionOutput {
        let start = ContinuousClock.now
        let target = request.target
        guard let type = target.imageIOTypeIdentifier, let pathExtension = target.fileExtension else {
            throw ConversionError.unsupportedConversion(from: request.sourceType, to: target)
        }
        guard let source = CGImageSourceCreateWithURL(request.sourceURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0
        else { throw ConversionError.unreadableSource(request.sourceURL) }
        try SafetyLimits.checkImage(source, at: 0, url: request.sourceURL)
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ConversionError.unreadableSource(request.sourceURL)
        }

        let frame = Self.frameProperties(source, at: 0)
        var properties = request.options.stripMetadata ? Self.essentialProperties(from: frame, target: target) : frame
        properties[kCGImagePropertyPixelWidth] = nil
        properties[kCGImagePropertyPixelHeight] = nil

        var notes: [String] = []
        if CGImageSourceGetCount(source) > 1 {
            notes.append("Only the first of \(CGImageSourceGetCount(source)) frames was compressed.")
        }
        let lossy = target.isLossyCapable
        let originalSize = "\(image.width)×\(image.height)"
        var chosen: (data: Data, quality: Double?, image: CGImage)

        if let limit = request.options.targetMaxBytes {
            progress(0.05)
            if let fit = try Self.fit(image, type: type, lossy: lossy, properties: properties, limit: limit) {
                chosen = (fit.data, fit.quality, image)
            } else if request.options.allowResizeToFitTarget {
                chosen = try Self.fitByDownscaling(image, type: type, lossy: lossy, properties: properties, limit: limit)
                notes.append("Downscaled from \(originalSize) to \(chosen.image.width)×\(chosen.image.height) px to fit.")
            } else {
                let smallest = try Self.smallestEncoding(image, type: type, lossy: lossy, properties: properties)
                throw ConversionError.cannotMeetTargetSize(
                    smallestAchievable: smallest, target: limit,
                    suggestion: lossy
                        ? "Turn on “Allow downscaling dimensions”, or raise the limit."
                        : "\(target.shortName) is lossless and can't shrink further without losing pixels. Choose HEIC or JPEG, or allow downscaling.")
            }
            notes.insert("\(ByteCount.exact(Int64(chosen.data.count))) — within the \(ByteCount.exact(limit)) limit.", at: 0)
        } else {
            let quality = lossy ? Self.defaultCompressionQuality : nil
            chosen = (try Self.encode(image, type: type, quality: quality, properties: properties), quality, image)
        }
        if let quality = chosen.quality {
            notes.insert(String(format: "%@ quality %.2f.", target.shortName, quality), at: 0)
        } else {
            notes.insert("Encoded losslessly as \(target.shortName).", at: 0)
        }

        progress(0.9)
        try Task.checkCancellation()
        let outputURL = FileStorageService.uniqueURL(in: request.outputDirectory, baseName: request.baseName, pathExtension: pathExtension)
        try chosen.data.write(to: outputURL, options: .atomic)

        let resized = chosen.image.width != image.width || chosen.image.height != image.height
        let fidelity: Fidelity
        if resized {
            fidelity = .lossy
        } else if let quality = chosen.quality {
            fidelity = quality >= 1 ? .nearLossless : .lossy
        } else {
            fidelity = .lossless
        }
        let verification: VerificationResult = resized
            ? .skipped("dimensions reduced to \(chosen.image.width)×\(chosen.image.height)")
            : PixelVerifier.compare(original: request.sourceURL, converted: outputURL)
        if request.options.stripMetadata { notes.append("EXIF, GPS, IPTC and XMP metadata stripped (orientation kept).") }
        progress(1)
        return try OutputBuilder.make(url: outputURL, fidelity: fidelity, verification: verification,
                                      notes: notes, engineName: displayName, startedAt: start)
    }

    // MARK: - Search

    /// Best encoding at the image's current size, or `nil` if nothing fits.
    static func fit(_ image: CGImage, type: String, lossy: Bool, properties: [CFString: Any],
                    limit: Int64, iterations: Int = 8) throws -> (data: Data, quality: Double?)? {
        if lossy {
            switch try bestQuality(image, type: type, properties: properties, limit: limit, iterations: iterations) {
            case let .fits(data, quality): return (data, quality)
            case .tooLarge: return nil
            }
        }
        let data = try encode(image, type: type, quality: nil, properties: properties)
        return Int64(data.count) <= limit ? (data, nil) : nil
    }

    /// Binary search over quality in [minimumQuality, 1] for the highest quality that fits.
    static func bestQuality(_ image: CGImage, type: String, properties: [CFString: Any],
                            limit: Int64, iterations: Int) throws -> SearchResult {
        try Task.checkCancellation()
        let top = try encode(image, type: type, quality: 1.0, properties: properties)
        if Int64(top.count) <= limit { return .fits(data: top, quality: 1.0) }
        let bottom = try encode(image, type: type, quality: minimumQuality, properties: properties)
        guard Int64(bottom.count) <= limit else { return .tooLarge(smallest: Int64(bottom.count)) }

        var best = (data: bottom, quality: minimumQuality)
        var low = minimumQuality, high = 1.0
        for _ in 0..<iterations {
            try Task.checkCancellation()
            let mid = (low + high) / 2
            let data = try encode(image, type: type, quality: mid, properties: properties)
            if Int64(data.count) <= limit {
                best = (data, mid)
                low = mid
            } else {
                high = mid
            }
        }
        return .fits(data: best.data, quality: best.quality)
    }

    /// Largest scale (binary search) at which some quality fits. Throws if even the smallest size fails.
    static func fitByDownscaling(_ image: CGImage, type: String, lossy: Bool, properties: [CFString: Any],
                                 limit: Int64) throws -> (data: Data, quality: Double?, image: CGImage) {
        let shortSide = Double(min(image.width, image.height))
        let minimumScale = min(1, max(16 / shortSide, 0.005))

        func attempt(_ scale: Double) throws -> (data: Data, quality: Double?, image: CGImage)? {
            try Task.checkCancellation()
            guard let scaled = downscale(image, by: scale) else { return nil }
            return try fit(scaled, type: type, lossy: lossy, properties: properties, limit: limit, iterations: 6)
                .map { ($0.data, $0.quality, scaled) }
        }

        guard var best = try attempt(minimumScale) else {
            let tiny = downscale(image, by: minimumScale) ?? image
            let smallest = try smallestEncoding(tiny, type: type, lossy: lossy, properties: properties)
            throw ConversionError.cannotMeetTargetSize(
                smallestAchievable: smallest, target: limit,
                suggestion: "Even a \(tiny.width)×\(tiny.height) px version is too large. Raise the limit.")
        }
        var low = minimumScale, high = 1.0
        for _ in 0..<7 {
            let mid = (low + high) / 2
            if let result = try attempt(mid) {
                best = result
                low = mid
            } else {
                high = mid
            }
        }
        return best
    }

    static func smallestEncoding(_ image: CGImage, type: String, lossy: Bool, properties: [CFString: Any]) throws -> Int64 {
        Int64(try encode(image, type: type, quality: lossy ? minimumQuality : nil, properties: properties).count)
    }

    // MARK: - Primitives

    static func encode(_ image: CGImage, type: String, quality: Double?, properties: [CFString: Any]) throws -> Data {
        guard let data = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil)
        else { throw ConversionError.encoderUnavailable(type) }
        var options = properties
        if let quality { options[kCGImageDestinationLossyCompressionQuality] = quality }
        if type == UTType.png.identifier {
            options[kCGImagePropertyPNGDictionary] = [kCGImagePropertyPNGCompressionFilter: 0xF8]
        }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError.writeFailed("ImageIO could not encode \(type)")
        }
        return data as Data
    }

    /// High-quality resample to `scale` of the original size (aspect ratio preserved).
    static func downscale(_ image: CGImage, by scale: Double) -> CGImage? {
        guard scale < 1 else { return image }
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        let space: CGColorSpace = {
            if let space = image.colorSpace, space.model == .rgb, space.supportsOutput { return space }
            return CGColorSpace(name: CGColorSpace.sRGB)!
        }()
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: hasAlpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
