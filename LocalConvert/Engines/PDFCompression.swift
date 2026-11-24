import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Compress Size mode for PDFs (and images compiled into a PDF).
///
/// 1. PDF sources are first re-saved by PDFKit with JPEG image compression and screen-resolution
///    image optimisation. Text and vector content are kept.
/// 2. If that is still over the limit, pages are rasterized to JPEG with a quality (and, if needed,
///    resolution) binary search — but only when the user allowed it, because text stops being
///    selectable. Otherwise `cannotMeetTargetSize` is thrown.
/// Images are always embedded as size-searched JPEG streams.
extension PDFConversionEngine {
    /// Rasterization resolution at scale 1.
    static let rasterDPI = 150.0

    func compressPDF(_ request: ConversionRequest, progress: ProgressHandler) throws -> ConversionOutput {
        let start = ContinuousClock.now
        let limit = request.options.targetMaxBytes
        let outputURL = FileStorageService.uniqueURL(in: request.outputDirectory, baseName: request.baseName, pathExtension: "pdf")
        var notes: [String] = []
        var data: Data

        if request.sourceType.conforms(to: .pdf) {
            guard let original = PDFDocument(url: request.sourceURL) else { throw ConversionError.unreadableSource(request.sourceURL) }
            guard !original.isLocked else { throw ConversionError.encryptedPDF }
            // When stripping, pages are copied into a fresh document so the catalog's XMP packet and
            // document info are left behind (only the page content travels).
            let document = request.options.stripMetadata ? Self.freshCopy(of: original) : original
            guard let optimized = document.dataRepresentation(options: [
                PDFDocumentWriteOption.saveImagesAsJPEGOption: true,
                PDFDocumentWriteOption.optimizeImagesForScreenOption: true,
            ]) else { throw ConversionError.writeFailed("PDFKit could not re-save the document") }
            progress(0.3)
            data = optimized
            if request.options.stripMetadata { PDFMetadataScrubber.scrubEmbeddedJPEGs(in: &data) }
            notes.append("Images re-compressed as JPEG at screen resolution; text and vectors kept.")

            if let limit, Int64(data.count) > limit {
                guard request.options.allowResizeToFitTarget else {
                    throw ConversionError.cannotMeetTargetSize(
                        smallestAchievable: Int64(data.count), target: limit,
                        suggestion: "Turn on “Allow downscaling” to rasterize pages to JPEG (text will no longer be selectable), or raise the limit.")
                }
                guard let pdf = CGPDFDocument(request.sourceURL as CFURL), pdf.numberOfPages > 0 else {
                    throw ConversionError.unreadableSource(request.sourceURL)
                }
                guard pdf.numberOfPages <= SafetyLimits.maxRasterizedPages else {
                    throw ConversionError.inputTooLarge(
                        "\(pdf.numberOfPages) pages; rasterizing is limited to \(SafetyLimits.maxRasterizedPages).")
                }
                let result = try Self.fitJPEGPages(count: pdf.numberOfPages, limit: limit, allowScaling: true,
                                                   strip: request.options.stripMetadata) { index, scale in
                    try Self.renderPage(pdf, number: index + 1, scale: scale)
                }
                data = result.data
                notes = [String(format: "Pages rasterized at %.0f dpi as JPEG (quality %.2f); text is no longer selectable.",
                                Self.rasterDPI * result.scale, result.quality)]
            }
        } else {
            let sources = try request.sourceURLs.map { url -> (CGImageSource, CGRect) in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
                    throw ConversionError.unreadableSource(url)
                }
                try SafetyLimits.checkImage(source, at: 0, url: url)
                guard let image = ImageConversionEngine.orientedImage(source, at: 0) else { throw ConversionError.unreadableSource(url) }
                let properties = ImageConversionEngine.frameProperties(source, at: 0)
                let points = 72 / PDFConversionEngine.sanitizedDPI(properties[kCGImagePropertyDPIWidth])
                return (source, CGRect(x: 0, y: 0, width: Double(image.width) * points, height: Double(image.height) * points))
            }
            let render: (Int, Double) throws -> (CGImage, CGRect) = { index, scale in
                guard let image = ImageConversionEngine.orientedImage(sources[index].0, at: 0),
                      let scaled = ImageConversionEngine.downscale(image, by: scale)
                else { throw ConversionError.unreadableSource(request.sourceURLs[index]) }
                return (scaled, sources[index].1)
            }
            if let limit {
                let result = try Self.fitJPEGPages(count: sources.count, limit: limit, allowScaling: request.options.allowResizeToFitTarget,
                                                   strip: request.options.stripMetadata, render: render)
                data = result.data
                notes.append(String(format: "Images embedded as JPEG (quality %.2f)%@.", result.quality,
                                    result.scale < 1 ? String(format: " at %.0f%% resolution", result.scale * 100) : ""))
            } else {
                data = try Self.makeJPEGPDF(count: sources.count, quality: ImageConversionEngine.defaultCompressionQuality,
                                            scale: 1, strip: request.options.stripMetadata, render: render)
                notes.append(String(format: "Images embedded as JPEG (quality %.2f).", ImageConversionEngine.defaultCompressionQuality))
            }
        }

