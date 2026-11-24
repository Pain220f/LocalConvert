import AVFoundation
import Compression
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import LocalConvert

// MARK: - Hostile fixtures

enum HostileFixtures {
    /// A valid 1×1 PNG whose IHDR claims `width × height` (CRC recomputed), i.e. a decompression bomb header.
    static func pngBomb(width: UInt32, height: UInt32, at url: URL) throws -> URL {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let tiny = try Fixtures.write(context.makeImage()!, as: .png, to: url)
        var data = try Data(contentsOf: tiny)
        // Signature (8) + length (4) + "IHDR" (4) → width at 16, height at 20, CRC after 13 data bytes at 29.
        func put(_ value: UInt32, at offset: Int) {
            withUnsafeBytes(of: value.bigEndian) { data.replaceSubrange(offset..<offset + 4, with: $0) }
        }
        put(width, at: 16)
        put(height, at: 20)
        put(crc32(data[12..<29]), at: 29)
        try data.write(to: url)
        return url
    }

    /// A genuinely valid all-black grayscale PNG of `width × height`: a few hundred KB on disk,
    /// `width × height` bytes once decoded. IDAT is a zlib stream built with the Compression framework.
    static func validLargePNG(width: Int, height: Int, at url: URL) throws -> URL {
        func chunk(_ type: String, _ payload: Data) -> Data {
            var out = Data()
            withUnsafeBytes(of: UInt32(payload.count).bigEndian) { out.append(contentsOf: $0) }
            let body = Data(type.utf8) + payload
            out.append(body)
            withUnsafeBytes(of: crc32(body).bigEndian) { out.append(contentsOf: $0) }
            return out
        }
        var header = Data()
        withUnsafeBytes(of: UInt32(width).bigEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(height).bigEndian) { header.append(contentsOf: $0) }
        header.append(contentsOf: [8, 0, 0, 0, 0])            // 8-bit grayscale, no interlace

        // Raw scanlines are all zero (filter byte 0 + zero samples), so Adler-32 is a = 1, b = n mod 65521.
        let rawSize = (width + 1) * height
        var deflated = Data([0x78, 0x01])
        let zeros = [UInt8](repeating: 0, count: 1 << 20)
        var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
                                        src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ConversionError.engineFailure("zlib unavailable")
        }
        defer { compression_stream_destroy(&stream) }
        var output = [UInt8](repeating: 0, count: 1 << 16)
        var remaining = rawSize
        try zeros.withUnsafeBufferPointer { source in
            try output.withUnsafeMutableBufferPointer { destination in
                var status = COMPRESSION_STATUS_OK
                repeat {
                    if stream.src_size == 0, remaining > 0 {
                        let take = min(remaining, source.count)
                        stream.src_ptr = source.baseAddress!
                        stream.src_size = take
                        remaining -= take
                    }
                    stream.dst_ptr = destination.baseAddress!
                    stream.dst_size = destination.count
                    let flags = remaining == 0 ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                    status = compression_stream_process(&stream, flags)
                    guard status != COMPRESSION_STATUS_ERROR else { throw ConversionError.engineFailure("deflate failed") }
                    deflated.append(destination.baseAddress!, count: destination.count - stream.dst_size)
                } while status != COMPRESSION_STATUS_END
            }
        }
        let adlerB = UInt32(rawSize % 65_521)
        withUnsafeBytes(of: ((adlerB << 16) | 1).bigEndian) { deflated.append(contentsOf: $0) }

        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            + chunk("IHDR", header) + chunk("IDAT", deflated) + chunk("IEND", Data())
        try png.write(to: url)
        return url
    }

    /// A GIF whose logical screen is `side × side` but holds a single 1×1 frame: tiny on disk,
    /// gigabytes once decoded onto its canvas.
    static func gifBomb(side: UInt16, at url: URL) throws -> URL {
        var bytes = Array("GIF89a".utf8)
        bytes += [UInt8(side & 0xFF), UInt8(side >> 8), UInt8(side & 0xFF), UInt8(side >> 8)]
        bytes += [0x80, 0x00, 0x00]                     // global colour table (2 entries), bg, aspect
        bytes += [0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF]   // black, white
        bytes += [0x2C, 0, 0, 0, 0, 0x01, 0x00, 0x01, 0x00, 0x00] // 1×1 image at (0,0)
        bytes += [0x02, 0x02, 0x44, 0x01, 0x00]         // LZW data for one pixel
        bytes += [0x3B]
        try Data(bytes).write(to: url)
        return url
    }

    static func crc32(_ bytes: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1))) }
        }
        return ~crc
    }

    /// Minimal hand-written PDF. CGPDF rebuilds the (absent) xref table on open.
    static func pdf(mediaBox: String, xObject: String? = nil, at url: URL) throws -> URL {
        var objects = [
            "1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj",
            "2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj",
        ]
        if let xObject {
            objects.append("3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [\(mediaBox)] /Resources << /XObject << /Im1 4 0 R >> >> /Contents 5 0 R >> endobj")
            objects.append("4 0 obj \(xObject) endobj")
        } else {
            objects.append("3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [\(mediaBox)] /Contents 5 0 R >> endobj")
        }
        objects.append("5 0 obj << /Length 0 >>\nstream\n\nendstream endobj")
        let text = "%PDF-1.4\n" + objects.joined(separator: "\n") + "\ntrailer << /Root 1 0 R >>\n%%EOF\n"
        try Data(text.utf8).write(to: url)
        return url
    }
}

