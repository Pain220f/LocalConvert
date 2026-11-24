import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Quartz / PDFKit document conversions.
///
/// - **Images → PDF**: JPEGs are wrapped with `CGImage(jpegDataProviderSource:)`, which makes Quartz
///   embed the original DCT stream untouched; other formats are embedded with lossless Flate.
/// - **PDF → single pages**: each page is copied with PDFKit; content streams and embedded images are
///   carried over without re-compression.
/// - **PDF → embedded images**: image XObjects are read directly with `CGPDFStream`. JPEG / JPEG 2000
///   streams are written out byte-for-byte; raw (Flate etc.) samples are decoded and stored as PNG/TIFF.
struct PDFConversionEngine: ConversionEngineProtocol {
    let identifier = "quartz-pdfkit"
    let displayName = "Quartz / PDFKit"

    func supportedTargets(for sourceType: UTType) -> [SupportedFormat] {
        if sourceType.conforms(to: .pdf) { return [.pdfPages, .pdfImages] }
        if ImageConversionEngine.canRead(sourceType) || sourceType == .image { return [.pdf] }
        return []
    }

    func compressionTargets(for sourceType: UTType) -> [SupportedFormat] {
        if sourceType.conforms(to: .pdf) { return [.pdfCompressed] }
        if ImageConversionEngine.canRead(sourceType) || sourceType == .image { return [.pdfCompressed] }
        return []
    }

    func convert(_ request: ConversionRequest, progress: @escaping ProgressHandler) async throws -> ConversionOutput {
        switch request.target {
        case .pdfCompressed: try compressPDF(request, progress: progress)
        case .pdf: try compilePDF(request, progress: progress)
        case .pdfPages: try splitPages(request, progress: progress)
        case .pdfImages: try extractImages(request, progress: progress)
        default: throw ConversionError.unsupportedConversion(from: request.sourceType, to: request.target)
        }
    }

    // MARK: - Images → PDF

    private func compilePDF(_ request: ConversionRequest, progress: ProgressHandler) throws -> ConversionOutput {
        let start = ContinuousClock.now
        let strip = request.options.stripMetadata
        let baseName = request.sourceURLs.count > 1 ? "\(request.baseName) and \(request.sourceURLs.count - 1) more" : request.baseName
        let outputURL = FileStorageService.uniqueURL(in: request.outputDirectory, baseName: baseName, pathExtension: "pdf")
        // Metadata-stripped JPEG copies live here until the PDF is closed (Quartz reads them lazily).
        let scratch = request.outputDirectory.appending(path: ".scratch-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: scratch) }

        guard let consumer = CGDataConsumer(url: outputURL as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: nil, Self.pdfInfo(strip: strip))
        else { throw ConversionError.writeFailed("could not create a PDF context") }

        var passthrough = 0
        var decoded = 0
        do {
            for (index, url) in request.sourceURLs.enumerated() {
                try Task.checkCancellation()
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
                    throw ConversionError.unreadableSource(url)
                }
                try SafetyLimits.checkImage(source, at: 0, url: url)
                let properties = ImageConversionEngine.frameProperties(source, at: 0)
                let orientation = CGImagePropertyOrientation(rawValue: UInt32(ImageConversionEngine.orientation(of: properties))) ?? .up
                let isJPEG = (CGImageSourceGetType(source) as String?) == UTType.jpeg.identifier
                let isMirrored = [.upMirrored, .downMirrored, .leftMirrored, .rightMirrored].contains(orientation)

                var image: CGImage?
                var transformOrientation = orientation
                if isJPEG, !isMirrored {
                    // Quartz embeds JPEG-provider images as the original DCT stream (no re-compression).
                    // The JPEG file's own APP segments (EXIF/GPS/XMP) travel with that stream, so when
                    // stripping we first remove them without touching the compressed image data.
                    var jpegURL = url
                    if strip {
                        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                        jpegURL = scratch.appending(path: "\(index).jpg")
                        try ImageConversionEngine.writeMetadataStrippedCopy(of: url, to: jpegURL)
                    }
                    if let provider = CGDataProvider(url: jpegURL as CFURL) {
                        image = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
                        if image != nil { passthrough += 1 }
                    }
                }
                if image == nil {
                    // Decoded pixels carry no EXIF/GPS. Mirrored orientations are applied by ImageIO (exact flip/rotate).
                    image = isMirrored ? ImageConversionEngine.orientedImage(source, at: 0) : CGImageSourceCreateImageAtIndex(source, 0, nil)
                    if isMirrored { transformOrientation = .up }
                    if image != nil { decoded += 1 }
                }
                guard let image else { throw ConversionError.unreadableSource(url) }

                let width = Double(image.width) * 72 / Self.sanitizedDPI(properties[kCGImagePropertyDPIWidth])
                let height = Double(image.height) * 72 / Self.sanitizedDPI(properties[kCGImagePropertyDPIHeight])
                let swapsAxes = transformOrientation == .left || transformOrientation == .right
                var mediaBox = CGRect(x: 0, y: 0, width: swapsAxes ? height : width, height: swapsAxes ? width : height)

                context.beginPage(mediaBox: &mediaBox)
                context.concatenate(Self.displayTransform(for: transformOrientation, width: width, height: height))
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                context.endPage()
                progress(Double(index + 1) / Double(request.sourceURLs.count))
            }
            context.closePDF()
            if strip { try Self.scrubEmbeddedJPEGs(at: outputURL) }
        } catch {
            // Always close the context (it holds the file open) and never leave a partial PDF behind.
            context.closePDF()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }

        var notes: [String] = []
        if passthrough > 0 { notes.append("\(passthrough) JPEG stream(s) embedded byte-for-byte (no re-compression).") }
        if decoded > 0 { notes.append("\(decoded) image(s) embedded with lossless Flate compression.") }
        if strip { notes.append("Image metadata (EXIF, GPS, XMP) removed before embedding.") }
        let fidelity: Fidelity = decoded == 0 ? .bitExact : .lossless
        return try OutputBuilder.make(url: outputURL, fidelity: fidelity, notes: notes, engineName: displayName, startedAt: start)
    }

