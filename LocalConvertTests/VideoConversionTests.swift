import AVFoundation
import CoreVideo
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import LocalConvert

/// Deterministic synthetic movies: 1 s of 320×240 H.264 at 30 fps plus 1 s of stereo AAC,
/// optionally tagged with a title and an ISO 6709 location.
enum VideoFixtures {
    static let width = 320
    static let height = 240
    static let title = "LocalConvert Fixture"
    static let location = "+37.3349-122.0090/"

    static func makeMovie(at url: URL, withMetadata: Bool = true, includeAudio: Bool = true) async throws {
        let directory = url.deletingLastPathComponent()
        let videoURL = directory.appending(path: "video-\(UUID().uuidString).mov")
        let audioURL = directory.appending(path: "audio-\(UUID().uuidString).m4a")
        defer {
            try? FileManager.default.removeItem(at: videoURL)
            try? FileManager.default.removeItem(at: audioURL)
        }
        try await writeH264(to: videoURL)
        try writeAAC(to: audioURL)

        let video = AVURLAsset(url: videoURL)
        let audio = AVURLAsset(url: audioURL)
        let videoTrack = try #require(try await video.loadTracks(withMediaType: .video).first)
        let audioTrack = try #require(try await audio.loadTracks(withMediaType: .audio).first)
        let videoRange = try await videoTrack.load(.timeRange)
        let audioRange = try await audioTrack.load(.timeRange)

        let composition = AVMutableComposition()
        let compositionVideo = try #require(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        try compositionVideo.insertTimeRange(videoRange, of: videoTrack, at: .zero)
        if includeAudio {
            let compositionAudio = try #require(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
            try compositionAudio.insertTimeRange(
                CMTimeRange(start: .zero, duration: CMTimeMinimum(audioRange.duration, videoRange.duration)),
                of: audioTrack, at: .zero)
        }

        let session = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        if withMetadata {
            let titleItem = AVMutableMetadataItem()
            titleItem.identifier = .commonIdentifierTitle
            titleItem.value = title as NSString
            let locationItem = AVMutableMetadataItem()
            locationItem.identifier = .quickTimeMetadataLocationISO6709
            locationItem.value = location as NSString
            session.metadata = [titleItem, locationItem]
        }
        try await session.export(to: url, as: .mov)
    }

    private static func writeH264(to url: URL, frames: Int = 30) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            let buffer = try makeFrame(index: frame)
            #expect(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: 30))
        await writer.finishWriting()
        #expect(writer.status == .completed, "\(String(describing: writer.error))")
    }

    private static func makeFrame(index: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        let pixelBuffer = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let base = try #require(CVPixelBufferGetBaseAddress(pixelBuffer)).assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = base + y * rowBytes + x * 4
                pixel[0] = UInt8((x + index * 8) & 0xFF)
                pixel[1] = UInt8((y + index * 4) & 0xFF)
                pixel[2] = UInt8((x ^ y) & 0xFF)
                pixel[3] = 255
            }
        }
        return pixelBuffer
    }

    private static func writeAAC(to url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100))
        buffer.frameLength = 44_100
        let channels = try #require(buffer.floatChannelData)
        for frame in 0..<Int(buffer.frameLength) {
            let sample = Float(sin(Double(frame) * 2 * .pi * 440 / 44_100) * 0.4)
            channels[0][frame] = sample
            channels[1][frame] = sample
        }
        try file.write(from: buffer)
    }

    // MARK: Inspection helpers

    static func codec(of url: URL, _ type: AVMediaType) async throws -> String? {
        guard let track = try await AVURLAsset(url: url).loadTracks(withMediaType: type).first,
              let description = try await track.load(.formatDescriptions).first
        else { return nil }
        let code = CMFormatDescriptionGetMediaSubType(description)
        return String(decoding: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, as: UTF8.self)
    }

    static func dimensions(of url: URL) async throws -> CGSize? {
        guard let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first else { return nil }
        return try await track.load(.naturalSize)
    }

    static func metadataIdentifiers(of url: URL) async throws -> Set<String> {
        let asset = AVURLAsset(url: url)
        var identifiers = Set<String>()
        for item in try await asset.load(.metadata) {
            if let identifier = item.identifier { identifiers.insert(identifier.rawValue) }
            if let key = item.commonKey { identifiers.insert("common/" + key.rawValue) }
        }
        return identifiers
    }

    static func title(of url: URL) async throws -> String? {
        let items = AVMetadataItem.metadataItems(from: try await AVURLAsset(url: url).load(.commonMetadata),
                                                 filteredByIdentifier: .commonIdentifierTitle)
        guard let item = items.first else { return nil }
        return try await item.load(.stringValue)
    }
}

@Suite("Video & audio container conversion", .serialized)
struct VideoConversionTests {
    let engine = MediaConversionEngine()