private func catchConversionError(_ body: () async throws -> Void) async -> ConversionError? {
    do { try await body(); return nil } catch let error as ConversionError { return error } catch { return nil }
}

// MARK: - V-01 / V-02 · decompression bombs and hostile headers

@Suite("Security: hostile inputs", .serialized)
struct HostileInputTests {
    @Test("A valid 156-megapixel PNG (≈150 KB on disk) is rejected before decoding, in every path")
    func imageBombRejected() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bomb = try HostileFixtures.validLargePNG(width: 13_000, height: 12_000, at: directory.appending(path: "bomb.png"))
        #expect(try Fixtures.fileSize(bomb) < 1_000_000)
        let properties = CGImageSourceCreateWithURL(bomb as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
        #expect((properties?[kCGImagePropertyPixelWidth] as? Int) == 13_000, "ImageIO must accept the file for this test to mean anything")

        for (target, mode) in [(SupportedFormat.tiff, ConversionMode.convertFormat), (.jpeg, .compressSize)] {
            let request = ConversionRequest(sourceURLs: [bomb], sourceType: .png, target: target,
                                            options: ConversionOptions(mode: mode, targetMaxBytes: mode == .compressSize ? 50_000 : nil),
                                            outputDirectory: directory)
            let error = await catchConversionError { _ = try await ImageConversionEngine().convert(request) { _ in } }
            guard case .inputTooLarge = error else { Issue.record("\(target): expected inputTooLarge, got \(String(describing: error))"); continue }
        }
        let pdfError = await catchConversionError {
            _ = try await PDFConversionEngine().convert(Fixtures.request(bomb, .png, .pdf, output: directory)) { _ in }
        }
        guard case .inputTooLarge = pdfError else { Issue.record("PDF: got \(String(describing: pdfError))"); return }
        guard case .skipped = PixelVerifier.compare(original: bomb, converted: bomb) else {
            Issue.record("verifier must not decode a bomb"); return
        }
        #expect(await PreviewLoader.image(at: bomb) == nil)
    }