        try Task.checkCancellation()
        if let limit { notes.append("\(ByteCount.exact(Int64(data.count))) — within the \(ByteCount.exact(limit)) limit.") }
        try data.write(to: outputURL, options: .atomic)
        if request.options.stripMetadata { notes.append(PDFConversionEngine.stripReport(for: outputURL)) }
        progress(1)
        return try OutputBuilder.make(url: outputURL, fidelity: .lossy, notes: notes, engineName: displayName, startedAt: start)
    }

    static func freshCopy(of document: PDFDocument) -> PDFDocument {
        let copy = PDFDocument()
        for index in 0..<document.pageCount {
            if let page = document.page(at: index)?.copy() as? PDFPage { copy.insert(page, at: copy.pageCount) }
        }
        return copy
    }

    // MARK: - Search

    /// Highest quality (then, if allowed, largest scale) whose JPEG-page PDF fits under `limit`.
    static func fitJPEGPages(count: Int, limit: Int64, allowScaling: Bool, strip: Bool,
                             render: (Int, Double) throws -> (CGImage, CGRect)) throws -> (data: Data, quality: Double, scale: Double) {
        let minimumQuality = ImageConversionEngine.minimumQuality
        func build(_ quality: Double, _ scale: Double) throws -> Data {
            try makeJPEGPDF(count: count, quality: quality, scale: scale, strip: strip, render: render)
        }
        /// Highest quality that fits at `scale`, given an already-built minimum-quality document.
        func bestQuality(at scale: Double, iterations: Int, floor: Data? = nil) throws -> (Data, Double)? {
            let low = try floor ?? build(minimumQuality, scale)
            guard Int64(low.count) <= limit else { return nil }
            var best = (low, minimumQuality)
            var lowQ = minimumQuality, highQ = 1.0
            for _ in 0..<iterations {
                let mid = (lowQ + highQ) / 2
                let candidate = try build(mid, scale)
                if Int64(candidate.count) <= limit { best = (candidate, mid); lowQ = mid } else { highQ = mid }
            }
            return best
        }

        if let fit = try bestQuality(at: 1, iterations: 6) { return (fit.0, fit.1, 1) }
        let minimumScale = 0.1
        // Built once and reused below: no second render, and no assumption that two renders match.
        let smallestData = try build(minimumQuality, allowScaling ? minimumScale : 1)
        let smallest = Int64(smallestData.count)
        guard allowScaling, smallest <= limit else {
            throw ConversionError.cannotMeetTargetSize(
                smallestAchievable: smallest, target: limit,
                suggestion: allowScaling ? "Raise the limit." : "Turn on “Allow downscaling”, or raise the limit.")
        }
        var best = (smallestData, minimumQuality, minimumScale)
        if let fit = try bestQuality(at: minimumScale, iterations: 4, floor: smallestData) { best = (fit.0, fit.1, minimumScale) }
        var low = minimumScale, high = 1.0
        for _ in 0..<5 {
            let mid = (low + high) / 2
            if let fit = try bestQuality(at: mid, iterations: 4) { best = (fit.0, fit.1, mid); low = mid } else { high = mid }
        }
        return best
    }

    // MARK: - Builders

    static func makeJPEGPDF(count: Int, quality: Double, scale: Double, strip: Bool,
                            render: (Int, Double) throws -> (CGImage, CGRect)) throws -> Data {
        guard let data = CFDataCreateMutable(nil, 0), let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: nil, PDFConversionEngine.pdfInfo(strip: strip))
        else { throw ConversionError.writeFailed("could not create a PDF context") }
        do {
            for index in 0..<count {
                try Task.checkCancellation()
                let (image, box) = try render(index, scale)
                let jpeg = try ImageConversionEngine.encode(image, type: UTType.jpeg.identifier, quality: quality, properties: [:])
                guard let provider = CGDataProvider(data: jpeg as CFData),
                      let embedded = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
                else { throw ConversionError.writeFailed("JPEG page \(index + 1)") }
                var mediaBox = box
                context.beginPage(mediaBox: &mediaBox)
                context.draw(embedded, in: box)
                context.endPage()
            }
            context.closePDF()
        } catch {
            context.closePDF()
            throw error
        }
        return data as Data
    }

    /// Renders page `number` (1-based) upright on white at `rasterDPI × scale`.
    static func renderPage(_ document: CGPDFDocument, number: Int, scale: Double) throws -> (CGImage, CGRect) {
        guard let page = document.page(at: number) else { throw ConversionError.engineFailure("Missing page \(number)") }
        let crop = page.getBoxRect(.cropBox)
        // The crop box comes from the file: reject empty, non-finite or absurd boxes (max 200 inches).
        guard crop.width.isFinite, crop.height.isFinite, crop.width >= 1, crop.height >= 1,
              crop.width <= 14_400, crop.height <= 14_400
        else { throw ConversionError.inputTooLarge("page \(number) has an invalid size (\(crop.width)×\(crop.height) pt).") }
        let rotated = abs(page.rotationAngle) % 180 == 90
        let pageBox = CGRect(x: 0, y: 0, width: rotated ? crop.height : crop.width, height: rotated ? crop.width : crop.height)
        // Cap the bitmap: at most maxRasterSide per side and maxRasterPixels in total.
        var pixelsPerPoint = rasterDPI / 72 * scale
        pixelsPerPoint = min(pixelsPerPoint, Double(SafetyLimits.maxRasterSide) / max(pageBox.width, pageBox.height))
        pixelsPerPoint = min(pixelsPerPoint, (Double(SafetyLimits.maxRasterPixels) / (pageBox.width * pageBox.height)).squareRoot())
        guard let width = SafetyLimits.int((pageBox.width * pixelsPerPoint).rounded(), in: 1...SafetyLimits.maxRasterSide),
              let height = SafetyLimits.int((pageBox.height * pixelsPerPoint).rounded(), in: 1...SafetyLimits.maxRasterSide)
        else { throw ConversionError.inputTooLarge("page \(number) cannot be rasterized safely.") }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw ConversionError.writeFailed("could not allocate page \(number)") }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        // getDrawingTransform never scales up, so scale explicitly and let it handle rotation/origin only.
        context.scaleBy(x: CGFloat(width) / pageBox.width, y: CGFloat(height) / pageBox.height)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: pageBox, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { throw ConversionError.writeFailed("page \(number)") }
        return (image, pageBox)
    }
}
