import CoreGraphics
import Foundation

/// Legge un singolo pixel da una CGImage. Serve ai test di rendering: verificare "l'immagine
/// non è nil" non distingue una pagina disegnata correttamente da una capovolta o vuota.
enum PixelProbe {
    struct RGB: Equatable, CustomStringConvertible {
        let red: Int
        let green: Int
        let blue: Int

        var description: String { "rgb(\(red), \(green), \(blue))" }

        /// Confronto tollerante: il rendering di un PDF passa per antialiasing e conversioni
        /// di spazio colore, quindi un match esatto sarebbe fragile.
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

    /// `x`/`y` sono frazioni della dimensione (0 = bordo sinistro/alto, 1 = destro/basso),
    /// così il test è indipendente dal fattore di scala usato nel rendering.
    static func sample(_ image: CGImage, atRelativeX x: CGFloat, y: CGFloat) -> RGB? {
        let pixelX = min(image.width - 1, max(0, Int(CGFloat(image.width) * x)))
        let pixelY = min(image.height - 1, max(0, Int(CGFloat(image.height) * y)))

        // Il buffer è allocato esplicitamente e non con `&array`: il CGContext sopravvive
        // alla chiamata `inout`, quindi scriverebbe in memoria che Swift può aver già
        // spostato — ed è esattamente il motivo per cui questa sonda restituiva colori
        // sporchi invece dei valori esatti.
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4)
        buffer.initialize(repeating: 0, count: 4)
        defer { buffer.deallocate() }

        guard let context = CGContext(
            data: buffer,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            // sRGB, non deviceRGB: le immagini sorgente sono in sRGB e una conversione di
            // gamma introdurrebbe scarti che costringerebbero a tolleranze inutilmente larghe.
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Nessuna interpolazione: vogliamo il pixel, non una media dei vicini.
        context.interpolationQuality = .none

        // Trasla l'immagine così che il pixel voluto cada nell'unico pixel del contesto.
        context.draw(image, in: CGRect(x: -CGFloat(pixelX), y: -CGFloat(image.height - 1 - pixelY),
                                       width: CGFloat(image.width), height: CGFloat(image.height)))
        return RGB(red: Int(buffer[0]), green: Int(buffer[1]), blue: Int(buffer[2]))
    }
}
