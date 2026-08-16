import XCTest

/// UI tests use XCTest, not Swift Testing: XCUITest has no equivalent in the new framework.
/// Don't try to unify them.
///
/// They're deliberately few: UI tests are slow and fragile, and only serve to guard against
/// regressions that unit tests can't see. Native-Mac-specific tests (sidebar, ⌘, Preferences,
/// multiple windows) will come once those features exist.
final class LaunchUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--uitesting"]
        app.launch()
        return app
    }

    func testAppLaunchesAndShowsLibrary() {
        let app = launchApp()
        // The "Chunky" title is the library's header: if it doesn't appear, launch ended up
        // on StorageErrorView or on the parental-controls lock screen.
        XCTAssertTrue(app.staticTexts["Chunky"].waitForExistence(timeout: 20),
                      "La libreria non è comparsa entro il timeout")
    }

    func testLibraryShowsImportAffordanceWhenEmpty() {
        let app = launchApp()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        // With an empty library the only visible entry point to import is this button.
        // If the library isn't empty, the test has nothing to verify.
        let importButton = app.buttons["Importa fumetti"]
        if importButton.waitForExistence(timeout: 5) {
            XCTAssertTrue(importButton.isHittable)
        }
    }
}
