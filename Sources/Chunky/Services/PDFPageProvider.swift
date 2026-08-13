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
