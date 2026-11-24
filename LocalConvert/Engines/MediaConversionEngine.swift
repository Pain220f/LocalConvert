import AVFoundation
import CoreMedia
import Foundation
import UniformTypeIdentifiers
import VideoToolbox

/// AVFoundation / VideoToolbox audio & video conversion.
///
/// - **MOV ⇄ MP4 / M4A**: `AVAssetExportPresetPassthrough` remux — compressed samples are copied as-is.
/// - **ALAC / WAV**: `AVAssetReader` decodes to PCM at the source's native bit depth and
///   `AVAssetWriter` re-encodes losslessly. Nothing below the source's resolution is discarded.
/// - **HEVC**: optional VideoToolbox (hardware where available) re-encode, clearly flagged as lossy.
struct MediaConversionEngine: ConversionEngineProtocol {
    let identifier = "avfoundation"
    let displayName = "AVFoundation"

    private static let losslessAudioTypes: [UTType] = [
        .wav, .aiff, UTType("public.aifc-audio"), UTType("org.xiph.flac"), UTType("com.apple.coreaudio-format"),
    ].compactMap { $0 }

    func supportedTargets(for sourceType: UTType) -> [SupportedFormat] {
        if sourceType.conforms(to: .movie) {
            let remux: [SupportedFormat] = sourceType.conforms(to: .quickTimeMovie) ? [.mp4, .mov] : [.mov, .mp4]
            return remux + [.hevcMOV, .m4a, .alac, .wav]
        }
        if sourceType.conforms(to: .audio) {
            let isLossless = Self.losslessAudioTypes.contains { sourceType.conforms(to: $0) }
            return isLossless ? [.alac, .wav, .m4a] : [.m4a, .alac, .wav]
        }
        return []
    }

    func compressionTargets(for sourceType: UTType) -> [SupportedFormat] {
        if sourceType.conforms(to: .movie) { return [.hevcMOV, .aac] }
        if sourceType.conforms(to: .audio) { return [.aac, .alac] }
        return []
    }

