import AVFoundation
import CoreMedia
import Foundation

/// Compress Size mode for audio and video: bitrate is derived from the byte budget, the result is
/// measured, and one tightened pass runs if container overhead pushed it over. The limit is never
/// exceeded silently: the engine either fits or throws `cannotMeetTargetSize`.
extension MediaConversionEngine {
    /// Lowest video bitrate worth producing; below this the picture is unusable.
    static let minimumVideoBitrate = 50_000.0

    // MARK: - Video → HEVC at a target size

    func compressVideo(_ asset: AVAsset, source: URL, to url: URL, limit: Int64, strip: Bool,
                       progress: @escaping ProgressHandler) async throws -> [String] {
        let duration = try await asset.load(.duration).seconds
        guard duration > 0, let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ConversionError.unreadableSource(source)
        }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let sourceVideoRate = Double(try await videoTrack.load(.estimatedDataRate))

        // 8% of the budget is reserved for container overhead.
        let budgetBitsPerSecond = Double(limit) * 8 * 0.92 / duration
        let audioBitrate = audioTrack == nil ? 0 : (budgetBitsPerSecond > 1_000_000 ? 128_000 : 64_000)
        var videoBitrate = budgetBitsPerSecond - Double(audioBitrate)
        if sourceVideoRate > 0 { videoBitrate = min(videoBitrate, max(sourceVideoRate, 500_000)) }

        func tooSmall(_ achieved: Int64?) -> ConversionError {
            let estimate = Int64((Self.minimumVideoBitrate + Double(audioBitrate)) * duration / 8 / 0.92)
            return .cannotMeetTargetSize(smallestAchievable: achieved ?? estimate, target: limit,
                                         suggestion: "A \(Int(duration.rounded()))-second video needs a higher limit, or trim it first.")
        }
        guard videoBitrate >= Self.minimumVideoBitrate else { throw tooSmall(nil) }

