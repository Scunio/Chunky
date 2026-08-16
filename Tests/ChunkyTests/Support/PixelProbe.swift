import CoreGraphics
import Foundation

/// Reads a single pixel from a CGImage. Used by rendering tests: verifying "the image isn't
/// nil" doesn't distinguish a correctly drawn page from a flipped or blank one.
enum PixelProbe {
    struct RGB: Equatable, CustomStringConvertible {
        let red: Int
        let green: Int
        let blue: Int

        var description: String { "rgb(\(red), \(green), \(blue))" }

        /// Tolerant comparison: rendering a PDF goes through antialiasing and color space
        /// conversions, so an exact match would be fragile.
        func isCloseTo(_ other: RGB, tolerance: Int = 24) -> Bool {
            abs(red - other.red) <= tolerance
                && abs(green - other.green) <= tolerance
                && abs(blue - other.blue) <= tolerance
        }

        static let white = RGB(red: 255, green: 255, blue: 255)
        static let red = RGB(red: 255, green: 0, blue: 0)
        static let green = RGB(red: 0, green: 255, blue: 0)
        static let blue = RGB(red: 0, green: 0, blue: 255)
    }

    /// `x`/`y` are fractions of the dimension (0 = left/top edge, 1 = right/bottom), so the
    /// test is independent of the scale factor used in rendering.
    static func sample(_ image: CGImage, atRelativeX x: CGFloat, y: CGFloat) -> RGB? {
        let pixelX = min(image.width - 1, max(0, Int(CGFloat(image.width) * x)))
        let pixelY = min(image.height - 1, max(0, Int(CGFloat(image.height) * y)))

        // The buffer is allocated explicitly rather than with `&array`: the CGContext
        // outlives the `inout` call, so it would write into memory Swift may have already
        // moved — which is exactly why this probe used to return garbled colors instead of
        // the exact values.
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4)
        buffer.initialize(repeating: 0, count: 4)
        defer { buffer.deallocate() }

        guard let context = CGContext(
            data: buffer,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            // sRGB, not deviceRGB: the source images are in sRGB and a gamma conversion
            // would introduce discrepancies that would force unnecessarily wide tolerances.
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // No interpolation: we want the pixel, not an average of its neighbors.
        context.interpolationQuality = .none

        // Translate the image so the desired pixel falls onto the context's single pixel.
        context.draw(image, in: CGRect(x: -CGFloat(pixelX), y: -CGFloat(image.height - 1 - pixelY),
                                       width: CGFloat(image.width), height: CGFloat(image.height)))
        return RGB(red: Int(buffer[0]), green: Int(buffer[1]), blue: Int(buffer[2]))
    }
}
