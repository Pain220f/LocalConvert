import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import LocalConvert

/// Deterministic fixtures generated in the sandbox container's temp directory.
enum Fixtures {
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "LocalConvertTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Opaque gradient with high-frequency detail so lossy encoders would visibly change pixels.
    static func gradientImage(width: Int = 96, height: Int = 64) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                pixels[offset] = UInt8((x * 255) / max(width - 1, 1))
                pixels[offset + 1] = UInt8((y * 255) / max(height - 1, 1))
                pixels[offset + 2] = UInt8((x ^ y) & 0xFF)
                pixels[offset + 3] = 255
            }
        }
        return context.makeImage()!
    }

    @discardableResult
    static func write(_ image: CGImage, as type: UTType, to url: URL, properties: [CFString: Any] = [:]) throws -> URL {
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    static func request(_ source: URL, _ type: UTType, _ target: SupportedFormat, strip: Bool = false, output: URL) -> ConversionRequest {
        ConversionRequest(sourceURLs: [source], sourceType: type, target: target,
                          options: ConversionOptions(stripMetadata: strip), outputDirectory: output)
    }

    static func fileSize(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? -1
    }
}

@Suite("Image conversion")
struct ImageConversionTests {
    let engine = ImageConversionEngine()

    @Test("Lossless targets are pixel-identical and report exact byte sizes",
          arguments: [SupportedFormat.tiff, .png, .bmp])
    func losslessTargets(target: SupportedFormat) async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try Fixtures.write(Fixtures.gradientImage(), as: .png, to: directory.appending(path: "source.png"))

        let output = try await engine.convert(Fixtures.request(source, .png, target, output: directory)) { _ in }

