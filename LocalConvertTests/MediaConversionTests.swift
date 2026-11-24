import AVFoundation
import Foundation
import Testing
@testable import LocalConvert

@Suite("Media conversion")
struct MediaConversionTests {
    let engine = MediaConversionEngine()

    /// 0.5 s of deterministic 16-bit stereo noise + tone (incompressible enough to catch any loss).
    private func writeWAV(to url: URL) throws -> [Int16] {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44_100, channels: 2, interleaved: true))
        let frames: AVAudioFrameCount = 22_050
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        var generator = SystemRandomNumberGenerator()
        var samples: [Int16] = []
        let data = try #require(buffer.int16ChannelData)[0]
        for index in 0..<Int(frames) * 2 {
            let tone = sin(Double(index / 2) * 2 * .pi * 440 / 44_100) * 12_000
            let sample = Int16(clamping: Int(tone) + Int.random(in: -2_000...2_000, using: &generator))
            data[index] = sample
            samples.append(sample)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        try file.write(from: buffer)
        return samples
    }

    private func readSamples(_ url: URL) throws -> [Int16] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        let channels = Int(file.processingFormat.channelCount)
        var samples: [Int16] = []
        // A single read may return fewer frames than requested; loop until the end of the file.
        while file.framePosition < file.length {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8_192))
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            let data = try #require(buffer.int16ChannelData)[0]
            samples += UnsafeBufferPointer(start: data, count: Int(buffer.frameLength) * channels)
        }
        return samples
    }

    @Test("WAV → ALAC → WAV preserves every sample and ALAC is smaller")
    func alacRoundTrip() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "tone.wav")
        let original = try writeWAV(to: source)

        let alac = try await engine.convert(Fixtures.request(source, .wav, .alac, output: directory)) { _ in }
        #expect(alac.fidelity == .lossless)
        #expect(alac.byteCount == (try Fixtures.fileSize(alac.url)))
        #expect(alac.byteCount < (try Fixtures.fileSize(source)))

        let back = try await engine.convert(Fixtures.request(alac.url, .mpeg4Audio, .wav, output: directory)) { _ in }
        let sourceFrames = try AVAudioFile(forReading: source).length
        let alacFrames = try AVAudioFile(forReading: alac.url).length
        let backFrames = try AVAudioFile(forReading: back.url).length
        #expect(sourceFrames == 22_050)
        #expect(alacFrames == sourceFrames)
        #expect(backFrames == sourceFrames)
        let decoded = try readSamples(back.url)
        let firstMismatch = zip(decoded, original).enumerated().first { $0.element.0 != $0.element.1 }
        #expect(decoded.count == original.count, "sample count \(decoded.count) vs \(original.count)")
        #expect(firstMismatch == nil, "first mismatch at \(firstMismatch?.offset ?? -1): \(String(describing: firstMismatch?.element))")
    }
}
