import CoreGraphics
import Foundation

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

    static func seedIfRequested() {
        if CommandLine.arguments.contains(multiLaunchArgument) {
            seedMultiple()
            return
        }
        guard CommandLine.arguments.contains(launchArgument) else { return }
        let url = LibraryStorage.localDocumentsURL.appendingPathComponent("\(comicTitle).pdf")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        writeLandmarkPDF(to: url)
    }

    /// Title of the Nth seeded comic (1-based) when `multiLaunchArgument` is used — grid tests
    /// tap/focus a specific one by name instead of an arbitrary/first cell.
    static func multiComicTitle(_ index: Int) -> String {
        "uitest-grid-\(String(format: "%02d", index))"
    }

    private static func seedMultiple() {
        for index in 1...comicCount {
            let url = LibraryStorage.localDocumentsURL.appendingPathComponent("\(multiComicTitle(index)).pdf")
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            writeLandmarkPDF(to: url, colorSeed: index)
        }
    }

    /// Three 2:3 pages, each split into four colour bands by thin white lines. Those lines are
    /// what a layout test measures: they sit *inside* the page, so they can only move if the
    /// page itself does. A solid-colour page can't distinguish "revealed by the bars" from
    /// "moved by a layout bug" once it fills the screen.
    private static func writeLandmarkPDF(to url: URL, colorSeed: Int = 0) {
        var mediaBox = CGRect(x: 0, y: 0, width: 1200, height: 1800)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else { return }
        // `colorSeed == 0` (the single-comic case) keeps the original fixed palette untouched;
        // a non-zero seed (grid seeding) picks a different, deterministic solid-ish palette per
        // comic so cells are visually distinguishable in a screenshot.
        let bands: [CGColor]
        if colorSeed == 0 {
            bands = [
                CGColor(red: 1, green: 0, blue: 0, alpha: 1),
                CGColor(red: 1, green: 1, blue: 0, alpha: 1),
                CGColor(red: 0, green: 0.47, blue: 1, alpha: 1),
                CGColor(red: 0.04, green: 0.04, blue: 0.04, alpha: 1)
            ]
        } else {
            let r = CGFloat((colorSeed * 47) % 255) / 255
            let g = CGFloat((colorSeed * 97) % 255) / 255
            let b = CGFloat((colorSeed * 17) % 255) / 255
            bands = [
                CGColor(red: r, green: g, blue: b, alpha: 1),
                CGColor(red: 1 - r, green: g, blue: b, alpha: 1),
                CGColor(red: r, green: 1 - g, blue: b, alpha: 1),
                CGColor(red: r, green: g, blue: 1 - b, alpha: 1)
            ]
        }
        let bandHeight = mediaBox.height / CGFloat(bands.count)
        for _ in 0..<3 {
            context.beginPDFPage(nil)
            for (index, colour) in bands.enumerated() {
                context.setFillColor(colour)
                context.fill(CGRect(x: 0, y: CGFloat(index) * bandHeight,
                                    width: mediaBox.width, height: bandHeight))
            }
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            for index in 1..<bands.count {
                context.fill(CGRect(x: 0, y: CGFloat(index) * bandHeight - 2,
                                    width: mediaBox.width, height: 4))
            }
            context.endPDFPage()
        }
        context.closePDF()
    }
}
