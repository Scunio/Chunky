import XCTest

// The reader's pager is a UIKit collection view, so these assertions only mean something
// on iOS — the same file is compiled into the macOS UI test target too.
#if os(iOS)

/// Kept in step with `UITestSeed` by hand: the UI test target doesn't link the app's code.
enum UITestSeedNames {
    static let comic = "uitest-landmark"
    static let page = "reader.page"
}

/// Guards the one reader invariant that kept regressing by hand: showing the controls must
/// *cover* the page, never move or resize it.
///
/// The failure it exists for: the bars come with the status bar, the status bar changes the
/// window's safe-area inset, and anything laid out against that inset shrinks by its height —
/// on iPad, where hiding the status bar takes the top inset to zero, by the full 32 pt. It was
/// re-introduced several times because it's invisible on a page that already fills the screen,
/// and nearly invisible on a notched iPhone, where the inset barely changes.
///
/// Frames, not screenshots: the geometry is the thing being asserted, and a pixel baseline
/// would break on every unrelated visual change.
final class ReaderLayoutUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launchReader() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--uitesting", "--uitesting-seed"]
        app.launch()

        // The fixture is written on launch, which on a clean container is *after* the library
        // has already scanned: it gets adopted by the next scan, so the first run needs one
        // relaunch. Deterministic, not a retry — on every later run the file is already there.
        var comic = app.buttons[UITestSeedNames.comic]
        if !comic.waitForExistence(timeout: 15) {
            app.terminate()
            app.launch()
            comic = app.buttons[UITestSeedNames.comic]
            XCTAssertTrue(comic.waitForExistence(timeout: 30),
                          "Il fumetto di test non è comparso in libreria: il seeding non ha funzionato")
        }
        comic.tap()
        return app
    }

    /// The page's own scroll view, not the pager: the collection view stays full-screen even
    /// when its cells don't, so asserting on it would pass straight through the regression
    /// this test exists for. Verified by re-introducing the bug: the pager's frame didn't
    /// budge, this one did.
    private func pageFrame(_ app: XCUIApplication) -> CGRect {
        let page = app.descendants(matching: .any)
            .matching(identifier: UITestSeedNames.page)
            .firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 30), "La pagina del reader non è comparsa")
        return page.frame
    }

    private func toggleControls(_ app: XCUIApplication) {
        // The accessibility overlay mirrors the real tap zones, so this is the same central
        // band a finger would hit.
        let toggle = app.buttons["Mostra o nascondi i controlli"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "La zona di toggle dei controlli non è raggiungibile")
        toggle.tap()
    }

    func testPageFillsTheWindowAndDoesNotMoveWhenControlsToggle() {
        let app = launchReader()
        let window = app.windows.firstMatch.frame

        let withControls = pageFrame(app)
        XCTAssertEqual(withControls, window,
                       "La pagina non copre tutta la finestra con i controlli visibili: \(withControls) vs \(window)")

        toggleControls(app)
        let withoutControls = pageFrame(app)
        XCTAssertEqual(withoutControls, withControls,
                       "La pagina si è spostata o ridimensionata al toggle dei controlli: \(withControls) -> \(withoutControls)")

        // Back again: the bug showed up on the way in, but a fix that only held in one
        // direction would still be broken.
        toggleControls(app)
        XCTAssertEqual(pageFrame(app), withControls,
                       "La pagina non è tornata alla stessa geometria dopo il secondo toggle")
    }

    /// The bars have to reach the screen's real edges: the same inset that moved the page also
    /// used to leave a strip of bare background under the footer.
    func testChromeReachesTheWindowEdges() {
        let app = launchReader()
        let window = app.windows.firstMatch.frame

        // The reader hides its controls on an idle timer, so by now they may be gone.
        let header = app.buttons["Libreria"]
        if !header.waitForExistence(timeout: 3) {
            toggleControls(app)
        }
        XCTAssertTrue(header.waitForExistence(timeout: 15), "L'header del reader non è comparso")
        XCTAssertLessThan(header.frame.minY, window.minY + 80,
                          "L'header è troppo lontano dal bordo superiore: \(header.frame)")

        let footer = app.buttons.matching(NSPredicate(format: "label CONTAINS '/'")).firstMatch
        if footer.waitForExistence(timeout: 5) {
            XCTAssertGreaterThan(footer.frame.maxY, window.maxY - 80,
                                 "Il footer non arriva al bordo inferiore: \(footer.frame)")
        }
    }
}
#endif