    @Test("MOV → MP4 remux keeps codecs, dimensions and duration")
    func remuxToMP4() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "clip.mov")
        try await VideoFixtures.makeMovie(at: source)

        let output = try await engine.convert(Fixtures.request(source, .quickTimeMovie, .mp4, output: directory)) { _ in }

        #expect(output.fidelity == .bitExact)
        #expect(output.url.pathExtension == "mp4")
        #expect(output.byteCount == (try Fixtures.fileSize(output.url)))
        #expect(try await VideoFixtures.codec(of: output.url, .video) == "avc1")
        #expect(try await VideoFixtures.codec(of: output.url, .audio) == "aac ")
        #expect(try await VideoFixtures.dimensions(of: output.url) == CGSize(width: VideoFixtures.width, height: VideoFixtures.height))
        let before = try await AVURLAsset(url: source).load(.duration).seconds
        let after = try await AVURLAsset(url: output.url).load(.duration).seconds
        #expect(abs(before - after) < 0.05)
    }

    @Test("Remux preserves metadata by default and strips title and location on request")
    func remuxMetadata() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "tagged.mov")
        try await VideoFixtures.makeMovie(at: source)
        let sourceIDs = try await VideoFixtures.metadataIdentifiers(of: source)
        #expect(sourceIDs.contains(AVMetadataIdentifier.quickTimeMetadataLocationISO6709.rawValue), "fixture must carry a location")

        let kept = try await engine.convert(Fixtures.request(source, .quickTimeMovie, .mov, output: directory)) { _ in }
        #expect(try await VideoFixtures.metadataIdentifiers(of: kept.url).contains(AVMetadataIdentifier.quickTimeMetadataLocationISO6709.rawValue))
        #expect(try await VideoFixtures.title(of: kept.url) == VideoFixtures.title)

        let stripped = try await engine.convert(Fixtures.request(source, .quickTimeMovie, .mov, strip: true, output: directory)) { _ in }
        let strippedIDs = try await VideoFixtures.metadataIdentifiers(of: stripped.url)
        #expect(!strippedIDs.contains(AVMetadataIdentifier.quickTimeMetadataLocationISO6709.rawValue))
        #expect(!strippedIDs.contains("common/location"))
        #expect(try await VideoFixtures.title(of: stripped.url) == nil)
    }

    @Test("M4A extraction copies the AAC bitstream and drops video")
    func audioPassthrough() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "clip.mov")
        try await VideoFixtures.makeMovie(at: source)

        let output = try await engine.convert(Fixtures.request(source, .quickTimeMovie, .m4a, output: directory)) { _ in }

        #expect(output.fidelity == .bitExact)
        #expect(try await VideoFixtures.codec(of: output.url, .audio) == "aac ")
        #expect(try await VideoFixtures.codec(of: output.url, .video) == nil)
        #expect(output.byteCount < (try Fixtures.fileSize(source)))
    }

    @Test("HEVC re-encode produces hvc1 at the same size and is flagged lossy")
    func hevcReencode() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "clip.mov")
        try await VideoFixtures.makeMovie(at: source)

        let output = try await engine.convert(Fixtures.request(source, .quickTimeMovie, .hevcMOV, output: directory)) { _ in }

        #expect(output.fidelity == .lossy)
        #expect(try await VideoFixtures.codec(of: output.url, .video) == "hvc1")
        #expect(try await VideoFixtures.dimensions(of: output.url) == CGSize(width: VideoFixtures.width, height: VideoFixtures.height))
    }

    @Test("ALAC keeps the source's tags unless stripping is requested")
    func alacMetadata() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "tagged.mov")
        try await VideoFixtures.makeMovie(at: source)

        let kept = try await engine.convert(Fixtures.request(source, .quickTimeMovie, .alac, output: directory)) { _ in }
        #expect(try await VideoFixtures.codec(of: kept.url, .audio) == "alac")
        #expect(try await VideoFixtures.title(of: kept.url) == VideoFixtures.title)

        let stripped = try await engine.convert(Fixtures.request(source, .quickTimeMovie, .alac, strip: true, output: directory)) { _ in }
        #expect(try await VideoFixtures.title(of: stripped.url) == nil)
        // iTunSMPB is written by the encoder itself (gapless priming/padding), not copied from the source.
        let remaining = try await VideoFixtures.metadataIdentifiers(of: stripped.url)
            .subtracting(["itlk/com.apple.iTunes.iTunSMPB"])
        #expect(remaining.isEmpty, "remaining identifiers: \(remaining.sorted())")
    }

    @Test("Asking for audio from a video-only file fails with a clear error and no output")
    func errorNamesSource() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let noAudio = directory.appending(path: "silent.mov")
        try await VideoFixtures.makeMovie(at: noAudio, includeAudio: false)

        await #expect(throws: ConversionError.self) {
            _ = try await engine.convert(Fixtures.request(noAudio, .quickTimeMovie, .wav, output: directory)) { _ in }
        }
        do {
            _ = try await engine.convert(Fixtures.request(noAudio, .quickTimeMovie, .wav, output: directory)) { _ in }
        } catch {
            #expect(error.localizedDescription == ConversionError.noAudioTrack.localizedDescription)
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".wav") }
        #expect(leftovers.isEmpty)
    }
}