    func convert(_ request: ConversionRequest, progress: @escaping ProgressHandler) async throws -> ConversionOutput {
        let start = ContinuousClock.now
        guard let pathExtension = request.target.fileExtension else {
            throw ConversionError.unsupportedConversion(from: request.sourceType, to: request.target)
        }
        let asset = AVURLAsset(url: request.sourceURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard try await asset.load(.isReadable) else { throw ConversionError.unreadableSource(request.sourceURL) }

        let outputURL = FileStorageService.uniqueURL(in: request.outputDirectory, baseName: request.baseName, pathExtension: pathExtension)
        let strip = request.options.stripMetadata
        var notes: [String] = []
        let fidelity: Fidelity

        do {
            switch request.target {
            case .mov, .mp4:
                try await export(strip ? try await Self.metadataFreeComposition(of: asset) : asset, preset: AVAssetExportPresetPassthrough,
                                 fileType: request.target == .mov ? .mov : .mp4,
                                 to: outputURL, strip: strip, progress: progress)
                fidelity = .bitExact
                notes.append("Remuxed: audio/video bitstreams copied without re-encoding.")
            case .m4a:
                let composition = try await audioOnlyComposition(of: asset)
                try await export(composition, preset: AVAssetExportPresetPassthrough, fileType: .m4a,
                                 to: outputURL, strip: strip,
                                 metadata: strip ? [] : try await asset.load(.metadata), progress: progress)
                fidelity = .bitExact
                notes.append("Audio bitstream copied into an M4A container without re-encoding.")
            case .hevcMOV where request.options.mode == .compressSize && request.options.targetMaxBytes != nil:
                notes += try await compressVideo(asset, source: request.sourceURL, to: outputURL,
                                                 limit: request.options.targetMaxBytes!, strip: strip, progress: progress)
                fidelity = .lossy
            case .aac:
                notes += try await encodeAAC(asset, source: request.sourceURL, to: outputURL,
                                             limit: request.options.targetMaxBytes, strip: strip, progress: progress)
                fidelity = .lossy
            case .hevcMOV:
                try await export(strip ? try await Self.metadataFreeComposition(of: asset) : asset, preset: AVAssetExportPresetHEVCHighestQuality, fileType: .mov,
                                 to: outputURL, strip: strip, progress: progress)
                fidelity = .lossy
                notes.append("Video re-encoded with the VideoToolbox \(Self.hasHardwareHEVCEncoder ? "hardware" : "software") HEVC encoder at highest quality. This is lossy.")
            case .alac, .wav:
                notes += try await transcodeAudioLosslessly(
                    asset, source: request.sourceURL, target: request.target, to: outputURL, strip: strip, progress: progress)
                fidelity = .lossless
            default:
                throw ConversionError.unsupportedConversion(from: request.sourceType, to: request.target)
            }
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
        if strip { notes.append("All container and track metadata (incl. location) and timed-metadata tracks removed.") }
        if let limit = request.options.targetMaxBytes {
            let size = try FileStorageService.byteCount(at: outputURL)
            guard size <= limit else {
                try? FileManager.default.removeItem(at: outputURL)
                throw ConversionError.cannotMeetTargetSize(
                    smallestAchievable: size, target: limit,
                    suggestion: request.target.isLossyCapable
                        ? "Raise the limit."
                        : "\(request.target.shortName) is lossless. Choose AAC (M4A) to compress further.")
            }
            notes.append("\(ByteCount.exact(size)) — within the \(ByteCount.exact(limit)) limit.")
        }
        progress(1)
        return try OutputBuilder.make(url: outputURL, fidelity: fidelity, notes: notes, engineName: displayName, startedAt: start)
    }

    // MARK: - Export session (remux / HEVC)

    func export(
        _ asset: AVAsset,
        preset: String,
        fileType: AVFileType,
        to url: URL,
        strip: Bool,
        metadata: [AVMetadataItem]? = nil,
        progress: @escaping ProgressHandler
    ) async throws {
        guard await AVAssetExportSession.compatibility(ofExportPreset: preset, with: asset, outputFileType: fileType) else {
            throw ConversionError.incompatibleContainer(
                "The source's codecs can't be stored in \(fileType == .mp4 ? "MP4" : fileType == .m4a ? "M4A" : "MOV") without re-encoding. Try MOV, ALAC or WAV instead."
            )
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ConversionError.encoderUnavailable(preset)
        }
        session.shouldOptimizeForNetworkUse = false
        if strip {
            session.metadata = []
            session.metadataItemFilter = .forSharing()
        } else if let metadata {
            session.metadata = metadata
        }
        // `states(updateInterval:)` is documented as safe to observe from any task.
        let observed = UncheckedSendableBox(session)
        let monitor = Task {
            for await state in observed.value.states(updateInterval: 0.2) {
                if case let .exporting(exportProgress) = state { progress(exportProgress.fractionCompleted) }
            }
        }
        defer { monitor.cancel() }
        try await session.export(to: url, as: fileType)
    }

    private func audioOnlyComposition(of asset: AVAsset) async throws -> AVMutableComposition {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw ConversionError.noAudioTrack }
        let composition = AVMutableComposition()
        for track in tracks {
            let range = try await track.load(.timeRange)
            guard let compositionTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try compositionTrack.insertTimeRange(range, of: track, at: range.start)
        }
        return composition
    }

    // MARK: - Lossless PCM path (ALAC / WAV)

    private struct PCMShape {
        var bits: Int
        var isFloat: Bool
        var sourceWasLossy: Bool
    }

    /// Native sample resolution of the source so decoding never truncates precision.
    private static func pcmShape(for asbd: AudioStreamBasicDescription) -> PCMShape {
        switch asbd.mFormatID {
        case kAudioFormatLinearPCM:
            let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
            let bits = Int(asbd.mBitsPerChannel)
            return PCMShape(bits: isFloat ? max(bits, 32) : (bits <= 16 ? 16 : (bits <= 24 ? 24 : 32)), isFloat: isFloat, sourceWasLossy: false)
        case kAudioFormatAppleLossless, kAudioFormatFLAC:
            // kAppleLosslessFormatFlag_*BitSourceData / kFLACFormatFlag_*BitSourceData: 1=16, 2=20, 3=24, 4=32.
            let bits = [1: 16, 2: 24, 3: 24, 4: 32][Int(asbd.mFormatFlags)] ?? 24
            return PCMShape(bits: bits, isFloat: false, sourceWasLossy: false)
        default:
            // Lossy codecs decode to float; keep full float precision.
            return PCMShape(bits: 32, isFloat: true, sourceWasLossy: true)
        }
    }

    private func transcodeAudioLosslessly(
        _ asset: AVAsset, source: URL, target: SupportedFormat, to url: URL, strip: Bool, progress: @escaping ProgressHandler
    ) async throws -> [String] {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw ConversionError.noAudioTrack }
        let formatDescriptions = try await track.load(.formatDescriptions)
        guard let description = formatDescriptions.first,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
        else { throw ConversionError.unreadableSource(source) }
        // Header values are untrusted: a NaN/huge sample rate or channel count must not reach Int().
        guard asbd.mSampleRate.isFinite, (1_000...768_000).contains(asbd.mSampleRate),
              (1...64).contains(asbd.mChannelsPerFrame)
        else { throw ConversionError.inputTooLarge("unsupported audio format (\(asbd.mSampleRate) Hz, \(asbd.mChannelsPerFrame) ch).") }
        let duration = try await asset.load(.duration).seconds

        var notes: [String] = []
        var shape = Self.pcmShape(for: asbd)
        if target == .alac, shape.isFloat {
            // ALAC stores integers only; 24-bit keeps ~144 dB of dynamic range.
            shape = PCMShape(bits: 24, isFloat: false, sourceWasLossy: shape.sourceWasLossy)
            notes.append("Floating-point audio stored as 24-bit integer (ALAC has no float mode).")
        }
        if shape.sourceWasLossy {
            notes.append("Source is lossy; output is a lossless copy of the decoded audio (no additional loss, but typically larger).")
        }

        let channels = Int(asbd.mChannelsPerFrame)
        var layoutData: Data?
        var layoutSize = 0
        if let layout = CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: &layoutSize), layoutSize > 0 {
            layoutData = Data(bytes: layout, count: layoutSize)
        } else if channels > 2 {
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)
            layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        }

        let readerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: shape.bits,
            AVLinearPCMIsFloatKey: shape.isFloat,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        var writerSettings: [String: Any] = [
            AVSampleRateKey: asbd.mSampleRate,
            AVNumberOfChannelsKey: channels,
        ]
        if let layoutData { writerSettings[AVChannelLayoutKey] = layoutData }
        if target == .wav {
            writerSettings[AVFormatIDKey] = kAudioFormatLinearPCM
            writerSettings[AVLinearPCMBitDepthKey] = shape.bits
            writerSettings[AVLinearPCMIsFloatKey] = shape.isFloat
            writerSettings[AVLinearPCMIsBigEndianKey] = false
            writerSettings[AVLinearPCMIsNonInterleaved] = false
        } else {
            writerSettings[AVFormatIDKey] = kAudioFormatAppleLossless
            writerSettings[AVEncoderBitDepthHintKey] = shape.bits
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: readerSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ConversionError.engineFailure("The audio track cannot be decoded.") }
        reader.add(output)

        let writer = try AVAssetWriter(outputURL: url, fileType: target == .wav ? .wav : .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: writerSettings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw ConversionError.encoderUnavailable(target.displayName) }
        writer.add(input)

        // AVAssetWriter starts with no metadata, so tags must be carried over explicitly.
        if !strip {
            let tags = try await Self.portableMetadata(from: asset)
            if target == .alac {
                writer.metadata = tags
                if !tags.isEmpty { notes.append("\(tags.count) metadata tag(s) carried over.") }
            } else if !tags.isEmpty {
                notes.append("WAV cannot hold the source's \(tags.count) metadata tag(s); choose ALAC to keep them.")
            }
        }

        guard reader.startReading() else { throw reader.error ?? ConversionError.unreadableSource(source) }
        guard writer.startWriting() else { throw writer.error ?? ConversionError.writeFailed(target.displayName) }
        writer.startSession(atSourceTime: .zero)

        var endTime = CMTime.zero
        do {
            while true {
                try Task.checkCancellation()
                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(for: .milliseconds(2))
                }
                guard let buffer = output.copyNextSampleBuffer() else { break }
                guard input.append(buffer) else {
                    throw writer.error ?? ConversionError.writeFailed("append failed")
                }
                let bufferEnd = CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(buffer), CMSampleBufferGetDuration(buffer))
                if bufferEnd.isValid, bufferEnd > endTime { endTime = bufferEnd }
                if duration > 0 {
                    progress(CMSampleBufferGetPresentationTimeStamp(buffer).seconds / duration)
                }
            }
            if reader.status == .failed { throw reader.error ?? ConversionError.unreadableSource(source) }
            input.markAsFinished()
            // An explicit end time makes the writer flush the final partial codec packet.
            if endTime > .zero { writer.endSession(atSourceTime: endTime) }
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? ConversionError.writeFailed(target.displayName) }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }

        let depth = shape.isFloat ? "32-bit float" : "\(shape.bits)-bit"
        notes.insert("Decoded and re-encoded losslessly at \(depth), \(Int(asbd.mSampleRate)) Hz, \(channels) ch.", at: 0)
        return notes
    }

    /// Used only to observe export progress from a sibling task.
    private struct UncheckedSendableBox<Value>: @unchecked Sendable {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    /// The source's media tracks in a fresh composition: asset-level tags, track-level tags and
    /// timed-metadata tracks (which can hold per-frame GPS) are all left behind. Samples are
    /// referenced, not copied, so a passthrough export stays bit-exact.
    static func metadataFreeComposition(of asset: AVAsset) async throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        for track in try await asset.load(.tracks) where track.mediaType != .metadata {
            let range = try await track.load(.timeRange)
            guard let copy = composition.addMutableTrack(withMediaType: track.mediaType,
                                                         preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try copy.insertTimeRange(range, of: track, at: range.start)
            copy.preferredTransform = try await track.load(.preferredTransform)
        }
        return composition
    }

    /// Re-expresses the source's tags (iTunes, QuickTime, ID3, …) through their common keys so the
    /// writer can map them into the output container.
    static func portableMetadata(from asset: AVAsset) async throws -> [AVMetadataItem] {
        var result: [AVMetadataItem] = []
        var seen = Set<String>()
        for item in try await asset.load(.metadata) {
            guard let key = item.commonKey, !seen.contains(key.rawValue),
                  let value = try await item.load(.value) else { continue }
            let copy = AVMutableMetadataItem()
            copy.identifier = AVMetadataItem.identifier(forKey: key.rawValue, keySpace: .common)
            copy.value = value
            copy.dataType = item.dataType
            copy.extendedLanguageTag = item.extendedLanguageTag
            result.append(copy)
            seen.insert(key.rawValue)
        }
        return result
    }

    // MARK: - VideoToolbox

    static var hasHardwareHEVCEncoder: Bool {
        var list: CFArray?
        guard VTCopyVideoEncoderList(nil, &list) == noErr, let encoders = list as? [[String: Any]] else { return false }
        return encoders.contains { encoder in
            (encoder[kVTVideoEncoderList_CodecType as String] as? NSNumber)?.uint32Value == kCMVideoCodecType_HEVC
                && (encoder[kVTVideoEncoderList_IsHardwareAccelerated as String] as? Bool) == true
        }
    }
}
