import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import QuickLookThumbnailing

struct MetadataDiffRow: Identifiable, Hashable, Sendable {
    enum Change: Sendable { case same, changed, added, removed }
    let key: String
    let before: String?
    let after: String?
    var id: String { key }

    var change: Change {
        switch (before, after) {
        case (nil, _): .added
        case (_, nil): .removed
        case let (b?, a?): b == a ? .same : .changed
        }
    }
}

/// Reads technical metadata as flat `key → value` pairs so source and output can be diffed.
enum MetadataInspector {
    static func diff(before: [String: String], after: [String: String]) -> [MetadataDiffRow] {
        Set(before.keys).union(after.keys).sorted().map {
            MetadataDiffRow(key: $0, before: before[$0], after: after[$0])
        }
    }

    static func inspect(_ url: URL) async -> [String: String] {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey])
        if values?.isDirectory == true { return inspectDirectory(url) }
        var result: [String: String] = [:]
        if let bytes = try? FileStorageService.byteCount(at: url) {
            result["File · Size"] = ByteCount.exact(bytes)
        }
        guard let type = values?.contentType else { return result }
        result["File · Type"] = type.localizedDescription ?? type.identifier

        if type.conforms(to: .pdf) {
            result.merge(inspectPDF(url)) { $1 }
        } else if type.conforms(to: .image) {
            result.merge(inspectImage(url)) { $1 }
        } else if type.conforms(to: .audiovisualContent) {
            result.merge(await inspectMedia(url)) { $1 }
        }
        return result
    }

    private static func inspectDirectory(_ url: URL) -> [String: String] {
        [
            "Folder · Files": String(FileStorageService.fileCount(at: url)),
            "Folder · Total size": ByteCount.exact((try? FileStorageService.byteCount(at: url)) ?? 0),
        ]
    }

    private static func inspectImage(_ url: URL) -> [String: String] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [:] }
        var result: [String: String] = ["Image · Frames": String(CGImageSourceGetCount(source))]
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
            flatten(properties, prefix: "Image", into: &result)
        }
        return result
    }

    private static func flatten(_ dictionary: [String: Any], prefix: String, into result: inout [String: String], depth: Int = 0) {
        for (key, value) in dictionary {
            let name = key.hasPrefix("{") ? key.trimmingCharacters(in: CharacterSet(charactersIn: "{}")) : key
            let path = "\(prefix) · \(name)"
            if let nested = value as? [String: Any], depth < 3 {
                flatten(nested, prefix: path, into: &result, depth: depth + 1)
            } else if let array = value as? [Any] {
                result[path] = array.prefix(12).map { "\($0)" }.joined(separator: ", ")
            } else if let data = value as? Data {
                result[path] = "\(data.count) bytes"
            } else {
                result[path] = "\(value)"
            }
        }
    }

    private static func inspectPDF(_ url: URL) -> [String: String] {
        guard let document = CGPDFDocument(url as CFURL) else { return [:] }
        var major: Int32 = 0, minor: Int32 = 0
        document.getVersion(majorVersion: &major, minorVersion: &minor)
        var result: [String: String] = [
            "PDF · Pages": String(document.numberOfPages),
            "PDF · Version": "\(major).\(minor)",
            "PDF · Encrypted": document.isEncrypted ? "Yes" : "No",
        ]
        if let info = document.info {
            for key in ["Title", "Author", "Subject", "Creator", "Producer"] {
                var string: CGPDFStringRef?
                if CGPDFDictionaryGetString(info, key, &string), let string,
                   let value = CGPDFStringCopyTextString(string) as String? {
                    result["PDF · \(key)"] = value
                }
            }
        }
        if let page = document.page(at: 1) {
            let box = page.getBoxRect(.mediaBox)
            result["PDF · Page 1 size"] = String(format: "%.1f × %.1f pt", box.width, box.height)
        }
        return result
    }

    private static func inspectMedia(_ url: URL) async -> [String: String] {
        let asset = AVURLAsset(url: url)
        var result: [String: String] = [:]
        if let duration = try? await asset.load(.duration) {
            result["Media · Duration"] = String(format: "%.3f s", duration.seconds)
        }
        if let metadata = try? await asset.load(.metadata) {
            result["Media · Metadata items"] = String(metadata.count)
        }
        guard let tracks = try? await asset.load(.tracks) else { return result }
        for (index, track) in tracks.enumerated() {
            let prefix = "Track \(index + 1) (\(track.mediaType.rawValue))"
            if let descriptions = try? await track.load(.formatDescriptions), let description = descriptions.first {
                result["\(prefix) · Codec"] = fourCC(CMFormatDescriptionGetMediaSubType(description))
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                    result["\(prefix) · Sample rate"] = "\(Int(asbd.mSampleRate)) Hz"
                    result["\(prefix) · Channels"] = String(asbd.mChannelsPerFrame)
                    if asbd.mBitsPerChannel > 0 { result["\(prefix) · Bits per channel"] = String(asbd.mBitsPerChannel) }
                }
                if track.mediaType == .video {
                    let size = CMVideoFormatDescriptionGetDimensions(description)
                    result["\(prefix) · Dimensions"] = "\(size.width) × \(size.height)"
                }
            }
            if let rate = try? await track.load(.estimatedDataRate), rate > 0 {
                result["\(prefix) · Data rate"] = String(format: "%.0f kbit/s", rate / 1000)
            }
            if track.mediaType == .video, let fps = try? await track.load(.nominalFrameRate), fps > 0 {
                result["\(prefix) · Frame rate"] = String(format: "%.3f fps", fps)
            }
        }
        return result
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        let printable = bytes.allSatisfy { $0 >= 32 && $0 < 127 }
        return printable ? String(decoding: bytes, as: UTF8.self) : String(code)
    }
}

/// Loads display images for the comparison view. Everything returns `CGImage` (Sendable) so the
/// work can run off the main actor.
enum PreviewLoader {
    /// Full-resolution-ish raster preview with EXIF orientation applied.
    static func image(at url: URL, maxPixelSize: Int = 4096) async -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary)
    }

    /// Quick Look thumbnail for anything (PDF, video, audio). Rendered locally by the system.
    static func thumbnail(for url: URL, side: CGFloat = 900) async -> CGImage? {
        var target = url
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let first = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil))?
                .sorted { $0.lastPathComponent < $1.lastPathComponent }.first
            guard let first else { return nil }
            target = first
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: target, size: CGSize(width: side, height: side), scale: 2, representationTypes: .thumbnail)
        let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        return representation?.cgImage
    }

    /// CoreImage absolute difference, amplified ×8 so tiny deviations become visible. Black = identical.
    static func difference(_ a: CGImage, _ b: CGImage) async -> CGImage? {
        let before = CIImage(cgImage: a)
        let after = CIImage(cgImage: b)
        let diff = after.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: before])
        let amplified = diff.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 8, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 8, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 8, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
        return CIContext(options: [.cacheIntermediates: false]).createCGImage(amplified, from: before.extent)
    }
}
