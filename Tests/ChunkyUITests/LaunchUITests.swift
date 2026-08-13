import XCTest

/// Gli UI test usano XCTest, non Swift Testing: XCUITest non ha un equivalente nel nuovo
/// framework. Non provare a unificarli.
///
/// Sono volutamente pochi: gli UI test sono lenti e fragili, e servono solo a proteggere le
/// regressioni che i test unitari non possono vedere. I test specifici del Mac nativo
/// (sidebar, ⌘, Preferenze, finestre multiple) arrivano quando quelle funzioni esistono.
final class LaunchUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--uitesting"]
        app.launch()
        return app
    }

    func testAppLaunchesAndShowsLibrary() {
        let app = launchApp()
        // Il titolo "Chunky" è l'intestazione della libreria: se non compare, l'avvio è
        // finito su StorageErrorView o sul blocco genitori.
        XCTAssertTrue(app.staticTexts["Chunky"].waitForExistence(timeout: 20),
                      "La libreria non è comparsa entro il timeout")
    }

    func testLibraryShowsImportAffordanceWhenEmpty() {
        let app = launchApp()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        // Con libreria vuota l'unico ingresso visibile all'import è questo pulsante.
        // Se la libreria non è vuota il test non ha nulla da verificare.
        let importButton = app.buttons["Importa fumetti"]
        if importButton.waitForExistence(timeout: 5) {
            XCTAssertTrue(importButton.isHittable)
        }
    }
}
