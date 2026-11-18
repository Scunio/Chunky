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

    /// The long add-account form is a ScrollView with its own `.onExitCommand`: Menu pressed after
    /// scrolling to the bottom must still pop back to the Account list with the tab bar visible.
    func testMenuFromLongFormReturnsToAccountListWithTabBar() {
        for row in ["Calibre / Ubooquity / OPDS", "Nuovo account SMB"] {
            let app = launchPastProfilePicker()
            selectTab("Account", in: app)
            XCTAssertTrue(app.cells[row].waitForExistence(timeout: 5))
            focusRow(row, in: app)
            XCUIRemote.shared.press(.select)
            XCTAssertTrue(app.buttons["Salva"].waitForExistence(timeout: 5), "\(row): form non comparso")
            moveFocus(to: app.buttons["Salva"], direction: .down, maxSteps: 40, app: app)
            Thread.sleep(forTimeInterval: 0.5)
            XCUIRemote.shared.press(.menu)
            Thread.sleep(forTimeInterval: 1.5)
            XCTAssertTrue(app.cells[row].waitForExistence(timeout: 5), "\(row): Menu non ha riportato alla lista Account")
            XCTAssertTrue(app.buttons["Libreria"].exists && app.buttons["Impostazioni"].exists,
                          "\(row): la tab bar non è tornata visibile dopo Menu")
            app.terminate()
        }
    }

    /// Real OPDS add + browse against a local catalog. Skipped unless `CHUNKY_OPDS_URL` is set
    /// (pass it as `TEST_RUNNER_CHUNKY_OPDS_URL`).
    func testAddingAnOPDSAccountThroughTheForm() throws {
        let url = ProcessInfo.processInfo.environment["CHUNKY_OPDS_URL"] ?? ""
        try XCTSkipUnless(!url.isEmpty, "Imposta CHUNKY_OPDS_URL per eseguire il test OPDS reale")
        let app = launchPastProfilePicker()
        selectTab("Account", in: app)
        focusRow("Calibre / Ubooquity / OPDS", in: app)
        XCUIRemote.shared.press(.select)

        let name = app.textFields["Nome"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        moveFocus(to: name, direction: .down, app: app)
        enterText("Test OPDS", into: name, app: app)
        let urlField = app.textFields["URL del server"]
        moveFocus(to: urlField, direction: .down, app: app)
        enterText(url, into: urlField, app: app)
        moveFocus(to: app.buttons["Salva"], direction: .down, maxSteps: 40, app: app)
        XCUIRemote.shared.press(.select)
        Thread.sleep(forTimeInterval: 1.5)

        XCTAssertTrue(app.staticTexts["Test OPDS"].waitForExistence(timeout: 8), "L'account OPDS salvato non è nella lista")
        // The account row's label also carries its scan status ("Test OPDS, Mai scansionato").
        XCTAssertTrue(app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", "Test OPDS")).firstMatch.waitForExistence(timeout: 5))
        // After the pop the cells report no focus state reliably: walk to the top, then down
        // past "Download" and "Web" onto the new account row.
        for _ in 0..<4 { XCUIRemote.shared.press(.up); Thread.sleep(forTimeInterval: 0.4) }
        for _ in 0..<2 { XCUIRemote.shared.press(.down); Thread.sleep(forTimeInterval: 0.5) }
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["Serie Alpha"].waitForExistence(timeout: 15), "Il catalogo OPDS non è stato sfogliato")
        add(XCTAttachment(screenshot: app.screenshot()))
    }
}
#endif
