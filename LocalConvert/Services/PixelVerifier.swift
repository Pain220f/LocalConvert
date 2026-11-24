import CoreGraphics
import Foundation
import ImageIO

/// Decodes two images and compares them sample by sample at 16 bits per channel.
///
/// Both images are rendered into the same color space with the same pipeline, so identical
/// stored pixels always compare equal; any reported difference is real.
enum PixelVerifier {
    /// Upper bound to keep memory bounded (two 16-bit RGBA buffers ≈ 16 bytes/pixel).
    static let maxPixels = 60_000_000

    static func compare(original: URL, converted: URL) -> VerificationResult {
        guard let a = image(at: original) else { return .skipped("could not decode the original") }
        guard let b = image(at: converted) else { return .skipped("could not decode the output") }
        return compare(a, b)
    }

    static func image(at url: URL, index: Int = 0) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > index
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, index, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    static func compare(_ a: CGImage, _ b: CGImage) -> VerificationResult {
        let total = a.width * a.height
        guard a.width == b.width, a.height == b.height else {
            return .differs(maxChannelDelta: 255, differingPixels: total, totalPixels: total)
        }
        guard total <= maxPixels else { return .skipped("image exceeds \(maxPixels / 1_000_000) MP") }

        let space = workingSpace(for: a)
        guard let bufferA = render(a, in: space), let bufferB = render(b, in: space) else {
            return .skipped("could not render pixels for comparison")
        }

        // Fast path: byte-identical buffers.
        let identical = bufferA.withUnsafeBytes { pa in
            bufferB.withUnsafeBytes { pb in memcmp(pa.baseAddress!, pb.baseAddress!, pa.count) == 0 }
        }
        if identical { return .pixelIdentical }

        var maxDelta: UInt16 = 0
        var differing = 0
        bufferA.withUnsafeBufferPointer { pa in
            bufferB.withUnsafeBufferPointer { pb in
                for pixel in 0..<total {
                    let offset = pixel &* 4
                    var pixelDiffers = false
                    for channel in 0..<4 {
                        let x = pa[offset &+ channel], y = pb[offset &+ channel]
                        let d = x > y ? x &- y : y &- x
                        if d > 0 {
                            pixelDiffers = true
                            if d > maxDelta { maxDelta = d }
                        }
                    }
                    if pixelDiffers { differing &+= 1 }
                }
            }
        }
        return .differs(maxChannelDelta: Double(maxDelta) / 257.0, differingPixels: differing, totalPixels: total)
    }

    private static func workingSpace(for image: CGImage) -> CGColorSpace {
        if let space = image.colorSpace, space.model == .rgb, space.supportsOutput {
            return space
        }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }

    private static func render(_ image: CGImage, in space: CGColorSpace) -> [UInt16]? {
        let width = image.width, height = image.height
        var buffer = [UInt16](repeating: 0, count: width * height * 4)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 16,
                bytesPerRow: width * 8,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? buffer : nil
    }
}
