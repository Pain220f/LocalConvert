import CoreGraphics
import Foundation

/// Removes identifying metadata from JPEG (DCT) image streams embedded in a PDF **in place**.
///
/// PDF APIs offer no way to replace one stream, so this works on the file bytes: inside each
/// embedded JPEG, identifying `APPn` segments (EXIF / XMP in APP1, IPTC in APP13, …) and `COM`
/// segments are turned into zero-filled `COM` segments of the *same length*. Stream lengths and
/// cross-reference offsets therefore stay valid, and the compressed image data is not touched.
/// Segments needed to render correctly are kept: APP0 (JFIF), APP2 (ICC profile), APP14 (Adobe).
///
/// Streams the scan cannot see (encrypted, or wrapped in another filter) are left alone; callers
/// verify the result with `embeddedJPEGsWithMetadata(in:)` and report anything that remains.
enum PDFMetadataScrubber {
    private static let keptMarkers: Set<UInt8> = [0xE0, 0xE2, 0xEE]

    /// Scrubs `data` in place and returns how many segments were neutralised.
    @discardableResult
    static func scrubEmbeddedJPEGs(in data: inout Data) -> Int {
        let keyword = Data("stream".utf8)
        var scrubbed = 0
        var searchStart = data.startIndex
        while let range = data.range(of: keyword, in: searchStart..<data.endIndex) {
            searchStart = range.upperBound
            // `stream` is followed by CRLF or LF, then the stream bytes.
            var cursor = range.upperBound
            if cursor < data.endIndex, data[cursor] == 0x0D { cursor += 1 }
            guard cursor < data.endIndex, data[cursor] == 0x0A else { continue }
            cursor += 1
            guard cursor + 3 < data.endIndex, data[cursor] == 0xFF, data[cursor + 1] == 0xD8, data[cursor + 2] == 0xFF else { continue }
            scrubbed += scrubJPEG(in: &data, startingAt: cursor)
        }
        return scrubbed
    }

    /// Walks the JPEG marker segments from SOI up to SOS (where entropy-coded data begins).
    private static func scrubJPEG(in data: inout Data, startingAt soi: Data.Index) -> Int {
        var count = 0
        var position = soi + 2
        while position + 4 <= data.endIndex {
            guard data[position] == 0xFF else { break }
            let marker = data[position + 1]
            if marker == 0xFF { position += 1; continue }              // fill byte
            if marker == 0xDA || marker == 0xD9 { break }              // SOS / EOI: header is over
            if (0xD0...0xD7).contains(marker) || marker == 0x01 { position += 2; continue } // no length
            let length = Int(data[position + 2]) << 8 | Int(data[position + 3])
            guard length >= 2, position + 2 + length <= data.endIndex else { break }
            let payload = (position + 4)..<(position + 2 + length)
            let isIdentifying = (0xE1...0xEF).contains(marker) && !keptMarkers.contains(marker)
                || (marker == 0xFE && data[payload].contains { $0 != 0 })   // already-blank comments don't count
            if isIdentifying {
                data[position + 1] = 0xFE                               // becomes a COM segment
                data.resetBytes(in: payload)
                count += 1
            }
            position += 2 + length
        }
        return count
    }

    /// Number of embedded JPEG streams that still carry EXIF/XMP/IPTC after scrubbing.
    static func embeddedJPEGsWithMetadata(in url: URL) -> Int {
        guard let document = CGPDFDocument(url as CFURL) else { return 0 }
        var remaining = 0
        for number in 1...max(1, document.numberOfPages) {
            guard let page = document.page(at: number), let resources = pageResources(page) else { continue }
            var xObjects: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(resources, "XObject", &xObjects), let xObjects else { continue }
            CGPDFDictionaryApplyBlock(xObjects, { _, object, _ in
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object, .stream, &stream), let stream else { return true }
                var format = CGPDFDataFormat.raw
                if let data = CGPDFStreamCopyData(stream, &format) as Data?, format == .jpegEncoded, hasIdentifyingSegments(data) {
                    remaining += 1
                }
                return true
            }, nil)
        }
        return remaining
    }

    static func hasIdentifyingSegments(_ jpeg: Data) -> Bool {
        var copy = jpeg
        guard copy.count > 4, copy[copy.startIndex] == 0xFF, copy[copy.startIndex + 1] == 0xD8 else { return false }
        return scrubJPEG(in: &copy, startingAt: copy.startIndex) > 0
    }

    private static func pageResources(_ page: CGPDFPage) -> CGPDFDictionaryRef? {
        var node: CGPDFDictionaryRef? = page.dictionary
        var hops = 0
        while let current = node, hops < 32 {
            var resources: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(current, "Resources", &resources), let resources { return resources }
            var parent: CGPDFDictionaryRef?
            node = CGPDFDictionaryGetDictionary(current, "Parent", &parent) ? parent : nil
            hops += 1
        }
        return nil
    }
}