        var lastSize: Int64?
        for pass in 1...2 {
            try await transcodeToHEVC(asset, videoTrack: videoTrack, audioTrack: audioTrack, source: source, to: url,
                                      videoBitrate: Int(videoBitrate), audioBitrate: audioBitrate, strip: strip,
                                      duration: duration, progress: progress)
            let size = try FileStorageService.byteCount(at: url)
            if size <= limit {
                return [String(format: "HEVC at %.0f kbit/s%@ (pass %d), sized for the limit.",
                               videoBitrate / 1000, audioBitrate > 0 ? " + AAC \(audioBitrate / 1000) kbit/s" : "", pass)]
            }
            lastSize = size
            try? FileManager.default.removeItem(at: url)
            videoBitrate *= Double(limit) / Double(size) * 0.9
            guard videoBitrate >= Self.minimumVideoBitrate else { break }
        }
        throw tooSmall(lastSize)
    }

    private func transcodeToHEVC(_ asset: AVAsset, videoTrack: AVAssetTrack, audioTrack: AVAssetTrack?, source: URL,
                                 to url: URL, videoBitrate: Int, audioBitrate: Int, strip: Bool,
                                 duration: Double, progress: @escaping ProgressHandler) async throws {
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let frameRate = try await videoTrack.load(.nominalFrameRate)

        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var compression: [String: Any] = [AVVideoAverageBitRateKey: videoBitrate]
        if frameRate > 0 { compression[AVVideoExpectedSourceFrameRateKey] = frameRate }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(naturalSize.width.rounded()),
            AVVideoHeightKey: Int(naturalSize.height.rounded()),
            AVVideoCompressionPropertiesKey: compression,
        ])
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = transform
        guard writer.canAdd(videoInput) else { throw ConversionError.encoderUnavailable("HEVC") }
        writer.add(videoInput)

        var audio: (output: AVAssetReaderTrackOutput, input: AVAssetWriterInput)?
        if let audioTrack, audioBitrate > 0 {
            let format = try await Self.aacFormat(for: audioTrack, bitrate: audioBitrate)
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: format.reader)
            output.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: format.writer)
            input.expectsMediaDataInRealTime = false
            if reader.canAdd(output), writer.canAdd(input) {
                reader.add(output)
                writer.add(input)
                audio = (output, input)
            }
        }
        if !strip { writer.metadata = try await asset.load(.metadata) }

        try await Self.pump(reader: reader, writer: writer,
                            streams: [(videoOutput, videoInput)] + (audio.map { [($0.output, $0.input)] } ?? []),
                            source: source, duration: duration, progress: progress)
    }

    // MARK: - Audio → AAC (optionally at a target size)

    func encodeAAC(_ asset: AVAsset, source: URL, to url: URL, limit: Int64?, strip: Bool,
                   progress: @escaping ProgressHandler) async throws -> [String] {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw ConversionError.noAudioTrack }
        let duration = try await asset.load(.duration).seconds
        guard duration > 0 else { throw ConversionError.unreadableSource(source) }
        let channels = min(2, try await Self.channelCount(of: track))
        let range = channels == 1 ? 32_000...192_000 : 64_000...320_000

        var bitrate = limit.map { Int(Double($0) * 8 * 0.94 / duration) } ?? (channels == 1 ? 128_000 : 256_000)
        bitrate = min(max(bitrate, range.lowerBound), range.upperBound)
        let tags = strip ? [] : try await Self.portableMetadata(from: asset)

        var lastSize: Int64 = 0
        for pass in 1...3 {
            let format = try await Self.aacFormat(for: track, bitrate: bitrate)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: format.reader)
            output.alwaysCopiesSampleData = false
            reader.add(output)
            let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: format.writer)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw ConversionError.encoderUnavailable("AAC") }
            writer.add(input)
            writer.metadata = tags
            try await Self.pump(reader: reader, writer: writer, streams: [(output, input)],
                                source: source, duration: duration, progress: progress)

            let note = "AAC at \(bitrate / 1000) kbit/s, \(channels == 1 ? "mono" : "stereo") (pass \(pass))."
            guard let limit else { return [note] }
            lastSize = try FileStorageService.byteCount(at: url)
            if lastSize <= limit { return [note] }
            try? FileManager.default.removeItem(at: url)
            guard bitrate > range.lowerBound else { break }
            bitrate = max(range.lowerBound, Int(Double(bitrate) * Double(limit) / Double(lastSize) * 0.95))
        }
        throw ConversionError.cannotMeetTargetSize(
            smallestAchievable: lastSize, target: limit ?? 0,
            suggestion: "Even \(range.lowerBound / 1000) kbit/s AAC is too large for \(Int(duration.rounded())) seconds. Raise the limit.")
    }

    // MARK: - Shared plumbing

    private static func channelCount(of track: AVAssetTrack) async throws -> Int {
        guard let description = try await track.load(.formatDescriptions).first,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
        else { return 2 }
        return max(1, Int(asbd.mChannelsPerFrame))
    }

    /// Reader settings that decode (and down-mix to ≤ 2 channels) to PCM, plus AAC writer settings.
    static func aacFormat(for track: AVAssetTrack, bitrate: Int) async throws -> (reader: [String: Any], writer: [String: Any]) {
        guard let description = try await track.load(.formatDescriptions).first,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
        else { throw ConversionError.noAudioTrack }
        let channels = min(2, max(1, Int(asbd.mChannelsPerFrame)))
        let sampleRate = min(asbd.mSampleRate > 0 ? asbd.mSampleRate : 44_100, 48_000)
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        let layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        let reader: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVChannelLayoutKey: layoutData,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let writer: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVChannelLayoutKey: layoutData,
            AVEncoderBitRateKey: bitrate,
        ]
        return (reader, writer)
    }

    /// Moves samples from reader outputs to writer inputs, interleaving streams by polling so that
    /// no input starves the writer. Honours cancellation and cleans up on failure.
    static func pump(reader: AVAssetReader, writer: AVAssetWriter,
                     streams: [(AVAssetReaderTrackOutput, AVAssetWriterInput)],
                     source: URL, duration: Double, progress: ProgressHandler) async throws {
        guard reader.startReading() else { throw reader.error ?? ConversionError.unreadableSource(source) }
        guard writer.startWriting() else { throw writer.error ?? ConversionError.writeFailed("could not start writing") }
        writer.startSession(atSourceTime: .zero)

        var finished = Array(repeating: false, count: streams.count)
        var endTime = CMTime.zero
        do {
            while finished.contains(false) {
                try Task.checkCancellation()
                var didWork = false
                for (index, stream) in streams.enumerated() where !finished[index] && stream.1.isReadyForMoreMediaData {
                    didWork = true
                    guard let buffer = stream.0.copyNextSampleBuffer() else {
                        stream.1.markAsFinished()
                        finished[index] = true
                        continue
                    }
                    guard stream.1.append(buffer) else {
                        throw writer.error ?? ConversionError.writeFailed("append failed")
                    }
                    let time = CMSampleBufferGetPresentationTimeStamp(buffer)
                    let bufferEnd = CMTimeAdd(time, CMSampleBufferGetDuration(buffer))
                    if bufferEnd.isValid, bufferEnd > endTime { endTime = bufferEnd }
                    if index == 0, duration > 0 { progress(min(0.98, time.seconds / duration)) }
                }
                if !didWork { try await Task.sleep(for: .milliseconds(1)) }
            }
            if reader.status == .failed { throw reader.error ?? ConversionError.unreadableSource(source) }
            if endTime > .zero { writer.endSession(atSourceTime: endTime) }
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? ConversionError.writeFailed("could not finish writing") }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }
    }
}
