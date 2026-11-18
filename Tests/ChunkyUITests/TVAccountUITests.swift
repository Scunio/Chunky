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

        for label in ["Download", "Web", "Calibre / Ubooquity / OPDS", "Nuovo account WebDAV", "Nuovo account SMB"] {
            XCTAssertTrue(app.staticTexts[label].waitForExistence(timeout: 5), "Riga mancante nella lista Account: \"\(label)\"")
        }
    }

    func testSelectingWebDAVShowsTheAddAccountForm() {
        let app = launchPastProfilePicker()
        selectTab("Account", in: app)

        XCTAssertTrue(app.cells["Nuovo account WebDAV"].waitForExistence(timeout: 5))
        focusRow("Nuovo account WebDAV", in: app)
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(app.textFields["Nome"].waitForExistence(timeout: 5),
                      "Il form \"Nuovo account\" non è comparso nel pannello di dettaglio")
        XCTAssertTrue(app.textFields["URL del server"].exists)
        XCTAssertTrue(app.buttons["Salva"].exists)

        // Menu pops the form back to the category list.
        XCUIRemote.shared.press(.menu)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(app.cells["Nuovo account WebDAV"].waitForExistence(timeout: 5),
                      "Menu non ha riportato alla lista Account")
    }
}
#endif
