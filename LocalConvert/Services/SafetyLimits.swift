import CoreGraphics
import Foundation
import ImageIO

/// Hard ceilings applied to untrusted input **before** anything is decoded or allocated.
///
/// Every input file is attacker-controllable (downloaded images, PDFs, media). These limits turn
/// decompression bombs and absurd header values into clean errors instead of OOM kills or
/// arithmetic traps. Up to four jobs run at once, so per-job ceilings are kept well below RAM size.
enum SafetyLimits {
    /// Largest raster image decoded in full (≈ 600 MB as 8-bit RGBA).
    static let maxImagePixels = 150_000_000
    /// Largest single image side accepted.
    static let maxImageSide = 65_535
    /// Rasterized PDF pages are rendered no larger than this per side / in total.
    static let maxRasterSide = 8_192
    static let maxRasterPixels = 64_000_000
    /// Upper bound on pages rasterized in memory for Compress Size.
    static let maxRasterizedPages = 500
    /// Largest decoded (inflated) raw image stream pulled out of a PDF.
    static let maxPDFStreamBytes = 512 * 1024 * 1024
    /// Media must be at least this long for bitrate math to be meaningful.
    static let minimumMediaDuration = 0.05
    /// Largest video frame dimension accepted for re-encoding.
    static let maxVideoSide = 16_384
    /// Largest byte limit a user can enter (1 PB); keeps Double → Int64 conversions safe.
    static let maxTargetBytes: Int64 = 1_000_000_000_000_000

    /// Validates frame `index`'s declared dimensions without decoding pixels.
    static func checkImage(_ source: CGImageSource, at index: Int, url: URL) throws {
        let properties = (CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]) ?? [:]
        guard let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else { throw ConversionError.unreadableSource(url) }
        try checkDimensions(width: width, height: height, what: "Image")
    }

    /// Non-throwing variant for best-effort paths (previews, verification).
    static func isDecodable(_ source: CGImageSource, at index: Int) -> Bool {
        (try? checkImage(source, at: index, url: URL(filePath: "/"))) != nil
    }

    static func checkDimensions(width: Int, height: Int, what: String) throws {
        guard width > 0, height > 0 else { throw ConversionError.inputTooLarge("\(what) has invalid dimensions (\(width)×\(height)).") }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, width <= maxImageSide, height <= maxImageSide, pixels <= maxImagePixels else {
            throw ConversionError.inputTooLarge(
                "\(what) is \(width)×\(height) px; the limit is \(maxImagePixels / 1_000_000) megapixels.")
        }
    }

    /// `value` as an `Int` if it is finite and inside `range`, otherwise `nil`. Never traps.
    static func int(_ value: Double, in range: ClosedRange<Int>) -> Int? {
        guard value.isFinite, value >= Double(range.lowerBound), value <= Double(range.upperBound) else { return nil }
        return Int(value)
    }

    /// Clamps a finite value into `range` before converting; non-finite values give `nil`.
    static func clampedInt(_ value: Double, to range: ClosedRange<Int>) -> Int? {
        guard value.isFinite else { return nil }
        return Int(min(max(value, Double(range.lowerBound)), Double(range.upperBound)))
    }

    static func validDuration(_ seconds: Double) -> Bool {
        seconds.isFinite && seconds >= minimumMediaDuration
    }
}
