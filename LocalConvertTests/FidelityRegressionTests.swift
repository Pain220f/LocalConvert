import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import LocalConvert

/// Regression tests for metadata-privacy and fidelity-reporting bugs found in review.
@Suite("Fidelity & privacy regressions")
struct FidelityRegressionTests {
    private static var gpsProperties: [CFString: Any] { [
        kCGImageDestinationLossyCompressionQuality: 0.85,
        kCGImagePropertyGPSDictionary: [
            kCGImagePropertyGPSLatitude: 37.3349, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 122.0090, kCGImagePropertyGPSLongitudeRef: "W",
        ],
    ] }

    private func hasGPS(_ url: URL) throws -> Bool {
        let properties = try #require(CGImageSourceCreateWithURL(url as CFURL, nil)
            .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] })
        return properties[kCGImagePropertyGPSDictionary] != nil
    }

    private func extractedJPEG(from pdf: URL, strip: Bool, in directory: URL) async throws -> URL {
        let output = try await PDFConversionEngine().convert(
            Fixtures.request(pdf, .pdf, .pdfImages, strip: strip, output: directory)) { _ in }
        let files = try FileManager.default.contentsOfDirectory(at: output.url, includingPropertiesForKeys: nil)
        return try #require(files.first { $0.pathExtension == "jpg" })
    }

    // MARK: Default targets

    @Test("HEIC defaults to a bit-exact HEIC rewrite; plain HEIF and AVIF default to lossless PNG")
    func heifDefaults() {
        let registry = EngineRegistry.standard
        #expect(registry.targets(for: .heic).first == .heic)
        #expect(registry.targets(for: .heif).first == .png)
        if let avif = UTType("public.avif"), ImageConversionEngine.canRead(avif) {
            #expect(registry.targets(for: avif).first == .png)
        }
        for type in [UTType.png, .jpeg, .tiff, .heic, .heif, .gif, .bmp, .pdf, .wav, .quickTimeMovie, .mpeg4Movie] {
            if let first = registry.targets(for: type).first {
                #expect(first.fidelity(from: type).isLossless, "default for \(type.identifier) must be lossless")
            }
        }
    }

    // MARK: PDF metadata

    @Test("Images → PDF embeds JPEG GPS data unless stripping, which keeps the DCT data intact")
    func pdfCompileStripsEmbeddedJPEGMetadata() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let jpeg = try Fixtures.write(Fixtures.gradientImage(), as: .jpeg, to: directory.appending(path: "gps.jpg"),
                                      properties: Self.gpsProperties)
        #expect(try hasGPS(jpeg))
        let engine = PDFConversionEngine()

        let kept = try await engine.convert(Fixtures.request(jpeg, .jpeg, .pdf, output: directory)) { _ in }
        #expect(try hasGPS(try await extractedJPEG(from: kept.url, strip: false, in: directory)))

        let stripped = try await engine.convert(Fixtures.request(jpeg, .jpeg, .pdf, strip: true, output: directory)) { _ in }
        #expect(stripped.fidelity == .bitExact)
        let image = try await extractedJPEG(from: stripped.url, strip: false, in: directory)
        #expect(try !hasGPS(image))
        #expect(PixelVerifier.compare(original: jpeg, converted: image) == .pixelIdentical)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!leftovers.contains { $0.hasPrefix(".scratch-") })
    }

    @Test("Extracting images with stripping removes GPS from verbatim JPEG streams")
    func pdfExtractStripsMetadata() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let jpeg = try Fixtures.write(Fixtures.gradientImage(), as: .jpeg, to: directory.appending(path: "gps.jpg"),
                                      properties: Self.gpsProperties)
        let pdf = try await PDFConversionEngine().convert(Fixtures.request(jpeg, .jpeg, .pdf, output: directory)) { _ in }

        let image = try await extractedJPEG(from: pdf.url, strip: true, in: directory)
        #expect(try !hasGPS(image))
        #expect(PixelVerifier.compare(original: jpeg, converted: image) == .pixelIdentical)
    }

    // MARK: Orientation

    @Test("Formats without an orientation flag get the rotation applied to pixels, verified as displayed")
    func orientationIsBakedIntoBMP() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // 96×64 sensor image tagged "rotate 90° CW to display" → displays as 64×96.
        let source = try Fixtures.write(Fixtures.gradientImage(width: 96, height: 64), as: .png,
                                        to: directory.appending(path: "rotated.png"),
                                        properties: [kCGImagePropertyOrientation: 6])

        let output = try await ImageConversionEngine().convert(Fixtures.request(source, .png, .bmp, output: directory)) { _ in }

        let properties = try #require(CGImageSourceCreateWithURL(output.url as CFURL, nil)
            .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] })
        #expect((properties[kCGImagePropertyPixelWidth] as? Int) == 64)
        #expect((properties[kCGImagePropertyPixelHeight] as? Int) == 96)
        #expect(output.verification == .pixelIdentical)
    }

    @Test("Verifier compares images as displayed: a dropped orientation flag is reported")
    func verifierSeesOrientation() throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = Fixtures.gradientImage(width: 40, height: 40)
        let tagged = try Fixtures.write(image, as: .png, to: directory.appending(path: "tagged.png"),
                                        properties: [kCGImagePropertyOrientation: 3])
        let untagged = try Fixtures.write(image, as: .png, to: directory.appending(path: "plain.png"))
        if case .differs = PixelVerifier.compare(original: tagged, converted: untagged) {} else {
            Issue.record("Same pixels with a different orientation must not verify as identical")
        }
    }

    @Test("PDF pages honour JPEG orientation (page box is rotated)")
    func pdfPageOrientation() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let jpeg = try Fixtures.write(Fixtures.gradientImage(width: 96, height: 64), as: .jpeg,
                                      to: directory.appending(path: "portrait.jpg"),
                                      properties: [kCGImagePropertyOrientation: 6])
        let pdf = try await PDFConversionEngine().convert(Fixtures.request(jpeg, .jpeg, .pdf, output: directory)) { _ in }
        let box = try #require(CGPDFDocument(pdf.url as CFURL)?.page(at: 1)).getBoxRect(.mediaBox)
        #expect(box.width == 64 && box.height == 96)
    }

    // MARK: Animated images

    private func writeAnimatedGIF(to url: URL, frames: Int) throws {
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames, nil))
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let colors: [(UInt8, UInt8, UInt8)] = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0)]
        for index in 0..<frames {
            let context = try #require(CGContext(data: nil, width: 24, height: 24, bitsPerComponent: 8, bytesPerRow: 96,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            let (r, g, b) = colors[index % colors.count]
            context.setFillColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: index * 4, y: 4, width: 8, height: 8))
            CGImageDestinationAddImage(destination, try #require(context.makeImage()),
                                       [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test("Every frame of an animation is verified; single-frame targets report the dropped frames")
    func animatedFrames() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gif = directory.appending(path: "anim.gif")
        try writeAnimatedGIF(to: gif, frames: 3)
        let engine = ImageConversionEngine()

        let png = try await engine.convert(Fixtures.request(gif, .gif, .png, output: directory)) { _ in }
        #expect(png.verification == .identicalFrames(compared: 1, sourceFrames: 3))

        let tiff = try await engine.convert(Fixtures.request(gif, .gif, .tiff, output: directory)) { _ in }
        #expect(tiff.verification == .pixelIdentical)
        #expect(CGImageSourceCreateWithURL(tiff.url as CFURL, nil).map(CGImageSourceGetCount) == 3)
    }
}
