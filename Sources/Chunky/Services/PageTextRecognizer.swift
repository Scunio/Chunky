import Foundation
import CoreGraphics
import Vision

/// A line of text found on a page, with the rectangle that bounds it.
///
/// `boundingBox` is **normalized (0...1) with the origin at the bottom left**: it's the space of
/// `VNRecognizedTextObservation.boundingBox`, and it's also what you get by dividing a PDF
/// line's bounds by its page's bounds. Keeping a single space for both sources means that,
/// further downstream, the code that draws highlights doesn't need to know whether the text
/// came from OCR or from the PDF's text layer.
struct RecognizedTextLine: Codable, Equatable {
    let text: String
    let boundingBox: CGRect
}

/// OCR of a page using Vision. The idea (and the confidence threshold) come from Simple-Comic
/// <https://github.com/MaddTheSane/Simple-Comic>, MIT, which has the same feature on macOS: here
/// the wrapper is rewritten in Swift and already returns the normalized coordinates the reader
/// needs, instead of the AppKit selection layer, which wouldn't make sense on SwiftUI.
enum PageTextRecognizer {
    /// Below this confidence the observation is discarded: on comics, screentones, panel
    /// borders and sound effects easily produce "words" that don't actually exist, and that
    /// would just be noise in search.
    static let minimumConfidence: Float = 0.5

    /// Languages passed to Vision: the system's preferred ones that Vision actually knows how
    /// to recognize, plus English as a safety net. Without the fallback, on a system set to an
    /// unsupported language the request would fail entirely instead of still reading comics in
    /// English, which are the majority of those with Latin text.
    static let recognitionLanguages: [String] = {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let supported = Set((try? request.supportedRecognitionLanguages()) ?? [])
        guard !supported.isEmpty else { return ["en-US"] }

        var languages: [String] = []
        for preferred in Locale.preferredLanguages {
            // Locale.preferredLanguages returns full tags ("it-IT"); Vision sometimes only
            // exposes the base language ("it"). Try both forms before giving up on it.
            let base = String(preferred.prefix(while: { $0 != "-" }))
            if let match = supported.first(where: { $0 == preferred || $0 == base || $0.hasPrefix("\(base)-") }),
               !languages.contains(match) {
                languages.append(match)
            }
        }
        if let english = supported.first(where: { $0 == "en-US" }) ?? supported.first(where: { $0.hasPrefix("en") }),
           !languages.contains(english) {
            languages.append(english)
        }
        return languages.isEmpty ? ["en-US"] : languages
    }()

    static func recognizeLines(in cgImage: CGImage) throws -> [RecognizedTextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = recognitionLanguages

        try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])

        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first,
                  candidate.confidence >= minimumConfidence else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return RecognizedTextLine(text: text, boundingBox: observation.boundingBox)
        }
    }

    /// Converts a normalized `boundingBox` into the screen coordinates the page is actually
    /// drawn with.
    ///
    /// Two transformations, both necessary: the same `scaledToFit` geometry the reader uses to
    /// center the page (identical to the one in `PanelSelectionView.confirmSelection()`),
    /// **plus** the vertical flip, because SwiftUI has its origin at the top left and Vision at
    /// the bottom left. Forgetting the flip doesn't make anything fail outright: it simply puts
    /// every highlight in the wrong half of the page, which is why the conversion lives here in
    /// a single spot and is covered by tests.
    static func screenRect(forNormalized box: CGRect, imageSize: CGSize, displaySize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              displaySize.width > 0, displaySize.height > 0 else { return .zero }

        let scale = min(displaySize.width / imageSize.width, displaySize.height / imageSize.height)
        let fittedSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let originX = (displaySize.width - fittedSize.width) / 2
        let originY = (displaySize.height - fittedSize.height) / 2

        return CGRect(
            x: originX + box.minX * fittedSize.width,
            y: originY + (1 - box.maxY) * fittedSize.height,
            width: box.width * fittedSize.width,
            height: box.height * fittedSize.height
        )
    }

    /// Same conversion, but for a page shown auto-cropped: `box` is still normalized against the
    /// *original* page (that's what OCR ran on), while `cropRect` — pixel coordinates, origin at
    /// the top left, from `ImageProcessing.contentCropRect` — is what's actually on screen.
    /// `cropRect == nil` falls back to the plain uncropped conversion. The function returns `nil`
    /// when the line falls entirely in the border that got cropped away — nothing to draw.
    static func screenRect(
        forNormalized box: CGRect, imageSize: CGSize, cropRect: CGRect?, displaySize: CGSize
    ) -> CGRect? {
        guard let cropRect else { return screenRect(forNormalized: box, imageSize: imageSize, displaySize: displaySize) }
        guard imageSize.width > 0, imageSize.height > 0, cropRect.width > 0, cropRect.height > 0 else { return nil }

        // Everything gets expressed in the bottom-left-origin pixel space `box` already uses,
        // so the crop rectangle can be intersected with it directly.
        let boxPixels = CGRect(
            x: box.minX * imageSize.width, y: box.minY * imageSize.height,
            width: box.width * imageSize.width, height: box.height * imageSize.height
        )
        let cropPixels = CGRect(
            x: cropRect.minX, y: imageSize.height - cropRect.maxY,
            width: cropRect.width, height: cropRect.height
        )
        let visible = boxPixels.intersection(cropPixels)
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return nil }

        let renormalized = CGRect(
            x: (visible.minX - cropPixels.minX) / cropPixels.width,
            y: (visible.minY - cropPixels.minY) / cropPixels.height,
            width: visible.width / cropPixels.width,
            height: visible.height / cropPixels.height
        )
        return screenRect(forNormalized: renormalized, imageSize: cropRect.size, displaySize: displaySize)
    }
}
