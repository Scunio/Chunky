import CoreImage
import CoreImage.CIFilterBuiltins

/// Optional filters applied to pages before showing them: automatic cropping of white
/// borders (common in scans) and quality upscaling for low-resolution pages.
enum ImageProcessing {
    private static let context = CIContext()

    /// Detects and removes uniformly light (white/near-white) borders around the page.
    static func autoCropWhiteBorders(_ image: PlatformImage) -> PlatformImage {
        guard let cgImage = image.cgImageRepresentation, let cropRect = contentCropRect(image) else { return image }
        let ciImage = CIImage(cgImage: cgImage)
        let extent = ciImage.extent
        // `contentCropRect` returns top-left-origin coordinates (see below); CoreImage wants
        // its own bottom-left-origin space back.
        let ciCropRect = CGRect(
            x: cropRect.minX, y: extent.height - cropRect.maxY,
            width: cropRect.width, height: cropRect.height
        )
        guard let cropped = context.createCGImage(ciImage, from: ciCropRect) else { return image }
        return PlatformImage.from(cgImage: cropped)
    }

    /// The content rectangle `autoCropWhiteBorders` would crop to, in pixel coordinates with
    /// the origin at the top left (the same convention as `crop(_:to:)`) — `nil` when nothing
    /// would be cropped. Exposed so callers whose own coordinates refer to the *original*,
    /// uncropped page (e.g. OCR search highlights) can translate into the cropped page's space
    /// without redoing the border detection themselves.
    static func contentCropRect(_ image: PlatformImage) -> CGRect? {
        guard let cgImage = image.cgImageRepresentation else { return nil }
        let ciImage = CIImage(cgImage: cgImage)
        let extent = ciImage.extent
        guard extent.width > 4, extent.height > 4,
              let ciCropRect = detectContentRect(in: ciImage, extent: extent),
              ciCropRect != extent, ciCropRect.width > 4, ciCropRect.height > 4 else {
            return nil
        }
        return CGRect(
            x: ciCropRect.minX, y: extent.height - ciCropRect.maxY,
            width: ciCropRect.width, height: ciCropRect.height
        )
    }

    /// Applies a Lanczos upscale (better quality than plain on-screen resizing)
    /// when the page is smaller than the target size.
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

    /// Automatically corrects contrast and saturation of a scanned page (often
    /// flat/faded), without requiring a manual tint like the user-configurable
    /// "page tint".
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

    /// Crops the image to the given rectangle, expressed in pixel coordinates (origin at the
    /// top left, as in display space). Used to share only a single panel.
    static func crop(_ image: PlatformImage, to rectTopLeftOrigin: CGRect) -> PlatformImage? {
        guard let cgImage = image.cgImageRepresentation else { return nil }
        let height = CGFloat(cgImage.height)
        // CGImage.cropping uses coordinates with origin at the bottom left: we convert the Y.
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

    /// Finds the content rectangle by scanning from the four edges toward the center,
    /// stopping at the first row/column that isn't uniformly near-white.
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

        // CoreImage coordinates have their origin at the bottom left: we convert the Y.
        let ciTop = height - 1 - bottom
        let rect = CGRect(x: left, y: ciTop, width: right - left, height: bottom - top)
        return rect.intersection(extent)
    }
}
