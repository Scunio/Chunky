#if os(tvOS)
import XCTest

/// "Account" — the tvOS split view (`AccountsView.tvOSSplitView`): categories on the left,
/// selected content on the right, replacing the old single-column scrolling list.
final class TVAccountUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testCategoryListShowsAllExpectedRows() {
        let app = launchPastProfilePicker()
        selectTab("Account", in: app)

        for label in ["Downloads", "Web", "Calibre / Ubooquity / OPDS", "Nuovo account WebDAV", "Nuovo account SMB"] {
            XCTAssertTrue(app.staticTexts[label].waitForExistence(timeout: 5), "Riga mancante nella lista Account: \"\(label)\"")
        }
    }

    func testSelectingWebDAVShowsTheAddAccountForm() {
        let app = launchPastProfilePicker()
        selectTab("Account", in: app)

        let webdavRow = app.buttons["Nuovo account WebDAV"]
        XCTAssertTrue(webdavRow.waitForExistence(timeout: 5))

        // `hasFocus` on a List-embedded Button is unreliable here (XCUITest reads a stale
        // accessibility snapshot for reused list cells), so this steers by a fixed press count
        // instead of polling focus: Downloads → Web → Calibre/OPDS → WebDAV, 4 presses down
        // from the tab bar with no accounts saved yet.
        let remote = XCUIRemote.shared
        for _ in 0..<4 {
            remote.press(.down)
            Thread.sleep(forTimeInterval: 0.5)
        }
        remote.press(.select)

        XCTAssertTrue(app.textFields["Nome account"].waitForExistence(timeout: 5),
                      "Il form \"Nuovo account\" non è comparso nel pannello di dettaglio")
        XCTAssertTrue(app.textFields["URL del server"].exists)
        XCTAssertTrue(app.buttons["Salva"].exists)
    }
}
#endif
