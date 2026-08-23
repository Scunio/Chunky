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
        for index in 2...14 {
            let title = "uitest-grid-\(String(format: "%02d", index))"
            XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 5), "Copertina mancante nella griglia: \(title)")
        }
    }

    func testOpeningAComicShowsDetailScreenWithReadButton() {
        let app = launchPastProfilePicker(extraArguments: ["--uitesting-seed-multi"])
        let firstCover = app.buttons["uitest-grid-01"]
        XCTAssertTrue(firstCover.waitForExistence(timeout: 20))

        // Grid focus starts on the top-left cell (the tab bar sits above it) — one press down
        // from the bar should already land here; select opens it regardless of the exact path.
        let remote = XCUIRemote.shared
        remote.press(.down)
        Thread.sleep(forTimeInterval: 0.5)
        remote.press(.select)

        XCTAssertTrue(app.buttons["Leggi"].waitForExistence(timeout: 5),
                      "Il bottone \"Leggi\" non è comparso nella schermata di dettaglio")
        XCTAssertTrue(app.staticTexts["uitest-grid-01"].exists, "Il titolo del fumetto non è comparso nel dettaglio")

        // Menu should pop the detail screen back to the grid (a real push, unlike the tab bar's
        // own root, where Menu exits the app entirely — see TVRedesignScreenshotUITests' history).
        remote.press(.menu)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(app.buttons["Libreria"].waitForExistence(timeout: 5),
                      "Non sono tornato alla Libreria dopo aver premuto Menu dal dettaglio")
    }
}
#endif
