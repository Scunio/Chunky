import Foundation
import CoreGraphics
import PDFKit

final class PDFPageProvider: ComicPageProvider {
    private let document: PDFDocument

    var pageCount: Int { document.pageCount }

    init(fileURL: URL) throws {
        guard let document = PDFDocument(url: fileURL) else {
            throw ComicReadError.corruptArchive
        }
        self.document = document
    }

    /// I PDF nativi (non scansionati) hanno già il testo: leggerlo da PDFKit è immediato ed
    /// esatto, mentre passarli per l'OCR costerebbe secondi per pagina e darebbe un risultato
    /// peggiore. Sui PDF fatti di sole scansioni `page.string` è vuoto e si torna all'OCR.
    func textLines(atPage index: Int) throws -> [RecognizedTextLine]? {
        guard let page = document.page(at: index) else { throw ComicReadError.pageOutOfRange }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0,
              let selection = page.selection(for: bounds) else { return nil }

        let lines = selection.selectionsByLine().compactMap { line -> RecognizedTextLine? in
            let text = (line.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            // Lo spazio PDF ha già l'origine in basso a sinistra come quello di Vision (ed è lo
            // stesso in cui `image(atPage:)` disegna, senza ribaltamenti): basta normalizzare
            // sui bounds della pagina perché i due tipi di riga siano intercambiabili.
            let rect = line.bounds(for: page)
            return RecognizedTextLine(
                text: text,
                boundingBox: CGRect(
                    x: (rect.minX - bounds.minX) / bounds.width,
                    y: (rect.minY - bounds.minY) / bounds.height,
                    width: rect.width / bounds.width,
                    height: rect.height / bounds.height
                )
            )
        }
        return lines.isEmpty ? nil : lines
    }

    func image(atPage index: Int) throws -> PlatformImage {
        guard let page = document.page(at: index) else {
            throw ComicReadError.pageOutOfRange
        }
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2.0
        let width = Int((bounds.width * scale).rounded())
        let height = Int((bounds.height * scale).rounded())
        guard width > 0, height > 0 else { throw ComicReadError.corruptArchive }

        // Un CGContext bitmap condiviso al posto di UIGraphicsImageRenderer (iOS) e di
        // NSImage.lockFocus (macOS). lockFocus è deprecato e, soprattutto, disegna nel
        // contesto grafico corrente del thread: questo provider viene invocato fuori dal
        // main thread da ReaderView, dove quel contesto non esiste.
        //
        // Lo spazio bitmap ha origine in basso a sinistra come lo spazio PDF, quindi non
        // serve alcun ribaltamento: basta scalare.
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw ComicReadError.corruptArchive
        }

        // Le pagine PDF sono spesso senza sfondo: senza questo riempimento resterebbero
        // trasparenti e in tema scuro risulterebbero illeggibili.
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)

        guard let cgImage = context.makeImage() else {
            throw ComicReadError.corruptArchive
        }
        return PlatformImage.from(cgImage: cgImage)
    }
}
