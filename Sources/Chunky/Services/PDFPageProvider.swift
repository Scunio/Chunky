import Foundation
import CoreGraphics

// PDFKit doesn't exist on tvOS devices (only appears to resolve on the Simulator SDK), so even
// the bare `import` crashes an archived/device build at launch with a dyld load failure.
#if !os(tvOS)
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

    /// Native (non-scanned) PDFs already have the text: reading it from PDFKit is instant and
    /// exact, whereas running them through OCR would cost seconds per page and give a worse
    /// result. On PDFs made only of scans `page.string` is empty and we fall back to OCR.
    func textLines(atPage index: Int) throws -> [RecognizedTextLine]? {
        guard let page = document.page(at: index) else { throw ComicReadError.pageOutOfRange }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0,
              let selection = page.selection(for: bounds) else { return nil }

        let lines = selection.selectionsByLine().compactMap { line -> RecognizedTextLine? in
            let text = (line.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            // PDF space already has its origin at the bottom left like Vision's (and it's the
            // same space in which `image(atPage:)` draws, without any flipping): it's enough to
            // normalize against the page bounds for the two kinds of line to be interchangeable.
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

        // A shared bitmap CGContext in place of UIGraphicsImageRenderer (iOS) and
        // NSImage.lockFocus (macOS). lockFocus is deprecated and, more importantly, draws into
        // the thread's current graphics context: this provider is invoked off the
        // main thread by ReaderView, where that context doesn't exist.
        //
        // The bitmap space has its origin at the bottom left like PDF space, so no
        // flipping is needed: just scaling.
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

        // PDF pages often have no background: without this fill they'd remain
        // transparent and would be unreadable in dark theme.
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
#endif