    @Test("Forged headers (PNG IHDR, GIF canvas) are refused without decoding")
    func forgedHeadersRefused() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try HostileFixtures.pngBomb(width: 40_000, height: 40_000, at: directory.appending(path: "forged.png"))
        let gif = try HostileFixtures.gifBomb(side: 60_000, at: directory.appending(path: "forged.gif"))
        for (url, type) in [(png, UTType.png), (gif, .gif)] {
            let error = await catchConversionError {
                _ = try await ImageConversionEngine().convert(Fixtures.request(url, type, .tiff, output: directory)) { _ in }
            }
            switch error {
            case .inputTooLarge, .unreadableSource: break
            default: Issue.record("\(url.lastPathComponent): expected a clean refusal, got \(String(describing: error))")
            }
        }
    }

    @Test("Images at the limit's edge still work")
    func normalImagesUnaffected() async throws {
        #expect(throws: Never.self) { try SafetyLimits.checkDimensions(width: 12_000, height: 12_000, what: "Image") }
        #expect(throws: ConversionError.self) { try SafetyLimits.checkDimensions(width: 0, height: 10, what: "Image") }
        #expect(throws: ConversionError.self) { try SafetyLimits.checkDimensions(width: Int.max, height: 2, what: "Image") }
    }

    @Test("A PDF image stream declaring 60,000 × 60,000 px is never inflated")
    func pdfStreamBombSkipped() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pdf = try HostileFixtures.pdf(
            mediaBox: "0 0 612 792",
            xObject: "<< /Type /XObject /Subtype /Image /Width 60000 /Height 60000 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Length 4 >>\nstream\nabcd\nendstream",
            at: directory.appending(path: "bomb.pdf"))
        let error = await catchConversionError {
            _ = try await PDFConversionEngine().convert(Fixtures.request(pdf, .pdf, .pdfImages, output: directory)) { _ in }
        }
        guard case .nothingToExtract = error else { Issue.record("expected the stream to be skipped, got \(String(describing: error))"); return }
    }

    @Test("Rasterizing pages with empty or absurd boxes fails cleanly instead of crashing",
          arguments: ["0 0 0 0", "0 0 1e30 1e30", "0 0 14000 14000"])
    func hostilePageBoxes(box: String) throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try HostileFixtures.pdf(mediaBox: box, at: directory.appending(path: "page.pdf"))
        guard let document = CGPDFDocument(url as CFURL), document.numberOfPages >= 1 else { return } // CGPDF refused it: also safe
        do {
            let (image, _) = try PDFConversionEngine.renderPage(document, number: 1, scale: 1)
            #expect(image.width <= SafetyLimits.maxRasterSide && image.height <= SafetyLimits.maxRasterSide)
            #expect(image.width * image.height <= SafetyLimits.maxRasterPixels)
        } catch {
            #expect(error is ConversionError)
        }
    }

    @Test("Size search survives a limit exactly equal to the smallest result (no force-unwrap)")
    func pdfSearchBoundary() throws {
        let image = NoisyFixture.image(width: 300, height: 200)
        let render: (Int, Double) throws -> (CGImage, CGRect) = { _, scale in
            (ImageConversionEngine.downscale(image, by: scale)!, CGRect(x: 0, y: 0, width: 300, height: 200))
        }
        let smallest = try PDFConversionEngine.makeJPEGPDF(count: 2, quality: ImageConversionEngine.minimumQuality,
                                                           scale: 0.1, strip: false, render: render)
        let result = try PDFConversionEngine.fitJPEGPages(count: 2, limit: Int64(smallest.count), allowScaling: true,
                                                          strip: false, render: render)
        #expect(Int64(result.data.count) <= Int64(smallest.count))
    }
}

// MARK: - V-05 · numeric conversions

@Suite("Security: numeric hardening")
struct NumericHardeningTests {
    @Test func conversionsNeverTrap() {
        #expect(SafetyLimits.int(.infinity, in: 1...100) == nil)
        #expect(SafetyLimits.int(.nan, in: 1...100) == nil)
        #expect(SafetyLimits.int(1e300, in: 1...100) == nil)
        #expect(SafetyLimits.int(50.7, in: 1...100) == 50)
        #expect(SafetyLimits.clampedInt(1e300, to: 64_000...320_000) == 320_000)
        #expect(SafetyLimits.clampedInt(-5, to: 64_000...320_000) == 64_000)
        #expect(SafetyLimits.clampedInt(.nan, to: 0...1) == nil)
        #expect(!SafetyLimits.validDuration(.infinity))
        #expect(!SafetyLimits.validDuration(1e-9))
        #expect(!SafetyLimits.validDuration(.nan))
        #expect(SafetyLimits.validDuration(1))
    }

    @MainActor
    @Test func targetSizeIsClamped() {
        let job = ConversionJob(sourceURLs: [URL(filePath: "/tmp/a.png")], sourceType: .png, category: .image,
                                originalBytes: 1_000_000, availableTargets: [.png], compressionTargets: [.jpeg])
        job.setMode(.compressSize)
        job.setTargetMaxBytes(.max)
        #expect(job.targetMaxBytes == SafetyLimits.maxTargetBytes)
    }

