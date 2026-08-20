import CoreGraphics
import Foundation

/// Deterministic library fixture, written on launch only when `--uitesting-seed` is passed.
/// UI tests can't otherwise reach the app's container to put a comic there, and a test that
/// skips itself when the library happens to be empty guards nothing in CI.
enum UITestSeed {
    static let launchArgument = "--uitesting-seed"
    /// The library shows a comic under its file name, so this doubles as the title the test
    /// taps on.
    static let comicTitle = "uitest-landmark"

    static func seedIfRequested() {
        guard CommandLine.arguments.contains(launchArgument) else { return }
        let url = LibraryStorage.localDocumentsURL.appendingPathComponent("\(comicTitle).pdf")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        writeLandmarkPDF(to: url)
    }

    /// Three 2:3 pages, each split into four colour bands by thin white lines. Those lines are
    /// what a layout test measures: they sit *inside* the page, so they can only move if the
    /// page itself does. A solid-colour page can't distinguish "revealed by the bars" from
    /// "moved by a layout bug" once it fills the screen.
    private static func writeLandmarkPDF(to url: URL) {
        var mediaBox = CGRect(x: 0, y: 0, width: 1200, height: 1800)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else { return }
        let bands: [CGColor] = [
            CGColor(red: 1, green: 0, blue: 0, alpha: 1),
            CGColor(red: 1, green: 1, blue: 0, alpha: 1),
            CGColor(red: 0, green: 0.47, blue: 1, alpha: 1),
            CGColor(red: 0.04, green: 0.04, blue: 0.04, alpha: 1)
        ]
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
