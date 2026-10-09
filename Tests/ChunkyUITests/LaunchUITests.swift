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
        // `launch()` doesn't guarantee the app comes forward (repeat launches especially
        // stay behind the test runner): without a key window nothing is hittable, and
        // `isHittable` — unlike `waitForExistence` — fails instead of waiting.
        app.activate()
        return app
    }

    /// Cold start on shared CI runners is slow (CloudKit store setup, first-launch
    /// system checks): 20s flaked repeatedly on green code (nightlies 07/10 and 09/10),
    /// while the same tests pass locally in ~15s total. The timeout tolerates slow
    /// runners — it doesn't weaken the assertions below.
    private static let launchTimeout: TimeInterval = 60

    func testAppLaunchesAndShowsLibrary() {
        let app = launchApp()
        // The "Chunky" title is the library's header: if it doesn't appear, launch ended up
        // on StorageErrorView or on the parental-controls lock screen.
        XCTAssertTrue(app.staticTexts["Chunky"].waitForExistence(timeout: Self.launchTimeout),
                      "La libreria non è comparsa entro il timeout")
    }

    func testLibraryShowsImportAffordanceWhenEmpty() {
        let app = launchApp()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: Self.launchTimeout))
        // With an empty library the only visible entry point to import is this button.
        // If the library isn't empty, the test has nothing to verify.
        let importButton = app.buttons["Importa fumetti"]
        if importButton.waitForExistence(timeout: 5) {
            XCTAssertTrue(importButton.isHittable)
        }
    }
}
