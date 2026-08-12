import Foundation
import PDFKit
#if os(iOS) || os(visionOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

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
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)

        #if os(iOS) || os(visionOS)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            ctx.cgContext.setFillColor(PlatformColor.white.cgColor)
            ctx.cgContext.fill(CGRect(origin: .zero, size: size))
            ctx.cgContext.translateBy(x: 0, y: size.height)
            ctx.cgContext.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: ctx.cgContext)
        }
        #elseif os(macOS)
        let image = NSImage(size: size)
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.setFillColor(PlatformColor.white.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: ctx)
        }
        image.unlockFocus()
        return image
        #endif
    }
}