        #expect(output.verification == .pixelIdentical)
        #expect(output.fidelity.isLossless)
        #expect(output.byteCount == (try Fixtures.fileSize(output.url)))
        #expect(output.byteCount > 0)
        #expect(output.url.pathExtension == target.fileExtension)
    }

    @Test("PNG → TIFF → PNG round trip is lossless")
    func roundTrip() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try Fixtures.write(Fixtures.gradientImage(), as: .png, to: directory.appending(path: "original.png"))

        let tiff = try await engine.convert(Fixtures.request(original, .png, .tiff, output: directory)) { _ in }
        let png = try await engine.convert(Fixtures.request(tiff.url, .tiff, .png, output: directory)) { _ in }

        #expect(PixelVerifier.compare(original: original, converted: png.url) == .pixelIdentical)
    }

    @Test("JPEG metadata stripping is bit-exact for image data and removes GPS")
    func jpegStripIsLossless() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try Fixtures.write(Fixtures.gradientImage(), as: .jpeg, to: directory.appending(path: "photo.jpg"), properties: [
            kCGImageDestinationLossyCompressionQuality: 0.8,
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 37.3349, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 122.0090, kCGImagePropertyGPSLongitudeRef: "W",
            ],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "private"],
        ])
        let sourceProperties = try #require(CGImageSourceCreateWithURL(source as CFURL, nil)
            .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] })
        #expect(sourceProperties[kCGImagePropertyGPSDictionary] != nil, "fixture must contain GPS")

        let output = try await engine.convert(Fixtures.request(source, .jpeg, .jpeg, strip: true, output: directory)) { _ in }

        #expect(output.fidelity == .bitExact)
        #expect(output.verification == .pixelIdentical)
        let properties = try #require(CGImageSourceCreateWithURL(output.url as CFURL, nil)
            .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] })
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        #expect(output.byteCount == (try Fixtures.fileSize(output.url)))
    }

    @Test("Re-encoding with metadata stripping removes GPS for lossless targets")
    func stripOnReencode() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try Fixtures.write(Fixtures.gradientImage(), as: .tiff, to: directory.appending(path: "scan.tiff"), properties: [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 51.5, kCGImagePropertyGPSLatitudeRef: "N"],
        ])
        let output = try await engine.convert(Fixtures.request(source, .tiff, .png, strip: true, output: directory)) { _ in }
        let properties = try #require(CGImageSourceCreateWithURL(output.url as CFURL, nil)
            .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] })
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        #expect(output.verification == .pixelIdentical)
    }

    @Test("Lossy targets are detected and reported, not hidden")
    func lossyIsReported() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try Fixtures.write(Fixtures.gradientImage(), as: .png, to: directory.appending(path: "source.png"))
        let output = try await engine.convert(Fixtures.request(source, .png, .jpeg, output: directory)) { _ in }
        #expect(!output.fidelity.isLossless)
        if case .differs = output.verification {} else {
            Issue.record("JPEG output should not verify as pixel-identical: \(output.verification)")
        }
    }

    @Test("JPEG → PDF embeds the original stream; extraction gives back identical pixels")
    func jpegPDFRoundTrip() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let jpeg = try Fixtures.write(Fixtures.gradientImage(), as: .jpeg, to: directory.appending(path: "page.jpg"),
                                      properties: [kCGImageDestinationLossyCompressionQuality: 0.85])
        let pdfEngine = PDFConversionEngine()

        let pdf = try await pdfEngine.convert(Fixtures.request(jpeg, .jpeg, .pdf, output: directory)) { _ in }
        #expect(pdf.fidelity == .bitExact)

        let extracted = try await pdfEngine.convert(Fixtures.request(pdf.url, .pdf, .pdfImages, output: directory)) { _ in }
        #expect(extracted.isDirectory)
        #expect(extracted.fidelity == .bitExact)
        let files = try FileManager.default.contentsOfDirectory(at: extracted.url, includingPropertiesForKeys: nil)
        let image = try #require(files.first { $0.pathExtension == "jpg" })
        #expect(PixelVerifier.compare(original: jpeg, converted: image) == .pixelIdentical)
        #expect(extracted.byteCount == (try Fixtures.fileSize(image)))
    }

    @Test("Splitting a PDF produces one file per page and sums sizes exactly")
    func splitPages() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = try Fixtures.write(Fixtures.gradientImage(), as: .png, to: directory.appending(path: "a.png"))
        let b = try Fixtures.write(Fixtures.gradientImage(width: 40, height: 80), as: .png, to: directory.appending(path: "b.png"))
        let pdfEngine = PDFConversionEngine()
        let combined = try await pdfEngine.convert(ConversionRequest(
            sourceURLs: [a, b], sourceType: .png, target: .pdf, options: .init(), outputDirectory: directory)) { _ in }

        let pages = try await pdfEngine.convert(Fixtures.request(combined.url, .pdf, .pdfPages, output: directory)) { _ in }
        #expect(pages.fileCount == 2)
        let files = try FileManager.default.contentsOfDirectory(at: pages.url, includingPropertiesForKeys: nil)
        let sum = try files.reduce(Int64(0)) { $0 + (try Fixtures.fileSize($1)) }
        #expect(pages.byteCount == sum)
    }
}

@Suite("Size reporting")
struct SizeDeltaTests {
    @Test func percentages() {
        let smaller = SizeDelta(before: 1_000, after: 750)
        #expect(smaller.delta == -250)
        #expect(smaller.percent == -25)
        #expect(smaller.isSmaller)
        #expect(smaller.formattedPercent == "-25.00%")

        let larger = SizeDelta(before: 200, after: 300)
        #expect(larger.percent == 50)
        #expect(!larger.isSmaller)

        #expect(SizeDelta(before: 0, after: 10).percent == 0)
        #expect(SizeDelta(before: 10, after: 10).formattedPercent == "±0.00%")
    }

    @Test func registryOffersLosslessDefaults() {
        let registry = EngineRegistry.standard
        #expect(registry.targets(for: .png).first == .png)
        #expect(registry.targets(for: .jpeg).first == .jpeg)
        #expect(registry.targets(for: .png).contains(.pdf))
        #expect(registry.targets(for: .pdf) == [.pdfPages, .pdfImages])
        #expect(registry.targets(for: .wav).first == .alac)
        #expect(registry.targets(for: .quickTimeMovie).first == .mp4)
        #expect(registry.targets(for: .plainText).isEmpty)
    }
}
