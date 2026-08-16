import CoreGraphics
import Foundation
import Testing

/// Converting Vision's `boundingBox` to screen coordinates is where the search can go wrong
/// without anything actually failing: the rectangles would simply end up in the wrong place,
/// and on a page full of text that's hard to notice just by looking. Hence the tests on
/// vertical flipping, which is the most likely mistake (Vision has its origin at the bottom
/// left, SwiftUI at the top left).
@Suite("PageTextRecognizer")
struct PageTextRecognizerTests {
    @Test("Il testo in alto nella pagina finisce in alto sullo schermo")
    func flipsVerticalOrigin() {
        // A line 10% tall resting against the page's top edge: in Vision coordinates that's
        // y = 0.9, in screen coordinates it must land at y = 0.
        let box = CGRect(x: 0, y: 0.9, width: 1, height: 0.1)
        let rect = PageTextRecognizer.screenRect(
            forNormalized: box,
            imageSize: CGSize(width: 100, height: 200),
            displaySize: CGSize(width: 100, height: 200)
        )

        #expect(rect.minY == 0)
        #expect(rect.height == 20)
    }

    @Test("Il testo in basso nella pagina finisce in basso sullo schermo")
    func bottomStaysAtBottom() {
        let box = CGRect(x: 0, y: 0, width: 1, height: 0.1)
        let rect = PageTextRecognizer.screenRect(
            forNormalized: box,
            imageSize: CGSize(width: 100, height: 200),
            displaySize: CGSize(width: 100, height: 200)
        )

        #expect(rect.maxY == 200)
    }

    /// The page is centered with `scaledToFit`, so in a viewport wider than the page there's an
    /// empty band on the left and right: highlights must move with the page, not stay anchored
    /// to the screen edge.
    @Test("Tiene conto delle bande laterali quando la pagina non riempie il viewport")
    func accountsForLetterboxing() {
        let box = CGRect(x: 0, y: 0, width: 1, height: 1)
        let rect = PageTextRecognizer.screenRect(
            forNormalized: box,
            imageSize: CGSize(width: 100, height: 200),
            displaySize: CGSize(width: 400, height: 200)
        )

        // The fitted page is 100×200 centered in 400×200: 150-point bands on each side.
        #expect(rect.minX == 150)
        #expect(rect.width == 100)
        #expect(rect.minY == 0)
        #expect(rect.height == 200)
    }

    @Test("Dimensioni degenerate non producono NaN")
    func rejectsDegenerateSizes() {
        let box = CGRect(x: 0, y: 0, width: 1, height: 1)
        #expect(PageTextRecognizer.screenRect(forNormalized: box, imageSize: .zero, displaySize: CGSize(width: 10, height: 10)) == .zero)
        #expect(PageTextRecognizer.screenRect(forNormalized: box, imageSize: CGSize(width: 10, height: 10), displaySize: .zero) == .zero)
    }

    @Test("Le lingue passate a Vision non sono mai vuote")
    func alwaysHasALanguage() {
        #expect(!PageTextRecognizer.recognitionLanguages.isEmpty)
    }

    /// Con l'auto-crop attivo la pagina disegnata a schermo non è quella su cui è girato l'OCR:
    /// senza questa variante, un rettangolo normalizzato sulla pagina originale finirebbe
    /// nel punto sbagliato non appena la pagina viene ritagliata.
    @Test("Con cropRect nil il risultato è identico alla conversione senza ritaglio")
    func nilCropRectMatchesUncroppedConversion() {
        let box = CGRect(x: 0.1, y: 0.8, width: 0.3, height: 0.1)
        let imageSize = CGSize(width: 100, height: 200)
        let displaySize = CGSize(width: 100, height: 200)

        let plain = PageTextRecognizer.screenRect(forNormalized: box, imageSize: imageSize, displaySize: displaySize)
        let withNilCrop = PageTextRecognizer.screenRect(
            forNormalized: box, imageSize: imageSize, cropRect: nil, displaySize: displaySize
        )
        #expect(withNilCrop == plain)
    }

    @Test("Una riga interamente dentro il ritaglio si sposta dell'offset del ritaglio")
    func lineFullyInsideCropShiftsByOffset() {
        // Pagina 100×200 con un bordo di 20pt ritagliato su ogni lato: resta un contenuto
        // 60×160. Una riga che occupa il quarto centrale in verticale, appena sotto al centro,
        // deve restare interamente visibile e mappata sulla pagina ritagliata, non su quella
        // originale.
        let imageSize = CGSize(width: 100, height: 200)
        let cropRect = CGRect(x: 20, y: 20, width: 60, height: 160) // top-left origin
        let box = CGRect(x: 0.3, y: 0.4, width: 0.4, height: 0.1) // bottom-left origin, normalized

        let rect = PageTextRecognizer.screenRect(
            forNormalized: box, imageSize: imageSize, cropRect: cropRect, displaySize: cropRect.size
        )
        #expect(rect != nil)

        // Senza ritaglio, la stessa riga cadrebbe in un punto diverso: la conversione deve
        // davvero tener conto dell'offset, non limitarsi a passare oltre.
        let withoutCrop = PageTextRecognizer.screenRect(forNormalized: box, imageSize: imageSize, displaySize: imageSize)
        #expect(rect! != withoutCrop)
    }

    @Test("Una riga interamente nel bordo ritagliato via non produce alcun rettangolo")
    func lineOutsideCropProducesNil() {
        let imageSize = CGSize(width: 100, height: 200)
        // Ritaglio che esclude la fascia superiore della pagina (in coordinate bottom-left,
        // "sopra" corrisponde a y vicino a `imageSize.height`).
        let cropRect = CGRect(x: 0, y: 20, width: 100, height: 160)
        let boxInTheCroppedBorder = CGRect(x: 0, y: 0.95, width: 1, height: 0.05)

        let rect = PageTextRecognizer.screenRect(
            forNormalized: boxInTheCroppedBorder, imageSize: imageSize, cropRect: cropRect, displaySize: cropRect.size
        )
        #expect(rect == nil)
    }

    @Test("Dimensioni degenerate del ritaglio non producono NaN")
    func rejectsDegenerateCropRect() {
        let box = CGRect(x: 0, y: 0, width: 1, height: 1)
        let rect = PageTextRecognizer.screenRect(
            forNormalized: box, imageSize: CGSize(width: 10, height: 10),
            cropRect: .zero, displaySize: CGSize(width: 10, height: 10)
        )
        #expect(rect == nil)
    }
}