    @Test("AAC with an enormous limit picks a valid bitrate instead of overflowing")
    func hugeAudioLimit() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "clip.mov")
        try await VideoFixtures.makeMovie(at: source)
        let request = ConversionRequest(sourceURLs: [source], sourceType: .quickTimeMovie, target: .aac,
                                        options: ConversionOptions(mode: .compressSize, targetMaxBytes: SafetyLimits.maxTargetBytes),
                                        outputDirectory: directory)
        let output = try await MediaConversionEngine().convert(request) { _ in }
        #expect(output.notes.contains { $0.contains("320 kbit/s") || $0.contains("192 kbit/s") })
    }
}

// MARK: - V-03 · metadata stripping

@Suite("Security: metadata stripping", .serialized)
struct MetadataStrippingTests {
    private static let marker = "LCSECRETXMP"

    private func gpsJPEG(in directory: URL) throws -> URL {
        try Fixtures.write(Fixtures.gradientImage(), as: .jpeg, to: directory.appending(path: "gps.jpg"), properties: [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.33, kCGImagePropertyGPSLatitudeRef: "N"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "private note"],
        ])
    }

    /// A PDF with an Author, a catalog XMP packet and a GPS-tagged embedded JPEG.
    private func taggedPDF(in directory: URL) async throws -> URL {
        let jpeg = try gpsJPEG(in: directory)
        let plain = try await PDFConversionEngine().convert(Fixtures.request(jpeg, .jpeg, .pdf, output: directory)) { _ in }
        let document = try #require(CGPDFDocument(plain.url as CFURL))
        let url = directory.appending(path: "tagged.pdf")
        let context = try #require(CGContext(url as CFURL, mediaBox: nil, [kCGPDFContextAuthor: "Jane Example"] as CFDictionary))
        context.addDocumentMetadata(Data("<x:xmpmeta xmlns:x='adobe:ns:meta/'>\(Self.marker)</x:xmpmeta>".utf8) as CFData)
        let page = try #require(document.page(at: 1))
        var box = page.getBoxRect(.mediaBox)
        context.beginPage(mediaBox: &box)
        context.drawPDFPage(page)
        context.endPage()
        context.closePDF()
        return url
    }

    private func catalogHasXMP(_ url: URL) -> Bool {
        guard let document = CGPDFDocument(url as CFURL), let catalog = document.catalog else { return false }
        var stream: CGPDFStreamRef?
        guard CGPDFDictionaryGetStream(catalog, "Metadata", &stream), let stream else { return false }
        var format = CGPDFDataFormat.raw
        return (CGPDFStreamCopyData(stream, &format) as Data?)?.range(of: Data(Self.marker.utf8)) != nil
    }

    private func info(_ url: URL, _ key: String) -> String? {
        // Keep the document alive: its Info dictionary is borrowed, not owned.
        guard let document = CGPDFDocument(url as CFURL) else { return nil }
        return withExtendedLifetime(document) {
            guard let info = document.info else { return nil }
            var string: CGPDFStringRef?
            guard CGPDFDictionaryGetString(info, key, &string), let string else { return nil }
            return CGPDFStringCopyTextString(string) as String?
        }
    }

    @Test("Split pages and compressed PDFs drop catalog XMP, Author and embedded EXIF/GPS",
          arguments: [SupportedFormat.pdfPages, .pdfCompressed])
    func pdfStripping(target: SupportedFormat) async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await taggedPDF(in: directory)
        #expect(catalogHasXMP(source))
        #expect(info(source, "Author") == "Jane Example")
        #expect(PDFMetadataScrubber.embeddedJPEGsWithMetadata(in: source) == 1)

        let request = ConversionRequest(sourceURLs: [source], sourceType: .pdf, target: target,
                                        options: ConversionOptions(stripMetadata: true, mode: target == .pdfCompressed ? .compressSize : .convertFormat),
                                        outputDirectory: directory)
        let output = try await PDFConversionEngine().convert(request) { _ in }
        let file = output.isDirectory
            ? try #require(try FileManager.default.contentsOfDirectory(at: output.url, includingPropertiesForKeys: nil).first)
            : output.url

        #expect(!catalogHasXMP(file))
        #expect(info(file, "Author") == nil)
        #expect(PDFMetadataScrubber.embeddedJPEGsWithMetadata(in: file) == 0)
        #expect(output.notes.contains { $0.hasPrefix("Document info and embedded image metadata") })
    }

    @Test("Images → PDF with stripping writes no Creator and no image metadata")
    func compiledPDFStripping() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let jpeg = try gpsJPEG(in: directory)
        let kept = try await PDFConversionEngine().convert(Fixtures.request(jpeg, .jpeg, .pdf, output: directory)) { _ in }
        #expect(info(kept.url, "Creator") == "LocalConvert")

        let stripped = try await PDFConversionEngine().convert(Fixtures.request(jpeg, .jpeg, .pdf, strip: true, output: directory)) { _ in }
        #expect(info(stripped.url, "Creator") == nil)
        #expect(PDFMetadataScrubber.embeddedJPEGsWithMetadata(in: stripped.url) == 0)
    }

    @Test("The scrubber keeps length and pixels identical and leaves no identifying segments")
    func scrubberIsLengthPreserving() throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let jpeg = try Data(contentsOf: try gpsJPEG(in: directory))
        #expect(PDFMetadataScrubber.hasIdentifyingSegments(jpeg))

        var wrapped = Data("1 0 obj << /Filter /DCTDecode >>\nstream\n".utf8) + jpeg + Data("\nendstream".utf8)
        let originalCount = wrapped.count
        #expect(PDFMetadataScrubber.scrubEmbeddedJPEGs(in: &wrapped) >= 1)
        #expect(wrapped.count == originalCount)

        let prefix = Data("1 0 obj << /Filter /DCTDecode >>\nstream\n".utf8).count
        let scrubbed = wrapped.subdata(in: prefix..<(prefix + jpeg.count))
        #expect(!PDFMetadataScrubber.hasIdentifyingSegments(scrubbed))
        let a = directory.appending(path: "a.jpg"), b = directory.appending(path: "b.jpg")
        try jpeg.write(to: a)
        try scrubbed.write(to: b)
        #expect(PixelVerifier.compare(original: a, converted: b) == .pixelIdentical)
        let properties = CGImageSourceCreateWithURL(b as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
        #expect(properties?[kCGImagePropertyGPSDictionary] == nil)
    }

    @Test("Remux with stripping removes every asset- and track-level tag")
    func remuxStripsAllTags() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "tagged.mov")
        try await VideoFixtures.makeMovie(at: source)
        #expect(!(try await VideoFixtures.metadataIdentifiers(of: source)).isEmpty)

        let output = try await MediaConversionEngine().convert(
            Fixtures.request(source, .quickTimeMovie, .mp4, strip: true, output: directory)) { _ in }
        #expect(try await VideoFixtures.metadataIdentifiers(of: output.url).isEmpty)
        for track in try await AVURLAsset(url: output.url).load(.tracks) {
            #expect(try await track.load(.metadata).isEmpty)
            #expect(track.mediaType != .metadata)
        }
        #expect(output.fidelity == .bitExact)
    }
}

