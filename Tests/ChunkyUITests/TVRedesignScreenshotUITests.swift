#if os(tvOS)
import XCTest

/// Not a pass/fail regression test: a screenshot-capture tool for verifying the tvOS redesign
/// visually without needing eyes on the physical Apple TV. Every screenshot is attached with
/// `.keepAlways` so it shows up in the .xcresult bundle regardless of outcome.
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
        // UI tests run out-of-process and can't import the app target, so this string is kept
        // in sync with `UITestSeed.multiLaunchArgument` by hand — see that type's doc comment.
        let app = launchPastProfilePicker(extraArguments: ["--uitesting-seed-multi"])
        attach(app, name: "01-library-tab")

        let remote = XCUIRemote.shared
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
