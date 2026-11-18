#if os(tvOS)
import XCTest

/// End-to-end, real-network test of the "Nuovo account SMB" form entirely through the GUI:
/// fills in a real NAS, saves, and confirms the account shows up and can browse the share.
///
/// Skipped unless the environment provides a server: set `CHUNKY_SMB_HOST`, `CHUNKY_SMB_SHARE`,
/// `CHUNKY_SMB_USER` and `CHUNKY_SMB_PASSWORD` (credentials are never committed).
final class TVAddSMBAccountUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testAddingARealSMBAccountThroughTheForm() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["CHUNKY_SMB_HOST"] != nil, "Imposta CHUNKY_SMB_HOST/SHARE/USER/PASSWORD per eseguire il test SMB reale")
        let host = env["CHUNKY_SMB_HOST"] ?? ""
        let share = env["CHUNKY_SMB_SHARE"] ?? ""
        let user = env["CHUNKY_SMB_USER"] ?? ""
        let password = env["CHUNKY_SMB_PASSWORD"] ?? ""

        let app = launchPastProfilePicker()
        selectTab("Account", in: app)

        XCTAssertTrue(app.cells["Nuovo account SMB"].waitForExistence(timeout: 5))
        focusRow("Nuovo account SMB", in: app)
        XCUIRemote.shared.press(.select)

        let remote = XCUIRemote.shared
        func fill(_ label: String, _ value: String, secure: Bool = false) {
            let field = secure ? app.secureTextFields[label] : app.textFields[label]
            XCTAssertTrue(field.waitForExistence(timeout: 5), "Campo mancante: \(label)")
            moveFocus(to: field, direction: .down, maxSteps: 15, app: app)
            enterText(value, into: field, app: app)
        }

        fill("Nome", "Test NAS")
        fill("1. Indirizzo", host)
        fill("2. Condivisione", share)
        if !user.isEmpty { fill("Nome utente", user) }
        if !password.isEmpty { fill("Password", password, secure: true) }

        // "Salva" is the last element at the bottom of the form.
        let saveButton = app.buttons["Salva"]
        moveFocus(to: saveButton, direction: .down, maxSteps: 15, app: app)
        remote.press(.select)
        Thread.sleep(forTimeInterval: 1)

        XCTAssertTrue(app.staticTexts["Test NAS"].waitForExistence(timeout: 8), "L'account SMB salvato non è comparso nella lista")

        focusRow("Test NAS", in: app, direction: .up)
        remote.press(.select)

        // The browser must list something from the real share (any row) — confirms the saved
        // credentials actually connect over the network.
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 15),
                      "Il browser dell'account SMB non ha mostrato il contenuto della condivisione")
    }
}
#endif