    /// Rewrites a PDF file with embedded-JPEG metadata neutralised (same length, see PDFMetadataScrubber).
    static func scrubEmbeddedJPEGs(at url: URL) throws {
        var data = try Data(contentsOf: url)
        if PDFMetadataScrubber.scrubEmbeddedJPEGs(in: &data) > 0 { try data.write(to: url, options: .atomic) }
    }

    /// Honest note about what stripping achieved for a PDF file or a folder of PDFs.
    static func stripReport(for url: URL) -> String {
        let files = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            ? ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
            : [url]
        let remaining = files.reduce(0) { $0 + PDFMetadataScrubber.embeddedJPEGsWithMetadata(in: $1) }
        return remaining == 0
            ? "Document info and embedded image metadata (EXIF, GPS, XMP, IPTC) removed."
            : "Warning: \(remaining) embedded image(s) are stored in a way LocalConvert can't rewrite and may still contain metadata."
    }

    /// Untrusted DPI tags are only honoured within 1…10,000 dpi; anything else means 72.
    static func sanitizedDPI(_ value: Any?) -> Double {
        guard let dpi = (value as? NSNumber)?.doubleValue, dpi.isFinite, (1...10_000).contains(dpi) else { return 72 }
        return dpi
    }

    /// Document info for new PDFs. Nothing identifying is written when the user strips metadata.
    static func pdfInfo(strip: Bool) -> CFDictionary? {
        strip ? nil : [kCGPDFContextCreator: "LocalConvert"] as CFDictionary
    }

    /// Maps the image rect (0,0,w,h) onto the page so the image displays upright (Quartz is y-up).
    static func displayTransform(for orientation: CGImagePropertyOrientation, width w: Double, height h: Double) -> CGAffineTransform {
        switch orientation {
        case .down: CGAffineTransform(translationX: w, y: h).rotated(by: .pi)
        case .right: CGAffineTransform(translationX: 0, y: w).rotated(by: -.pi / 2) // EXIF 6: rotate 90° CW
        case .left: CGAffineTransform(translationX: h, y: 0).rotated(by: .pi / 2) // EXIF 8: rotate 90° CCW
        default: .identity
        }
    }

    // MARK: - PDF → pages

