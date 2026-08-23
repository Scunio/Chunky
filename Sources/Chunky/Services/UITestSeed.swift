import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import ZIPFoundation

/// Deterministic library fixture, written on launch only when `--uitesting-seed` is passed.
/// UI tests can't otherwise reach the app's container to put a comic there, and a test that
/// skips itself when the library happens to be empty guards nothing in CI.
enum UITestSeed {
    static let launchArgument = "--uitesting-seed"
    /// Seeds `comicCount` numbered comics instead of the single landmark one — for tests that
    /// need an actual grid (layout, focus, scrolling) rather than just "the library isn't empty".
    static let multiLaunchArgument = "--uitesting-seed-multi"
    /// The library shows a comic under its file name, so this doubles as the title the test
    /// taps on.
    static let comicTitle = "uitest-landmark"
    static let comicCount = 14

    /// PDFKit doesn't exist on tvOS devices (see `ComicPageProviderFactory`): a `.pdf` fixture
    /// there would sit on disk forever unread, never registered into the library. `.cbz` (a
    /// zip of PNGs) is the one format every platform can actually open.
    private static var fixtureExtension: String {
        #if os(tvOS)
        "cbz"
        #else
        "pdf"
        #endif
    }

    static func seedIfRequested() {
        if CommandLine.arguments.contains(multiLaunchArgument) {
            seedMultiple()
            return
        }
        guard CommandLine.arguments.contains(launchArgument) else { return }
        let url = LibraryStorage.localDocumentsURL.appendingPathComponent("\(comicTitle).\(fixtureExtension)")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        writeLandmarkFixture(to: url)
    }

    /// Title of the Nth seeded comic (1-based) when `multiLaunchArgument` is used — grid tests
    /// tap/focus a specific one by name instead of an arbitrary/first cell.
    static func multiComicTitle(_ index: Int) -> String {
        "uitest-grid-\(String(format: "%02d", index))"
    }

    private static func seedMultiple() {
        for index in 1...comicCount {
            let url = LibraryStorage.localDocumentsURL.appendingPathComponent("\(multiComicTitle(index)).\(fixtureExtension)")
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            writeLandmarkFixture(to: url, colorSeed: index)
        }
    }

    private static func writeLandmarkFixture(to url: URL, colorSeed: Int = 0) {
        #if os(tvOS)
        writeLandmarkCBZ(to: url, colorSeed: colorSeed)
        #else
        writeLandmarkPDF(to: url, colorSeed: colorSeed)
        #endif
    }

    /// `colorSeed == 0` (the single-comic case) keeps the original fixed palette untouched;
    /// a non-zero seed (grid seeding) picks a different, deterministic solid-ish palette per
    /// comic so cells are visually distinguishable in a screenshot.
    private static func bands(for colorSeed: Int) -> [CGColor] {
        guard colorSeed != 0 else {
            return [
                CGColor(red: 1, green: 0, blue: 0, alpha: 1),
                CGColor(red: 1, green: 1, blue: 0, alpha: 1),
                CGColor(red: 0, green: 0.47, blue: 1, alpha: 1),
                CGColor(red: 0.04, green: 0.04, blue: 0.04, alpha: 1)
            ]
        }
        let r = CGFloat((colorSeed * 47) % 255) / 255
        let g = CGFloat((colorSeed * 97) % 255) / 255
        let b = CGFloat((colorSeed * 17) % 255) / 255
        return [
            CGColor(red: r, green: g, blue: b, alpha: 1),
            CGColor(red: 1 - r, green: g, blue: b, alpha: 1),
            CGColor(red: r, green: 1 - g, blue: b, alpha: 1),
            CGColor(red: r, green: g, blue: 1 - b, alpha: 1)
        ]
    }

    /// Three 2:3 pages, each split into four colour bands by thin white lines. Those lines are
    /// what a layout test measures: they sit *inside* the page, so they can only move if the
    /// page itself does. A solid-colour page can't distinguish "revealed by the bars" from
    /// "moved by a layout bug" once it fills the screen.
    private static func writeLandmarkPDF(to url: URL, colorSeed: Int = 0) {
        var mediaBox = CGRect(x: 0, y: 0, width: 1200, height: 1800)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else { return }
        let pageBands = bands(for: colorSeed)
        let bandHeight = mediaBox.height / CGFloat(pageBands.count)
        for _ in 0..<3 {
            context.beginPDFPage(nil)
            drawBands(pageBands, bandHeight: bandHeight, size: mediaBox.size, into: context)
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// Same visual fixture as `writeLandmarkPDF`, as a zip of PNG pages instead: the format
    /// every `CBZPageProvider`-capable platform (including tvOS) can actually open.
    private static func writeLandmarkCBZ(to url: URL, colorSeed: Int = 0) {
        let pageBands = bands(for: colorSeed)
        let size = CGSize(width: 1200, height: 1800)
        let bandHeight = size.height / CGFloat(pageBands.count)

        guard let archive = try? Archive(url: url, accessMode: .create) else { return }
        for page in 0..<3 {
            guard let pageData = renderPagePNG(bands: pageBands, bandHeight: bandHeight, size: size) else { continue }
            try? archive.addEntry(
                with: "page\(page + 1).png",
                type: .file,
                uncompressedSize: Int64(pageData.count),
                provider: { position, bufferSize -> Data in
                    let start = Int(position)
                    let end = min(start + bufferSize, pageData.count)
                    return pageData.subdata(in: start..<end)
                }
            )
        }
    }

    private static func renderPagePNG(bands pageBands: [CGColor], bandHeight: CGFloat, size: CGSize) -> Data? {
        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        drawBands(pageBands, bandHeight: bandHeight, size: size, into: context)
        guard let cgImage = context.makeImage() else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func drawBands(_ pageBands: [CGColor], bandHeight: CGFloat, size: CGSize, into context: CGContext) {
        for (index, colour) in pageBands.enumerated() {
            context.setFillColor(colour)
            context.fill(CGRect(x: 0, y: CGFloat(index) * bandHeight, width: size.width, height: bandHeight))
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        for index in 1..<pageBands.count {
            context.fill(CGRect(x: 0, y: CGFloat(index) * bandHeight - 2, width: size.width, height: 4))
        }
    }
}
