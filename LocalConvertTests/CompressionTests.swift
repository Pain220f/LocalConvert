import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import LocalConvert

/// Photo-like fixture: smooth gradients plus deterministic noise, so lossy codecs have real work to do.
enum NoisyFixture {
    static func image(width: Int = 480, height: Int = 360, seed: UInt64 = 42) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        var state = seed
        func next() -> UInt8 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: state >> 56)
        }
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                pixels[offset] = UInt8(clamping: x * 255 / width / 2 + Int(next() / 2))
                pixels[offset + 1] = UInt8(clamping: y * 255 / height / 2 + Int(next() / 2))
                pixels[offset + 2] = UInt8(clamping: (x + y) % 128 + Int(next() / 4))
                pixels[offset + 3] = 255
            }
        }
        return context.makeImage()!
    }

    static func png(in directory: URL, name: String = "photo.png") throws -> URL {
        try Fixtures.write(image(), as: .png, to: directory.appending(path: name))
    }
}

private func compressRequest(_ source: URL, _ type: UTType, _ target: SupportedFormat, limit: Int64?,
                             allowResize: Bool = false, output: URL) -> ConversionRequest {
    ConversionRequest(
        sourceURLs: [source], sourceType: type, target: target,
        options: ConversionOptions(stripMetadata: false, mode: .compressSize,
                                   targetMaxBytes: limit, allowResizeToFitTarget: allowResize),
        outputDirectory: output)
}

/// Runs a conversion that must fail with `cannotMeetTargetSize`, returning the reported numbers.
private func expectCannotMeet(_ engine: some ConversionEngineProtocol, _ request: ConversionRequest)
    async -> (smallest: Int64, target: Int64)? {
    do {
        let output = try await engine.convert(request) { _ in }
        Issue.record("Expected cannotMeetTargetSize, got \(output.byteCount) bytes for a \(request.options.targetMaxBytes ?? -1) byte limit")
        return nil
    } catch let ConversionError.cannotMeetTargetSize(smallest, target, _) {
        return (smallest, target)
    } catch {
        Issue.record("Unexpected error: \(error)")
        return nil
    }
}

private func imageSize(_ url: URL) throws -> (Int, Int) {
    let properties = try #require(CGImageSourceCreateWithURL(url as CFURL, nil)
        .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] })
    return ((properties[kCGImagePropertyPixelWidth] as? Int) ?? 0, (properties[kCGImagePropertyPixelHeight] as? Int) ?? 0)
}

@Suite("Target-size compression", .serialized)
struct CompressionTests {
    let images = ImageConversionEngine()

    @Test("JPEG output is always ≤ the limit, and looser limits keep more quality",
          arguments: [SupportedFormat.jpeg, .heic])
    func imageCapsAreStrictAndMonotonic(format: SupportedFormat) async throws {
        guard images.compressionTargets(for: .png).contains(format) else { return } // HEIC encoder may be absent
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try NoisyFixture.png(in: directory)

        // Discover the smallest achievable size by asking for something impossible.
        let floor = try #require(await expectCannotMeet(images, compressRequest(source, .png, format, limit: 1_000, output: directory)))
        #expect(floor.smallest > 1_000)
        #expect(floor.target == 1_000)

        var previous: ConversionOutput?
        for multiplier in [1.3, 2.5, 6.0] {
            let limit = Int64(Double(floor.smallest) * multiplier)
            let output = try await images.convert(compressRequest(source, .png, format, limit: limit, output: directory)) { _ in }
            #expect(output.byteCount <= limit, "\(output.byteCount) > \(limit)")
            #expect(output.byteCount == (try Fixtures.fileSize(output.url)))
            #expect(output.fidelity == .lossy || output.fidelity == .nearLossless)
            #expect(try imageSize(output.url) == (480, 360), "no downscaling unless allowed")
            if let previous {
                #expect(output.byteCount >= previous.byteCount, "a looser limit must not lower quality")
            }
            previous = output
        }
    }

    @Test("An impossible limit fails cleanly and leaves no file behind")
    func impossibleLimitFails() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try NoisyFixture.png(in: directory)

