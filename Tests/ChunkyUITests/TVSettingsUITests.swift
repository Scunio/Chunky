#if os(tvOS)
import XCTest

/// "Impostazioni" — the tab that made ColorThemeView's tvOS presets and
/// ParentalLockSettingsView reachable there for the first time.
final class TVSettingsUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testAppearancePresetsAreReachable() {
        let app = launchPastProfilePicker()
        selectTab("Impostazioni", in: app)

        XCTAssertTrue(app.staticTexts["Aspetto"].waitForExistence(timeout: 5))
        focusRow("Aspetto", in: app)
        XCUIRemote.shared.press(.select)
        // The tvOS-only preset row (ColorThemeView), not the ColorPicker/Slider section that's
        // iOS/macOS only — its absence here would mean the tvOS branch didn't compile in.
        XCTAssertTrue(app.buttons["Predefinito"].waitForExistence(timeout: 5),
                      "I preset di tema tvOS (\"Predefinito\") non sono comparsi in Aspetto")
        XCTAssertTrue(app.buttons["Seppia"].exists)
        XCTAssertTrue(app.buttons["Notte"].exists)
    }

    func testParentalLockIsReachable() {
        let app = launchPastProfilePicker()
        selectTab("Impostazioni", in: app)

        XCTAssertTrue(app.staticTexts["Blocco genitori"].waitForExistence(timeout: 5))
        focusRow("Blocco genitori", in: app)
        XCUIRemote.shared.press(.select)

        // No passcode set in a fresh UI-test container, so the "set a code" fields are what
        // should be showing — this is the branch that was 100% unreachable on tvOS before the
        // Impostazioni tab existed.
        XCTAssertTrue(app.secureTextFields["Nuovo codice"].waitForExistence(timeout: 5),
                      "Il form \"Imposta un codice\" del Blocco genitori non è comparso")
    }

    func testAutoLockPickerAfterSettingPasscode() {
        let app = launchPastProfilePicker()
        selectTab("Impostazioni", in: app)
        focusRow("Blocco genitori", in: app)
        XCUIRemote.shared.press(.select)

        let remote = XCUIRemote.shared
        let newField = app.secureTextFields["Nuovo codice"]
        XCTAssertTrue(newField.waitForExistence(timeout: 5))
        moveFocus(to: newField, direction: .down, app: app)
        enterText("1234", into: newField, app: app)
        let confirmField = app.secureTextFields["Conferma codice"]
        moveFocus(to: confirmField, direction: .down, app: app)
        enterText("1234", into: confirmField, app: app)
        moveFocus(to: app.cells["Salva codice"], direction: .down, app: app)
        remote.press(.select)
        Thread.sleep(forTimeInterval: 1.5)
        add(XCTAttachment(screenshot: app.screenshot()))

        // Passcode saved: the picker section replaces the "set a code" form.
        XCTAssertTrue(app.staticTexts["QUANDO LASCIO CHUNKY"].waitForExistence(timeout: 5),
                      "Il picker \"Quando lascio Chunky\" non è comparso dopo aver salvato il codice")
        let lockNow = app.buttons["Blocca subito"]
        let doNothing = app.buttons["Non fare nulla"]
        XCTAssertTrue(lockNow.exists && doNothing.exists)
        // tvOS default is "Blocca subito".
        XCTAssertTrue(lockNow.isSelected, "Il valore predefinito tvOS dovrebbe essere \"Blocca subito\" con il segno di spunta")
        XCTAssertFalse(doNothing.isSelected)

        moveFocus(to: app.cells["Non fare nulla"], direction: .down, app: app)
        remote.press(.select)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(doNothing.isSelected, "La selezione non è passata a \"Non fare nulla\"")
        XCTAssertFalse(lockNow.isSelected)

        // Persistence: leave the screen and come back.
        remote.press(.menu)
        Thread.sleep(forTimeInterval: 1.5)
        focusRow("Blocco genitori", in: app)
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["QUANDO LASCIO CHUNKY"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Non fare nulla"].isSelected, "La scelta non è stata mantenuta")

        // Removing the code asks for it first.
        moveFocus(to: app.cells["Rimuovi codice"], direction: .down, app: app)
        remote.press(.select)
        XCTAssertTrue(app.alerts["Rimuovere il codice?"].waitForExistence(timeout: 5)
                      || app.staticTexts["Rimuovere il codice?"].waitForExistence(timeout: 2),
                      "\"Rimuovi codice\" non ha chiesto il codice attuale")
        add(XCTAttachment(screenshot: app.screenshot()))
    }
}
#endif
