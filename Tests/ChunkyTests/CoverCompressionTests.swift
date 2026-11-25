import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
// Niente `@testable import Chunky`: i test compilano i sorgenti direttamente
// nello stesso modulo (vedi template `ChunkyUnitTest` in project.yml).

/// Le copertine si sincronizzano via CloudKit: devono essere JPEG piccoli, e quelle vecchie in
/// PNG grande vanno ricompresse una volta sola.
struct CoverCompressionTests {
    /// Per-pixel noise, so PNG can't compress it away and stays big like a real scanned cover.
    private func noisyPNG(width: Int, height: Int) throws -> Data {
        var generator = SystemRandomNumberGenerator()
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for index in pixels.indices where index % 4 != 3 {
            pixels[index] = UInt8.random(in: 0...255, using: &generator)
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test("Le nuove copertine sono JPEG entro 480 pixel")
    func newCoversAreSmallJPEG() throws {
        let source = try noisyPNG(width: 1200, height: 1800)
        let cover = try #require(ThumbnailGenerator.makeThumbnailData(fromSourceData: source))
        #expect(!ThumbnailGenerator.isPNG(cover))
        #expect(cover.starts(with: [0xFF, 0xD8]))
        let image = try #require(CGImageSourceCreateWithData(cover as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(max(image.width, image.height) <= Int(ThumbnailGenerator.maxDimension))
    }

    @Test("Un PNG grande viene ricompresso, uno già compatto no")
    func recompressesOnlyLargePNG() throws {
        let bigPNG = try noisyPNG(width: 480, height: 720)
        #expect(bigPNG.count > ThumbnailGenerator.recompressThreshold)
        let compact = try #require(ThumbnailGenerator.compactedCoverData(bigPNG))
        #expect(compact.count < bigPNG.count)
        #expect(!ThumbnailGenerator.isPNG(compact))
        // Già JPEG: nessun secondo giro.
        #expect(ThumbnailGenerator.compactedCoverData(compact) == nil)
    }
}
