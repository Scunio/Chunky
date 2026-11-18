#if os(tvOS)
import XCTest

/// After the parental-lock screen is dismissed while the reader is open, the remote must still
/// drive the reader (page turns), not fall through to the system.
final class TVParentalLockFocusUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testReaderKeepsFocusAfterUnlock() {
        let app = launchPastProfilePicker(extraArguments: ["--uitesting-seed-multi"])
        let remote = XCUIRemote.shared

        // Set a passcode (default auto-lock: "Blocca subito").
        selectTab("Impostazioni", in: app)
        focusRow("Blocco genitori", in: app)
        remote.press(.select)
        let newField = app.secureTextFields["Nuovo codice"]
        XCTAssertTrue(newField.waitForExistence(timeout: 5))
        moveFocus(to: newField, direction: .down, app: app)
        enterText("1234", into: newField, app: app)
        let confirmField = app.secureTextFields["Conferma codice"]
        moveFocus(to: confirmField, direction: .down, app: app)
        enterText("1234", into: confirmField, app: app)
        moveFocus(to: app.cells["Salva codice"], direction: .down, app: app)
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["QUANDO LASCIO CHUNKY"].waitForExistence(timeout: 5))
        remote.press(.menu)
        Thread.sleep(forTimeInterval: 1.5)

        // Open a comic in the reader.
        selectTab("Libreria", in: app)
        XCTAssertTrue(app.buttons["uitest-grid-01"].waitForExistence(timeout: 20))
        remote.press(.down)
        Thread.sleep(forTimeInterval: 0.5)
        remote.press(.select)
        let read = app.buttons["comicDetail.primaryAction"]
        XCTAssertTrue(read.waitForExistence(timeout: 5))
        remote.press(.select)
        let firstPage = NSPredicate(format: "label BEGINSWITH %@", "1 /")
        XCTAssertTrue(app.staticTexts.matching(firstPage).firstMatch.waitForExistence(timeout: 10), "Il lettore non si è aperto")

        // Control: with no lock cycle yet, Right must turn the page.
        Thread.sleep(forTimeInterval: 5)
        let control0 = app.screenshot().pngRepresentation
        remote.press(.right)
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertNotEqual(control0, app.screenshot().pngRepresentation, "Controllo: Destra non gira pagina neanche senza blocco")
        remote.press(.left)
        Thread.sleep(forTimeInterval: 1)

        for round in 1...3 {
            for useButton in [false, true] {
                // Back to page 1 state is not needed: just check the page label changes.
                XCUIDevice.shared.press(.home)
                Thread.sleep(forTimeInterval: 2)
                app.activate()
                let field = app.secureTextFields["Codice"]
                XCTAssertTrue(field.waitForExistence(timeout: 10), "Schermata di blocco assente (round \(round))")
                Thread.sleep(forTimeInterval: 1)
                if !field.hasFocus { moveFocus(to: field, direction: .up, app: app) }
                remote.press(.select)
                Thread.sleep(forTimeInterval: 1.5)
                if useButton {
                    app.typeText("1234")
                    Thread.sleep(forTimeInterval: 1)
                    remote.press(.menu)
                    Thread.sleep(forTimeInterval: 1.5)
                    moveFocus(to: app.buttons["Sblocca"], direction: .down, app: app)
                    remote.press(.select)
                } else {
                    app.typeText("1234")
                    Thread.sleep(forTimeInterval: 1)
                    remote.press(.down)
                    Thread.sleep(forTimeInterval: 1)
                    remote.press(.select)
                }
                Thread.sleep(forTimeInterval: 3)
                XCTAssertFalse(app.secureTextFields["Codice"].exists, "Ancora bloccata (round \(round), button \(useButton))")
                if app.buttons["Annulla"].exists {
                    moveFocus(to: app.buttons["Annulla"], direction: .left, app: app)
                    remote.press(.select)
                    Thread.sleep(forTimeInterval: 1)
                }
                // Let the reader chrome auto-hide so the only visual change left is the page turn.
                Thread.sleep(forTimeInterval: 5)
                let before = app.screenshot().pngRepresentation
                remote.press(.right)
                Thread.sleep(forTimeInterval: 1.5)
                let after = app.screenshot().pngRepresentation
                XCTAssertNotEqual(before, after, "Il lettore non risponde dopo lo sblocco (round \(round), button \(useButton))")
                // Past the last page Right opens "Fine del fumetto" — still proof the pager answered.
                if app.buttons["Annulla"].exists {
                    moveFocus(to: app.buttons["Annulla"], direction: .left, app: app)
                    remote.press(.select)
                } else {
                    remote.press(.left)
                }
                Thread.sleep(forTimeInterval: 1)
            }
        }
    }
}
#endif
