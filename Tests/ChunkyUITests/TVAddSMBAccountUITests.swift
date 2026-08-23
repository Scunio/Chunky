#if os(tvOS)
import XCTest

/// End-to-end, real-network test of the "Nuovo account SMB" form entirely through the GUI:
/// fills in the same NAS this session already validated at the AMSMB2/network layer directly
/// (see the standalone connectivity script used earlier), saves, and confirms the account shows
/// up and can browse real share content — not just that the form's fields exist.
final class TVAddSMBAccountUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testAddingARealSMBAccountThroughTheForm() {
        let app = launchPastProfilePicker()
        selectTab("Account", in: app)

        let smbRow = app.staticTexts["Nuovo account SMB"]
        XCTAssertTrue(smbRow.waitForExistence(timeout: 5))
        moveFocus(to: smbRow, direction: .down, app: app)
        XCUIRemote.shared.press(.select)

        let nameField = app.textFields["Nome account"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "Il form SMB non è comparso")
        enterText("Test NAS", into: nameField, app: app)

        let hostField = app.textFields["Indirizzo"]
        moveFocus(to: hostField, direction: .down)
        enterText("NAS07BE7B.local", into: hostField, app: app)

        let shareField = app.textFields["Condivisione"]
        moveFocus(to: shareField, direction: .down)
        enterText("Public", into: shareField, app: app)

        let usernameField = app.textFields["Nome utente"]
        moveFocus(to: usernameField, direction: .down)
        enterText("Lorenzo", into: usernameField, app: app)

        let passwordField = app.secureTextFields["Password"]
        moveFocus(to: passwordField, direction: .down)
        enterText("Lorenzo98", into: passwordField, app: app)

        let saveButton = app.buttons["Salva"]
        moveFocus(to: saveButton, direction: .down)
        XCUIRemote.shared.press(.select)
        Thread.sleep(forTimeInterval: 1)

        // Saving returns to the category list (AddAccountView's onSaved closure) with the new
        // account now listed under "I tuoi account" — this only exists once a real
        // RemoteAccountEntity was actually created and saved.
        let accountRow = app.staticTexts["Test NAS"]
        XCTAssertTrue(accountRow.waitForExistence(timeout: 8), "L'account SMB salvato non è comparso nella lista")

        moveFocus(to: accountRow, direction: .up)
        XCUIRemote.shared.press(.select)

        // RemoteBrowserView listing the real share's contents — confirms the saved credentials
        // actually connect over the network, not just that Core Data accepted the form.
        let sawRealContent = app.staticTexts[".DS_Store"].waitForExistence(timeout: 15)
            || app.staticTexts["@Recycle"].waitForExistence(timeout: 2)
        XCTAssertTrue(sawRealContent, "Il browser dell'account SMB non ha mostrato il contenuto reale della condivisione \"Public\"")
    }
}
#endif
