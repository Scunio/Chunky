#if os(tvOS)
import XCTest

/// The library grid and the comic detail screen it now opens into (`TVComicDetailView`) instead
/// of going straight to the reader.
final class TVLibraryUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testGridShowsAllSeededComics() {
        let app = launchPastProfilePicker(extraArguments: ["--uitesting-seed-multi"])
        // 14 files need a moment to be scanned, thumbnailed and inserted after a cold launch —
        // give the first one a generous timeout, the rest should already be there by then.
        XCTAssertTrue(app.buttons["uitest-grid-01"].waitForExistence(timeout: 20),
                      "Copertina mancante nella griglia: uitest-grid-01 (scansione libreria troppo lenta o fallita)")

        // The grid has 6 columns — rows 2 and 3 start off-screen, and `LazyVGrid` doesn't
        // materialize (or expose to the accessibility tree) cells that have never been
        // scrolled into view. System focus is still on the tab bar at this point (checking a
        // cell's existence doesn't move it), so the first down-press only enters row 1, not
        // row 2 — one extra press up front accounts for that before the row-boundary presses.
        let remote = XCUIRemote.shared
        remote.press(.down)
        Thread.sleep(forTimeInterval: 0.5)
        for index in 2...14 {
            if index == 7 || index == 13 {
                remote.press(.down)
                Thread.sleep(forTimeInterval: 0.5)
            }
            let title = "uitest-grid-\(String(format: "%02d", index))"
            XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 5), "Copertina mancante nella griglia: \(title)")
        }
    }

    func testOpeningAComicShowsDetailScreenWithReadButton() {
        let app = launchPastProfilePicker(extraArguments: ["--uitesting-seed-multi"])
        XCTAssertTrue(app.buttons["uitest-grid-01"].waitForExistence(timeout: 20))

        // Grid focus starts on the top-left cell (the tab bar sits above it) — one press down
        // from the bar should already land here. Which comic that actually is isn't guaranteed
        // (Core Data doesn't promise insertion order for same-timestamp inserts, confirmed:
        // the top-left cell isn't always "uitest-grid-01"), so this reads back whichever cell
        // gained focus instead of assuming — the test only needs *a* comic's detail screen to
        // open correctly, not a specific one.
        let remote = XCUIRemote.shared
        remote.press(.down)
        Thread.sleep(forTimeInterval: 0.5)
        guard let focusedTitle = app.buttons.allElementsBoundByIndex.first(where: { $0.hasFocus })?.label else {
            XCTFail("Nessuna cella della griglia ha il focus dopo la pressione giù")
            return
        }
        remote.press(.select)

        XCTAssertTrue(app.buttons["Leggi"].waitForExistence(timeout: 5),
                      "Il bottone \"Leggi\" non è comparso nella schermata di dettaglio")
        XCTAssertTrue(app.staticTexts[focusedTitle].waitForExistence(timeout: 5), "Il titolo del fumetto non è comparso nel dettaglio")

        // Menu should pop the detail screen back to the grid (a real push, unlike the tab bar's
        // own root, where Menu exits the app entirely — see TVRedesignScreenshotUITests' history).
        remote.press(.menu)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(app.buttons["Libreria"].waitForExistence(timeout: 5),
                      "Non sono tornato alla Libreria dopo aver premuto Menu dal dettaglio")
    }
}
#endif
