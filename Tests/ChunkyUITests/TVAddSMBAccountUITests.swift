#if os(tvOS)
import XCTest

/// End-to-end, real-network test of the "Nuovo account SMB" form entirely through the GUI:
/// fills in a real NAS, saves, and confirms the account shows up and can browse real share
/// content — not just that the form's fields exist.
///
/// Known flaky: whether focus lands on the form's first field automatically or stays on the
/// category row after opening it varies between runs (confirmed both ways on the same build) —
/// a real timing race in tvOS's focus engine during the push transition, not something this
/// test can fully paper over with fixed delays. Confirmed working end-to-end at least once.
final class TVAddSMBAccountUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testAddingARealSMBAccountThroughTheForm() {
        let app = launchPastProfilePicker()
        selectTab("Account", in: app)

        let smbRow = app.buttons["Nuovo account SMB"]
        XCTAssertTrue(smbRow.waitForExistence(timeout: 5))

        // Each successful run of this test leaves its own "Test NAS" account behind (no
        // dedup/cleanup), which pushes every row below it down by one — count how many are
        // already there so the fixed press counts below still land correctly.
        let existingAccounts = app.staticTexts.matching(identifier: "Test NAS").count

        // `hasFocus` on a List-embedded Button is unreliable — fixed press count instead.
        let remote = XCUIRemote.shared
        for _ in 0..<(5 + existingAccounts) {
            remote.press(.down)
            Thread.sleep(forTimeInterval: 0.5)
        }
        remote.press(.select)

        let nameField = app.textFields["Nome account"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "Il form SMB non è comparso")
        // Whether focus lands on the first field by itself or stays on the category row varies
        // run to run — this nudge right is a best-effort, not a guaranteed fix; see the type's
        // doc comment.
        Thread.sleep(forTimeInterval: 0.8)
        remote.press(.right)
        Thread.sleep(forTimeInterval: 0.8)
        enterText("Test NAS", into: nameField, app: app)

        // `hasFocus` polling is unreliable here too, and the field order isn't 1:1 with the
        // form's visual rows (Porta/Workgroup/Endpoint/"Test di velocità" sit between
        // Condivisione and Nome utente) — fixed press counts read straight from
        // AddAccountView's field order instead.
        func downOnce() {
            remote.press(.down)
            Thread.sleep(forTimeInterval: 0.4)
        }

        let hostField = app.textFields["Indirizzo"]
        downOnce()
        enterText("NAS07BE7B.local", into: hostField, app: app)

        let shareField = app.textFields["Condivisione"]
        downOnce()
        enterText("Public", into: shareField, app: app)

        // Porta, Workgroup, Modifica Endpoint, "Test di velocità" — skipped, left at defaults.
        for _ in 0..<5 { downOnce() }

        let usernameField = app.textFields["Nome utente"]
        enterText("Lorenzo", into: usernameField, app: app)

        let passwordField = app.secureTextFields["Password"]
        downOnce()
        enterText("Lorenzo98", into: passwordField, app: app)

        // "Salva" lives in the toolbar above the form, not as a list row — reachable by going
        // up past the top of the list, not down past the bottom.
        let saveButton = app.buttons["Salva"]
        moveFocus(to: saveButton, direction: .up, maxSteps: 15, app: app)
        XCUIRemote.shared.press(.select)
        Thread.sleep(forTimeInterval: 1)

        // Saving returns to the category list (AddAccountView's onSaved closure) with the new
        // account now listed under "I tuoi account" — this only exists once a real
        // RemoteAccountEntity was actually created and saved.
        let accountRow = app.staticTexts["Test NAS"]
        XCTAssertTrue(accountRow.waitForExistence(timeout: 8), "L'account SMB salvato non è comparso nella lista")

        // Focus is still on "Nuovo account SMB"; the first "Test NAS" row is 3 rows above it
        // regardless of how many duplicates trail after it.
        for _ in 0..<3 {
            remote.press(.up)
            Thread.sleep(forTimeInterval: 0.4)
        }
        remote.press(.select)

        // RemoteBrowserView listing the real share's contents — confirms the saved credentials
        // actually connect over the network, not just that Core Data accepted the form.
        let sawRealContent = app.staticTexts[".DS_Store"].waitForExistence(timeout: 15)
            || app.staticTexts["@Recycle"].waitForExistence(timeout: 2)
        XCTAssertTrue(sawRealContent, "Il browser dell'account SMB non ha mostrato il contenuto reale della condivisione \"Public\"")
    }
}
#endif
