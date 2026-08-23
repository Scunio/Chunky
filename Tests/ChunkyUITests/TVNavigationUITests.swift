#if os(tvOS)
import XCTest

/// Verifies the tab bar itself: all 5 destinations exist, are text-labeled (the tvOS HIG
/// requirement icon-only toolbars don't have to meet), and switching between them actually
/// changes the visible screen.
final class TVNavigationUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testAllFiveTabsExist() {
        let app = launchPastProfilePicker()
        for label in ["Libreria", "In lettura", "Preferiti", "Account", "Impostazioni"] {
            XCTAssertTrue(app.buttons[label].exists, "Manca la tab \"\(label)\"")
        }
    }

    func testSwitchingTabsChangesContent() {
        let app = launchPastProfilePicker()

        selectTab("In lettura", in: app)
        XCTAssertTrue(app.staticTexts["In lettura"].waitForExistence(timeout: 5),
                      "Il titolo \"In lettura\" non è comparso dopo aver selezionato la tab")

        selectTab("Impostazioni", in: app)
        XCTAssertTrue(app.staticTexts["Aspetto"].waitForExistence(timeout: 5),
                      "La riga \"Aspetto\" non è comparsa nella tab Impostazioni")
        XCTAssertTrue(app.staticTexts["Blocco genitori"].exists)

        selectTab("Account", in: app)
        XCTAssertTrue(app.staticTexts["Downloads"].waitForExistence(timeout: 5),
                      "La riga \"Downloads\" non è comparsa nella tab Account")

        // Back to the start, confirming the bar isn't a one-way ratchet.
        selectTab("Libreria", in: app)
        XCTAssertTrue(app.staticTexts["Chunky"].waitForExistence(timeout: 5) || app.buttons["Libreria"].hasFocus,
                      "Non sono tornato sulla tab Libreria")
    }
}
#endif