        let result = try #require(await expectCannotMeet(images, compressRequest(source, .png, .jpeg, limit: 2_000, output: directory)))
        #expect(result.smallest > 2_000)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files == ["photo.png"], "no output may be written: \(files)")
    }

    @Test("With downscaling allowed, the image shrinks until it fits strictly under the limit")
    func downscaleFallback() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try NoisyFixture.png(in: directory)
        let floor = try #require(await expectCannotMeet(images, compressRequest(source, .png, .jpeg, limit: 1_000, output: directory)))
        let limit = floor.smallest / 3

        let output = try await images.convert(
            compressRequest(source, .png, .jpeg, limit: limit, allowResize: true, output: directory)) { _ in }

        #expect(output.byteCount <= limit)
        #expect(output.byteCount == (try Fixtures.fileSize(output.url)))
        #expect(output.fidelity == .lossy)
        let (width, height) = try imageSize(output.url)
        #expect(width < 480 && height < 360)
        #expect(abs(Double(width) / Double(height) - 480.0 / 360.0) < 0.05, "aspect ratio preserved")
        #expect(output.notes.contains { $0.contains("Downscaled") })
    }

    @Test("PNG never turns lossy to meet a limit; it refuses, or downscales only when allowed")
    func losslessRefusal() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try NoisyFixture.png(in: directory)
        let lossless = try await images.convert(compressRequest(source, .png, .png, limit: nil, output: directory)) { _ in }
        #expect(lossless.fidelity == .lossless)
        #expect(lossless.verification == .pixelIdentical)
        let limit = lossless.byteCount / 2

        let refusal = try #require(await expectCannotMeet(images, compressRequest(source, .png, .png, limit: limit, output: directory)))
        #expect(refusal.smallest == lossless.byteCount)

        let resized = try await images.convert(
            compressRequest(source, .png, .png, limit: limit, allowResize: true, output: directory)) { _ in }
        #expect(resized.byteCount <= limit)
        #expect(resized.url.pathExtension == "png")
        let (width, _) = try imageSize(resized.url)
        #expect(width < 480)
    }

    @Test("A limit above the lossless size is met losslessly")
    func generousLimitStaysLossless() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try NoisyFixture.png(in: directory)
        let output = try await images.convert(compressRequest(source, .png, .png, limit: 50_000_000, output: directory)) { _ in }
        #expect(output.fidelity == .lossless)
        #expect(output.verification == .pixelIdentical)
    }

    @Test("AAC is sized under the limit; lossless ALAC refuses when it can't fit")
    func audioLimits() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "clip.mov")
        try await VideoFixtures.makeMovie(at: source)
        let media = MediaConversionEngine()
        let limit: Int64 = 16_000 // 1 s of audio → ~120 kbit/s budget

        let aac = try await media.convert(compressRequest(source, .quickTimeMovie, .aac, limit: limit, output: directory)) { _ in }
        #expect(aac.byteCount <= limit)
        #expect(aac.fidelity == .lossy)
        #expect(try await VideoFixtures.codec(of: aac.url, .audio) == "aac ")

        let refusal = try #require(await expectCannotMeet(media, compressRequest(source, .quickTimeMovie, .alac, limit: 5_000, output: directory)))
        #expect(refusal.smallest > 5_000)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".m4a") }
        #expect(leftovers.count == 1, "only the successful AAC output may exist: \(leftovers)")
    }

    @Test("HEVC compression hits a byte budget")
    func videoLimit() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "clip.mov")
        try await VideoFixtures.makeMovie(at: source)
        let sourceSize = try Fixtures.fileSize(source)
        let limit = sourceSize / 3

        let output = try await MediaConversionEngine().convert(
            compressRequest(source, .quickTimeMovie, .hevcMOV, limit: limit, output: directory)) { _ in }

        #expect(output.byteCount <= limit, "\(output.byteCount) > \(limit)")
        #expect(try await VideoFixtures.codec(of: output.url, .video) == "hvc1")
        #expect(try await VideoFixtures.dimensions(of: output.url) == CGSize(width: VideoFixtures.width, height: VideoFixtures.height))
    }

    @Test("PDF compression fits a limit (rasterizing only when allowed) and refuses otherwise")
    func pdfLimits() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pages = try (0..<2).map { try Fixtures.write(NoisyFixture.image(seed: UInt64($0 + 1)), as: .png,
                                                        to: directory.appending(path: "page\($0).png")) }
        let pdfEngine = PDFConversionEngine()
        let pdf = try await pdfEngine.convert(ConversionRequest(
            sourceURLs: pages, sourceType: .png, target: .pdf, options: .init(), outputDirectory: directory)) { _ in }
        let limit = pdf.byteCount / 4

        let rasterized = try await pdfEngine.convert(
            compressRequest(pdf.url, .pdf, .pdfCompressed, limit: limit, allowResize: true, output: directory)) { _ in }
        #expect(rasterized.byteCount <= limit)
        #expect(CGPDFDocument(rasterized.url as CFURL)?.numberOfPages == 2)

        let refusal = try #require(await expectCannotMeet(pdfEngine,
            compressRequest(pdf.url, .pdf, .pdfCompressed, limit: 3_000, allowResize: false, output: directory)))
        #expect(refusal.smallest > 3_000)
    }

    @Test("Images compile into a size-limited PDF")
    func imagesToCompressedPDF() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try NoisyFixture.png(in: directory)
        let limit: Int64 = 60_000
        let output = try await PDFConversionEngine().convert(
            compressRequest(source, .png, .pdfCompressed, limit: limit, allowResize: true, output: directory)) { _ in }
        #expect(output.byteCount <= limit)
        #expect(output.fidelity == .lossy)
    }
}

