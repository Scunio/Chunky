import Foundation
import CoreGraphics
import ImageIO

enum ThumbnailGenerator {
    static let maxDimension: CGFloat = 480

    /// Generates a thumbnail directly from the source bytes (e.g. the JPEG inside the archive),
    /// avoiding an expensive decode + PNG re-encode round trip.
    static func makeThumbnailData(fromSourceData data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgThumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }
        return encode(cgThumbnail)
    }

    static func makeThumbnailData(from image: PlatformImage) -> Data? {
        guard let fullData = image.pngData,
              let source = CGImageSourceCreateWithData(fullData as CFData, nil),
              let cgThumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return image.pngData
        }
        return encode(cgThumbnail)
    }

    private static var thumbnailOptions: [CFString: Any] {
        [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
    }

    private static func encode(_ cgImage: CGImage) -> Data? {
        #if os(iOS) || os(visionOS) || os(tvOS)
        let thumbnail = PlatformImage(cgImage: cgImage)
        #elseif os(macOS)
        let thumbnail = PlatformImage(cgImage: cgImage, size: .zero)
        #endif
        return thumbnail.pngData
    }
}
