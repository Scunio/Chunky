import CoreImage
import CoreImage.CIFilterBuiltins

/// Filtri opzionali applicati alle pagine prima di mostrarle: ritaglio automatico dei bordi
/// bianchi (comune negli scan) e upscaling di qualità per le pagine a bassa risoluzione.
enum ImageProcessing {
    private static let context = CIContext()

    /// Rileva e rimuove bordi uniformemente chiari (bianco/quasi bianco) attorno alla pagina.
    static func autoCropWhiteBorders(_ image: PlatformImage) -> PlatformImage {
        guard let cgImage = image.cgImageRepresentation else { return image }
        let ciImage = CIImage(cgImage: cgImage)
        let extent = ciImage.extent
        guard extent.width > 4, extent.height > 4,
              let cropRect = detectContentRect(in: ciImage, extent: extent),
              cropRect != extent, cropRect.width > 4, cropRect.height > 4 else {
            return image
        }
        guard let cropped = context.createCGImage(ciImage, from: cropRect) else { return image }
        return PlatformImage.from(cgImage: cropped)
    }

    /// Applica un upscaling Lanczos (qualità migliore del semplice ridimensionamento a schermo)
    /// quando la pagina è più piccola della dimensione target.
    static func upscaleIfNeeded(_ image: PlatformImage, targetSize: CGSize) -> PlatformImage {
        guard let cgImage = image.cgImageRepresentation else { return image }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        guard width > 0, height > 0 else { return image }

        let scale = max(targetSize.width / width, targetSize.height / height)
        guard scale > 1.15 else { return image }
        let cappedScale = min(scale, 3.0)

        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = CIImage(cgImage: cgImage)
        filter.scale = Float(cappedScale)
        filter.aspectRatio = 1

        guard let output = filter.outputImage,
              let result = context.createCGImage(output, from: output.extent) else {
            return image
        }
        return PlatformImage.from(cgImage: result)
    }

    /// Corregge automaticamente contrasto e saturazione di una pagina scansionata (spesso
    /// piatta/sbiadita), senza richiedere una tinta manuale come il "tint pagina" impostabile
    /// dall'utente.
    static func autoTintAndContrast(_ image: PlatformImage) -> PlatformImage {
        guard let cgImage = image.cgImageRepresentation else { return image }
        let filter = CIFilter.colorControls()
        filter.inputImage = CIImage(cgImage: cgImage)
        filter.contrast = 1.12
        filter.saturation = 1.08
        filter.brightness = 0.0
        guard let output = filter.outputImage,
              let result = context.createCGImage(output, from: output.extent) else {
            return image
        }
        return PlatformImage.from(cgImage: result)
    }

    /// Ritaglia l'immagine al rettangolo indicato, espresso in coordinate pixel (origine in alto
    /// a sinistra, come nello spazio di visualizzazione). Usato per condividere solo una vignetta.
    static func crop(_ image: PlatformImage, to rectTopLeftOrigin: CGRect) -> PlatformImage? {
        guard let cgImage = image.cgImageRepresentation else { return nil }
        let height = CGFloat(cgImage.height)
        // CGImage.cropping usa coordinate con origine in basso a sinistra: convertiamo la Y.
        let flippedRect = CGRect(
            x: rectTopLeftOrigin.minX,
            y: height - rectTopLeftOrigin.maxY,
            width: rectTopLeftOrigin.width,
            height: rectTopLeftOrigin.height
        )
        let bounds = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        let clamped = flippedRect.intersection(bounds)
        guard clamped.width > 1, clamped.height > 1, let cropped = cgImage.cropping(to: clamped) else { return nil }
        return PlatformImage.from(cgImage: cropped)
    }

    /// Individua il rettangolo di contenuto scandendo dai quattro bordi verso il centro,
    /// fermandosi alla prima riga/colonna che non è quasi-bianca in modo uniforme.
    private static func detectContentRect(in image: CIImage, extent: CGRect) -> CGRect? {
        guard let cgImage = context.createCGImage(image, from: extent) else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0,
              let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return nil }

        let bytesPerRow = cgImage.bytesPerRow
        let bytesPerPixel = max(cgImage.bitsPerPixel / 8, 1)
        let whiteThreshold: UInt8 = 245
        let maxNonWhiteFraction = 0.02

        func luminance(x: Int, y: Int) -> UInt8 {
            let offset = y * bytesPerRow + x * bytesPerPixel
            guard offset + 2 < CFDataGetLength(data) else { return 255 }
            let r = bytes[offset]
            let g = bytes[offset + 1]
            let b = bytes[offset + 2]
            return UInt8((Int(r) + Int(g) + Int(b)) / 3)
        }

        func rowIsMostlyWhite(_ y: Int) -> Bool {
            var nonWhite = 0
            let step = max(width / 200, 1)
            var sampled = 0
            for x in stride(from: 0, to: width, by: step) {
                sampled += 1
                if luminance(x: x, y: y) < whiteThreshold { nonWhite += 1 }
            }
            return Double(nonWhite) / Double(max(sampled, 1)) < maxNonWhiteFraction
        }

        func columnIsMostlyWhite(_ x: Int) -> Bool {
            var nonWhite = 0
            let step = max(height / 200, 1)
            var sampled = 0
            for y in stride(from: 0, to: height, by: step) {
                sampled += 1
                if luminance(x: x, y: y) < whiteThreshold { nonWhite += 1 }
            }
            return Double(nonWhite) / Double(max(sampled, 1)) < maxNonWhiteFraction
        }

        var top = 0
        while top < height / 4, rowIsMostlyWhite(top) { top += 1 }
        var bottom = height - 1
        while bottom > height - height / 4, bottom > top, rowIsMostlyWhite(bottom) { bottom -= 1 }
        var left = 0
        while left < width / 4, columnIsMostlyWhite(left) { left += 1 }
        var right = width - 1
        while right > width - width / 4, right > left, columnIsMostlyWhite(right) { right -= 1 }

        guard top > 0 || bottom < height - 1 || left > 0 || right < width - 1 else { return nil }
        guard right > left, bottom > top else { return nil }

        // Le coordinate CoreImage hanno l'origine in basso a sinistra: convertiamo la Y.
        let ciTop = height - 1 - bottom
        let rect = CGRect(x: left, y: ciTop, width: right - left, height: bottom - top)
        return rect.intersection(extent)
    }
}
