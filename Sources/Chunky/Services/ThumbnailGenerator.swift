import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

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

    /// JPEG quality for covers: a 480-pixel cover lands around 30-60 KB instead of the ~400 KB
    /// of PNG. Covers sync through CloudKit (Core Data mirrors `coverImageDataInline`), so the
    /// size is paid in every user's iCloud storage and on every device's first sync.
    static let jpegQuality: CGFloat = 0.75

    /// Covers bigger than this that are still PNG get re-encoded once (see `compactedCoverData`).
    static let recompressThreshold = 120_000

    private static func encode(_ cgImage: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// A smaller replacement for a cover saved by earlier versions as a large PNG, or nil when it's
    /// already compact (so the pass that calls this settles after one run). Downsampled to
    /// `maxDimension` and encoded as JPEG, like new covers.
    static func compactedCoverData(_ data: Data) -> Data? {
        guard data.count > recompressThreshold, isPNG(data) else { return nil }
        guard let compact = makeThumbnailData(fromSourceData: data), compact.count < data.count else { return nil }
        return compact
    }

    static func isPNG(_ data: Data) -> Bool {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47])
    }
}