    private func splitPages(_ request: ConversionRequest, progress: ProgressHandler) throws -> ConversionOutput {
        let start = ContinuousClock.now
        guard let document = PDFDocument(url: request.sourceURL) else { throw ConversionError.unreadableSource(request.sourceURL) }
        guard !document.isLocked else { throw ConversionError.encryptedPDF }
        let pageCount = document.pageCount
        guard pageCount > 0 else { throw ConversionError.unreadableSource(request.sourceURL) }

        let folder = FileStorageService.uniqueURL(in: request.outputDirectory, baseName: "\(request.baseName) pages", pathExtension: nil)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let digits = max(3, String(pageCount).count)
        var finished = false
        defer { if !finished { try? FileManager.default.removeItem(at: folder) } }

        for index in 0..<pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index), let copy = page.copy() as? PDFPage else { continue }
            let single = PDFDocument()
            single.insert(copy, at: 0)
            if !request.options.stripMetadata, let attributes = document.documentAttributes {
                single.documentAttributes = attributes
            }
            let name = "\(request.baseName) p" + String(format: "%0\(digits)d", index + 1)
            let url = folder.appending(path: name).appendingPathExtension("pdf")
            guard single.write(to: url) else { throw ConversionError.writeFailed("page \(index + 1)") }
            if request.options.stripMetadata { try Self.scrubEmbeddedJPEGs(at: url) }
            progress(Double(index + 1) / Double(pageCount))
        }
        finished = true
        var notes = ["\(pageCount) page(s) written; embedded images and vector content are not re-compressed."]
        if request.options.stripMetadata { notes.append(Self.stripReport(for: folder)) }
        return try OutputBuilder.make(url: folder, fidelity: .lossless, notes: notes, engineName: displayName, startedAt: start)
    }

    // MARK: - PDF → embedded images

    private final class StreamCollector {
        var seen = Set<OpaquePointer>()
        var streams: [(page: Int, stream: CGPDFStreamRef)] = []
    }

    private func extractImages(_ request: ConversionRequest, progress: ProgressHandler) throws -> ConversionOutput {
        let start = ContinuousClock.now
        guard let document = CGPDFDocument(request.sourceURL as CFURL) else { throw ConversionError.unreadableSource(request.sourceURL) }
        guard document.isUnlocked else { throw ConversionError.encryptedPDF }

        let collector = StreamCollector()
        for pageNumber in 1...max(1, document.numberOfPages) {
            guard let page = document.page(at: pageNumber), let resources = Self.resources(of: page) else { continue }
            Self.collectImages(in: resources, page: pageNumber, into: collector, depth: 0)
        }
        guard !collector.streams.isEmpty else { throw ConversionError.nothingToExtract }

        let folder = FileStorageService.uniqueURL(in: request.outputDirectory, baseName: "\(request.baseName) images", pathExtension: nil)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var verbatim = 0, decoded = 0, skipped = 0, jp2Converted = 0
        var perPageIndex: [Int: Int] = [:]
        var finished = false
        defer { if !finished { try? FileManager.default.removeItem(at: folder) } }
        for (offset, entry) in collector.streams.enumerated() {
            try Task.checkCancellation()
            defer { progress(Double(offset + 1) / Double(collector.streams.count)) }
            let imageNumber = (perPageIndex[entry.page] ?? 0) + 1
            perPageIndex[entry.page] = imageNumber
            let base = String(format: "page-%03d-image-%02d", entry.page, imageNumber)

            // Inflating a stream (FlateDecode etc.) happens inside CGPDFStreamCopyData, so the declared
            // dimensions are validated first: a tiny stream must not expand into gigabytes.
            guard let streamDictionary = CGPDFStreamGetDictionary(entry.stream),
                  Self.declaredDecodedSize(streamDictionary).map({ $0 <= SafetyLimits.maxPDFStreamBytes }) == true
            else { skipped += 1; continue }
            var format = CGPDFDataFormat.raw
            guard let data = CGPDFStreamCopyData(entry.stream, &format) as Data? else { skipped += 1; continue }
            switch format {
            case .jpegEncoded:
                let url = folder.appending(path: base).appendingPathExtension("jpg")
                if request.options.stripMetadata {
                    // Remove any EXIF/GPS/XMP segments inside the stream; DCT data stays byte-identical.
                    let raw = request.outputDirectory.appending(path: ".raw-\(UUID().uuidString).jpg")
                    defer { try? FileManager.default.removeItem(at: raw) }
                    try data.write(to: raw, options: .atomic)
                    try ImageConversionEngine.writeMetadataStrippedCopy(of: raw, to: url)
                } else {
                    try data.write(to: url, options: .atomic)
                }
                verbatim += 1
            case .JPEG2000 where request.options.stripMetadata:
                // JPEG 2000 can carry XMP/EXIF boxes and ImageIO can't rewrite them losslessly, so the
                // image is decoded (already size-checked above) and stored as metadata-free PNG.
                guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
                      SafetyLimits.isDecodable(source, at: 0),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                      let destination = CGImageDestinationCreateWithURL(
                        folder.appending(path: base).appendingPathExtension("png") as CFURL, UTType.png.identifier as CFString, 1, nil)
                else { skipped += 1; continue }
                CGImageDestinationAddImage(destination, image, nil)
                if CGImageDestinationFinalize(destination) { decoded += 1; jp2Converted += 1 } else { skipped += 1 }
            case .JPEG2000:
                try data.write(to: folder.appending(path: base).appendingPathExtension("jp2"), options: .atomic)
                verbatim += 1
            case .raw:
                guard let dictionary = CGPDFStreamGetDictionary(entry.stream),
                      let (image, isCMYK) = Self.makeImage(fromRaw: data, dictionary: dictionary)
                else { skipped += 1; continue }
                let type: UTType = isCMYK ? .tiff : .png
                let url = folder.appending(path: base).appendingPathExtension(isCMYK ? "tiff" : "png")
                guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
                    skipped += 1; continue
                }
                CGImageDestinationAddImage(destination, image, nil)
                if CGImageDestinationFinalize(destination) { decoded += 1 } else { skipped += 1 }
            @unknown default:
                skipped += 1
            }
        }
        guard verbatim + decoded > 0 else { throw ConversionError.nothingToExtract }
        finished = true

        var notes: [String] = []
        if verbatim > 0 { notes.append("\(verbatim) JPEG/JPEG 2000 stream(s) written byte-for-byte.") }
        if request.options.stripMetadata, verbatim > 0 { notes.append("Embedded JPEG metadata removed without re-compressing the image data.") }
        if jp2Converted > 0 { notes.append("\(jp2Converted) JPEG 2000 image(s) saved as lossless PNG so their embedded metadata could be removed.") }
        if decoded > 0 { notes.append("\(decoded) raw image(s) decoded and stored losslessly as PNG/TIFF (soft masks not applied).") }
        if skipped > 0 { notes.append("\(skipped) image(s) skipped (indexed, masks or unsupported encodings).") }
        return try OutputBuilder.make(
            url: folder, fidelity: decoded == 0 ? .bitExact : .lossless,
            notes: notes, engineName: displayName, startedAt: start
        )
    }

    /// Worst-case decoded byte size of an image XObject from its declared header (4 components),
    /// or `nil` if the header is missing or absurd.
    static func declaredDecodedSize(_ dictionary: CGPDFDictionaryRef) -> Int? {
        var width: CGPDFInteger = 0, height: CGPDFInteger = 0, bpc: CGPDFInteger = 8
        guard CGPDFDictionaryGetInteger(dictionary, "Width", &width),
              CGPDFDictionaryGetInteger(dictionary, "Height", &height),
              (1...SafetyLimits.maxImageSide).contains(width), (1...SafetyLimits.maxImageSide).contains(height)
        else { return nil }
        _ = CGPDFDictionaryGetInteger(dictionary, "BitsPerComponent", &bpc)
        guard (1...16).contains(bpc) else { return nil }
        let (pixels, o1) = width.multipliedReportingOverflow(by: height)
        let (bits, o2) = pixels.multipliedReportingOverflow(by: 4 * bpc)
        return o1 || o2 ? nil : bits / 8
    }

    /// Page resources, honouring inheritance from parent `Pages` nodes.
    private static func resources(of page: CGPDFPage) -> CGPDFDictionaryRef? {
        var node: CGPDFDictionaryRef? = page.dictionary
        var hops = 0
        while let current = node, hops < 32 {
            var resources: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(current, "Resources", &resources), let resources { return resources }
            var parent: CGPDFDictionaryRef?
            node = CGPDFDictionaryGetDictionary(current, "Parent", &parent) ? parent : nil
            hops += 1
        }
        return nil
    }

    private static func collectImages(in resources: CGPDFDictionaryRef, page: Int, into collector: StreamCollector, depth: Int) {
        guard depth < 8 else { return }
        var xObjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xObjects), let xObjects else { return }
        CGPDFDictionaryApplyBlock(xObjects, { _, object, _ in
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                  let dictionary = CGPDFStreamGetDictionary(stream)
            else { return true }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { return true }
            switch String(cString: subtype) {
            case "Image":
                if collector.seen.insert(stream.rawValue).inserted { collector.streams.append((page, stream)) }
            case "Form":
                var nested: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(dictionary, "Resources", &nested), let nested {
                    collectImages(in: nested, page: page, into: collector, depth: depth + 1)
                }
            default:
                break
            }
            return true
        }, nil)
    }

    /// Rebuilds a `CGImage` from decoded PDF image samples (8/16 bpc Gray, RGB, CMYK or ICCBased).
    private static func makeImage(fromRaw data: Data, dictionary: CGPDFDictionaryRef) -> (CGImage, Bool)? {
        var width: CGPDFInteger = 0, height: CGPDFInteger = 0, bpc: CGPDFInteger = 0
        guard CGPDFDictionaryGetInteger(dictionary, "Width", &width),
              CGPDFDictionaryGetInteger(dictionary, "Height", &height),
              CGPDFDictionaryGetInteger(dictionary, "BitsPerComponent", &bpc),
              width > 0, height > 0, bpc == 8 || bpc == 16
        else { return nil }
        var isMask: CGPDFBoolean = 0
        if CGPDFDictionaryGetBoolean(dictionary, "ImageMask", &isMask), isMask != 0 { return nil }

        var components = 0
        var space: CGColorSpace?
        var name: UnsafePointer<CChar>?
        var array: CGPDFArrayRef?
        if CGPDFDictionaryGetName(dictionary, "ColorSpace", &name), let name {
            switch String(cString: name) {
            case "DeviceGray": components = 1; space = CGColorSpaceCreateDeviceGray()
            case "DeviceRGB": components = 3; space = CGColorSpaceCreateDeviceRGB()
            case "DeviceCMYK": components = 4; space = CGColorSpaceCreateDeviceCMYK()
            default: return nil
            }
        } else if CGPDFDictionaryGetArray(dictionary, "ColorSpace", &array), let array {
            var family: UnsafePointer<CChar>?
            var iccStream: CGPDFStreamRef?
            guard CGPDFArrayGetName(array, 0, &family), let family, String(cString: family) == "ICCBased",
                  CGPDFArrayGetStream(array, 1, &iccStream), let iccStream,
                  let iccDictionary = CGPDFStreamGetDictionary(iccStream)
            else { return nil }
            var n: CGPDFInteger = 0
            guard CGPDFDictionaryGetInteger(iccDictionary, "N", &n), [1, 3, 4].contains(n) else { return nil }
            components = n
            var iccFormat = CGPDFDataFormat.raw
            if let profile = CGPDFStreamCopyData(iccStream, &iccFormat) {
                space = CGColorSpace(iccData: profile)
            }
            if space == nil {
                space = n == 1 ? CGColorSpaceCreateDeviceGray() : (n == 3 ? CGColorSpaceCreateDeviceRGB() : CGColorSpaceCreateDeviceCMYK())
            }
        } else {
            return nil
        }
        guard let space else { return nil }

        // Width/height come from an untrusted file: use overflow-checked arithmetic and a sane cap.
        let (bitsPerRow, o1) = width.multipliedReportingOverflow(by: components * bpc)
        guard !o1, width <= 1 << 16, height <= 1 << 16 else { return nil }
        let bytesPerRow = (bitsPerRow + 7) / 8
        let (byteCount, o2) = bytesPerRow.multipliedReportingOverflow(by: height)
        guard !o2, data.count >= byteCount, let provider = CGDataProvider(data: data as CFData) else { return nil }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | (bpc == 16 ? CGBitmapInfo.byteOrder16Big.rawValue : 0))
        guard let image = CGImage(
            width: width, height: height,
            bitsPerComponent: bpc, bitsPerPixel: bpc * components, bytesPerRow: bytesPerRow,
            space: space, bitmapInfo: bitmapInfo, provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ) else { return nil }
        return (image, components == 4)
    }
}
