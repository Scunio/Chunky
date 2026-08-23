#if os(tvOS)
import XCTest

/// "Preferiti" — regression test for the empty-state copy bug found via screenshot earlier: a
/// non-empty library with nothing favorited showed the generic "la tua libreria è vuota / apri
/// Account" message (implying nothing was imported at all) instead of "Nessun preferito".
final class TVFavoritesUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testEmptyFavoritesShowsDedicatedMessageNotGenericEmptyLibrary() {
        // Seeded library is non-empty (14 comics) but nothing in it is favorited. Wait for the
        // grid to actually be populated on the Libreria tab first — otherwise a slow scan can
        // make Preferiti observe a still-empty `comics` fetch and show the (also technically
        // correct at that instant) generic empty-library message, a false failure unrelated to
        // the bug this test guards against.
        let app = launchPastProfilePicker(extraArguments: ["--uitesting-seed-multi"])
        XCTAssertTrue(app.buttons["uitest-grid-01"].waitForExistence(timeout: 20),
                      "La libreria non si è popolata in tempo per testare la tab Preferiti")
        selectTab("Preferiti", in: app)

        XCTAssertTrue(app.staticTexts["Nessun preferito"].waitForExistence(timeout: 5),
                      "Il messaggio dedicato \"Nessun preferito\" non è comparso")
        XCTAssertFalse(app.staticTexts["La tua libreria è vuota"].exists,
                       "È tornato il messaggio generico sbagliato (bug già corretto una volta)")
    }
}
#endif
