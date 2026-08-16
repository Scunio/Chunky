import CoreGraphics
import Foundation
import Testing

/// La conversione da `boundingBox` di Vision a coordinate schermo è il punto in cui la ricerca
/// può sbagliare senza che niente fallisca: i rettangoli finirebbero semplicemente nel posto
/// sbagliato, e su una pagina piena di testo è difficile accorgersene guardando. Da qui i test
/// sul ribaltamento verticale, che è l'errore più probabile (Vision ha l'origine in basso a
/// sinistra, SwiftUI in alto a sinistra).
@Suite("PageTextRecognizer")
struct PageTextRecognizerTests {
    @Test("Il testo in alto nella pagina finisce in alto sullo schermo")
    func flipsVerticalOrigin() {
        // Riga alta il 10% appoggiata al bordo superiore della pagina: in coordinate Vision è
        // y = 0.9, in coordinate schermo deve stare a y = 0.
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

    /// La pagina è centrata con `scaledToFit`, quindi in un viewport più largo di lei c'è una
    /// banda vuota a sinistra e a destra: le evidenziazioni devono spostarsi con la pagina, non
    /// restare ancorate al bordo dello schermo.
    @Test("Tiene conto delle bande laterali quando la pagina non riempie il viewport")
    func accountsForLetterboxing() {
        let box = CGRect(x: 0, y: 0, width: 1, height: 1)
        let rect = PageTextRecognizer.screenRect(
            forNormalized: box,
            imageSize: CGSize(width: 100, height: 200),
            displaySize: CGSize(width: 400, height: 200)
        )

        // La pagina fitted è 100×200 centrata in 400×200: bande da 150 punti per lato.
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
}