@MainActor
@Suite("Job modes")
struct JobModeTests {
    private func makeJob() -> ConversionJob {
        ConversionJob(sourceURLs: [URL(filePath: "/tmp/photo.png")], sourceType: .png, category: .image,
                      originalBytes: 481_000, availableTargets: [.png, .tiff, .jpeg],
                      compressionTargets: [.heic, .jpeg, .png])
    }

    private func finishedOutput() -> ConversionOutput {
        ConversionOutput(url: URL(filePath: "/tmp/out.png"), isDirectory: false, byteCount: 1, fileCount: 1,
                         fidelity: .lossless, verification: .pixelIdentical, notes: [], engineName: "test", elapsed: .zero)
    }

    @Test func switchingModesSwapsTargetsAndResetsResult() {
        let job = makeJob()
        #expect(job.mode == .convertFormat)
        #expect(job.target == .png)
        #expect(job.targetMaxBytes == nil)

        job.finish(with: finishedOutput())
        job.setMode(.compressSize)
        #expect(job.status == .pending)
        #expect(job.output == nil)
        #expect(job.availableTargets == [.heic, .jpeg, .png])
        #expect(job.target == .heic)
        #expect(job.plannedFidelity == .lossy)

        job.setTarget(.jpeg)
        job.setMode(.convertFormat)
        #expect(job.target == .png, "each mode remembers its own target")
        job.setMode(.compressSize)
        #expect(job.target == .jpeg)
    }

    @Test func sizeLimitOnlyAppliesInCompressMode() {
        let job = makeJob()
        job.setTargetMaxBytes(200_000)
        #expect(job.targetMaxBytes == nil, "convert mode never enforces a limit")
        job.setMode(.compressSize)
        #expect(job.targetMaxBytes == 200_000)
        #expect(job.options(stripMetadata: true) == ConversionOptions(
            stripMetadata: true, mode: .compressSize, targetMaxBytes: 200_000, allowResizeToFitTarget: false))

        job.finish(with: finishedOutput())
        job.setAllowResizeToFitTarget(true)
        #expect(job.status == .pending && job.output == nil)

        job.finish(with: finishedOutput())
        job.setTargetMaxBytes(nil)
        #expect(job.targetMaxBytes == nil)
        #expect(job.output == nil)
        job.setTargetMaxBytes(job.targetSizeBytes)
        #expect(job.targetMaxBytes == 200_000, "the value survives switching the limit off and on")
        job.setTargetMaxBytes(10)
        #expect(job.targetMaxBytes == 1_000, "limits are clamped to at least 1 KB")
    }

    @Test func jobsWithoutCompressionStayInConvertMode() {
        let job = ConversionJob(sourceURLs: [URL(filePath: "/tmp/a.pdf")], sourceType: .pdf, category: .document,
                                originalBytes: 10, availableTargets: [.pdfPages])
        job.setMode(.compressSize)
        #expect(job.mode == .convertFormat)
    }

    @Test func busyJobsIgnoreEdits() {
        let job = makeJob()
        job.status = .converting(0.5)
        job.setMode(.compressSize)
        job.setTarget(.jpeg)
        #expect(job.mode == .convertFormat && job.target == .png)
    }

    @Test func presetsNeverExceedTheOriginal() {
        let presets = SizePreset.presets(for: 481_000)
        #expect(presets.map(\.bytes).allSatisfy { $0 < 481_000 })
        #expect(presets.contains { $0.label == "50%" && $0.bytes == 240_500 })
        #expect(presets.contains { $0.bytes == 250_000 })
        #expect(ConversionJob.suggestedLimit(for: 481_000) == 240_000)
    }
}
