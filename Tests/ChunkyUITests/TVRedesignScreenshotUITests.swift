#if os(tvOS)
import XCTest

/// Not a pass/fail regression test: a screenshot-capture tool for verifying the tvOS redesign
/// visually without needing eyes on the physical Apple TV. Every screenshot is attached with
/// `.keepAlways` so it shows up in the .xcresult bundle regardless of outcome. Deliberately
/// avoids hard assertions on specific UI elements (their accessibility identifiers aren't wired
/// up yet) — the point is capturing what's on screen, not asserting about it.
final class TVRedesignScreenshotUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = true
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testCaptureRedesignedScreens() {
        let app = XCUIApplication()
        app.launchArguments += ["--uitesting"]
        app.launch()

        let remote = XCUIRemote.shared

        // tvOS sometimes shows its own user-profile-picker interstitial before handing focus
        // to the app at all (observed intermittently across runs, timing varies) — if it's up,
        // select the default-focused profile and keep polling for the tab bar's own text rather
        // than assuming a fixed wait gets past it.
        _ = app.wait(for: .runningForeground, timeout: 20)
        var sawLibreria = false
        for _ in 0..<15 {
            if app.buttons["Libreria"].waitForExistence(timeout: 2) {
                sawLibreria = true
                break
            }
            remote.press(.select)
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(sawLibreria, "La tab bar di Chunky non è comparsa: probabilmente bloccati sulla schermata profilo di sistema.")
        Thread.sleep(forTimeInterval: 1)
        attach(app, name: "01-library-tab")

        // Step right through the tabs from the tab bar itself, capturing each. No Menu press
        // between tabs: confirmed live that Menu exits the app straight to the tvOS Home Screen
        // whenever there's nothing deeper to back out of (standard tvOS behavior, not a bug) —
        // the first attempt at this test did exactly that and ended up screenshotting a
        // different app entirely. Focus starts on the tab bar itself ("Libreria" selected, no
        // deeper content pushed for an empty library), so plain .right presses are enough to
        // move across tabs without ever leaving it.
        let tabNames = ["library", "now-reading", "favorites", "accounts", "settings"]
        for (index, name) in tabNames.enumerated() {
            if index > 0 {
                remote.press(.right)
                Thread.sleep(forTimeInterval: 1)
            }
            attach(app, name: "02-tab-\(index)-\(name)")
        }
    }
}
#endif