// MARK: - V-06 / V-07 · subprocess buffer and session isolation

@Suite("Security: process and storage hygiene", .serialized)
struct HygieneTests {
    @Test func boundedBufferKeepsOnlyTheTail() {
        let buffer = BoundedBuffer(capacity: 1_024)
        for index in 0..<200 { buffer.append(Data(repeating: UInt8(index % 251), count: 1_000)) }
        #expect(buffer.contents.count == 1_024)
        #expect(buffer.contents.last == UInt8(199 % 251))
    }

    @Test("Launch cleanup keeps live sessions (other instances) and removes dead ones")
    func sessionIsolation() throws {
        let live = FileStorageService()
        let liveJob = try live.makeJobDirectory(for: UUID())
        var deadDirectory: URL?
        do {
            let dead = FileStorageService()
            _ = try dead.makeJobDirectory(for: UUID())
            deadDirectory = dead.sessionDirectory
        }   // `dead` is released here, which releases its lock — like a crashed instance
        let orphan = FileStorageService.rootDirectory.appending(path: "orphan-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)

        // Simulate the purge another process would run: it must not see our sessions as stale.
        #expect(SessionLock.isHeld(at: live.sessionDirectory.appending(path: FileStorageService.lockFileName)))
        #expect(!SessionLock.isHeld(at: try #require(deadDirectory).appending(path: FileStorageService.lockFileName)))
        FileStorageService.purgeStaleSessions()

        #expect(FileManager.default.fileExists(atPath: liveJob.path))
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
    }
}
