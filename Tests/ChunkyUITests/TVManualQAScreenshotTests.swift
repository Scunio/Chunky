#if os(tvOS)
import XCTest

/// Temporary, not meant to stay: verifies the new push-based Account navigation (illustration
/// panel + plain list, replacing the old always-visible category/detail split view) and that
/// AddAccountView still works correctly now that it no longer wraps itself in its own
/// `NavigationStack` (it's pushed inside AccountsView's).
final class TVManualQAScreenshotTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = true
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testAccountPushNavigation() {
        let app = XCUIApplication()
        app.launch()

        let remote = XCUIRemote.shared
        _ = app.wait(for: .runningForeground, timeout: 20)
        XCTAssertTrue(app.buttons["Libreria"].waitForExistence(timeout: 15), "Tab bar non comparsa")
        Thread.sleep(forTimeInterval: 1.0)

        for _ in 0..<3 {
            remote.press(.right)
            Thread.sleep(forTimeInterval: 0.4)
        }
        remote.press(.select)
        Thread.sleep(forTimeInterval: 1.5)
        attach(app, name: "01-account-list-illustrazione")

        // Category list: Downloads (focused) -> Web -> [Trovati in rete se presente] -> ... -> SMB
        for _ in 0..<5 {
            remote.press(.down)
            Thread.sleep(forTimeInterval: 0.4)
        }
        attach(app, name: "02-nuovo-account-smb-a-fuoco")

        remote.press(.select)
        Thread.sleep(forTimeInterval: 1.5)
        attach(app, name: "03-form-push")

        remote.press(.menu)
        Thread.sleep(forTimeInterval: 1.0)
        attach(app, name: "04-dopo-back")
        XCTAssertTrue(app.staticTexts["Account"].waitForExistence(timeout: 5),
                      "Il back dal form non torna alla lista Account")
    }
}
#endif
