import CoreGraphics
import Foundation
import Testing

@Suite("PlatformImage")
struct PlatformImageTests {
    private func makeCGImage(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    /// Su macOS `NSImage(cgImage:size: .zero)` produceva un'immagine 0×0: chiunque leggesse
    /// `.size` (invece dei pixel) otteneva zero. È il percorso del ritaglio pannello → condivisione.
    @Test("from(cgImage:) conserva le dimensioni")
    func preservesSize() throws {
        let cgImage = try makeCGImage(width: 40, height: 25)
        let image = PlatformImage.from(cgImage: cgImage)
        #expect(image.size.width == 40)
        #expect(image.size.height == 25)
    }

    @Test("Round-trip cgImage → PlatformImage → cgImage conserva i pixel")
    func roundTripKeepsPixels() throws {
        let cgImage = try makeCGImage(width: 12, height: 12)
        let restored = try #require(PlatformImage.from(cgImage: cgImage).cgImageRepresentation)
        #expect(restored.width == 12)
        #expect(restored.height == 12)
        let sampled = try #require(PixelProbe.sample(restored, atRelativeX: 0.5, y: 0.5))
        #expect(sampled.isCloseTo(.green))
    }

    @Test("pngData produce dati PNG rileggibili")
    func pngRoundTrip() throws {
        let image = PlatformImage.from(cgImage: try makeCGImage(width: 8, height: 8))
        let data = try #require(image.pngData)
        #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]), "manca la firma PNG")
        #expect(PlatformImage.from(data: data) != nil)
    }

    @Test("from(data:) restituisce nil su dati non-immagine")
    func rejectsGarbage() {
        #expect(PlatformImage.from(data: Data(repeating: 0x41, count: 128)) == nil)
        #expect(PlatformImage.from(data: Data()) == nil)
    }
}
