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
        // Focus starts on the tab bar, not inside the list — one `.down` moves it in, landing
        // on row 1 ("Aspetto").
        XCUIRemote.shared.press(.down)
        Thread.sleep(forTimeInterval: 0.5)
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
        // Focus starts on the tab bar: first `.down` lands on row 1 ("Aspetto"), second on
        // row 2 ("Blocco genitori").
        XCUIRemote.shared.press(.down)
        Thread.sleep(forTimeInterval: 0.4)
        XCUIRemote.shared.press(.down)
        Thread.sleep(forTimeInterval: 0.4)
        XCUIRemote.shared.press(.select)

        // No passcode set in a fresh UI-test container, so the "set a code" fields are what
        // should be showing — this is the branch that was 100% unreachable on tvOS before the
        // Impostazioni tab existed.
        XCTAssertTrue(app.secureTextFields["Nuovo codice"].waitForExistence(timeout: 5),
                      "Il form \"Imposta un codice\" del Blocco genitori non è comparso")
    }
}
#endif
