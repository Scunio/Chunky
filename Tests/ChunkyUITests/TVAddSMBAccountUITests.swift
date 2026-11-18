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
        // Initial focus on the form lands below "Nome" (e.g. on a "Trovati in rete" row when a
        // NAS is discovered), so the first field is reached upward; the rest go downward.
        func fill(_ label: String, _ value: String, secure: Bool = false, direction: XCUIRemote.Button = .down) {
            let field = secure ? app.secureTextFields[label] : app.textFields[label]
            XCTAssertTrue(field.waitForExistence(timeout: 5), "Campo mancante: \(label)")
            moveFocus(to: field, direction: direction, maxSteps: 15, app: app)
            enterText(value, into: field, app: app)
        }

        fill("Nome", "Test NAS", direction: .up)
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

        // The account row's label also carries its status ("Test NAS, Mai scansionato").
        let accountRow = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", "Test NAS")).firstMatch
        moveFocus(to: accountRow, direction: .up, app: app)
        remote.press(.select)

        // The share is known to contain a "Serie" folder — confirms the saved credentials
        // actually connect over the network and the listing is real.
        XCTAssertTrue(app.staticTexts["Serie"].waitForExistence(timeout: 20),
                      "Il browser dell'account SMB non ha mostrato la cartella \"Serie\" della condivisione")

        // Re-selecting an already-downloaded file must open the reader, not download it again
        // into a duplicate "X 1.cbz" record. Needs "Test Comic.cbz" at the root of the share.
        let comicRow = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", "Test Comic")).firstMatch
        guard comicRow.waitForExistence(timeout: 5) else { return }
        moveFocus(to: comicRow, direction: .down, app: app)
        remote.press(.select)
        let downloaded = app.images["Scaricato"]
        XCTAssertTrue(downloaded.waitForExistence(timeout: 60), "Il download non è terminato (nessun segno di spunta)")
        Thread.sleep(forTimeInterval: 1)
        remote.press(.select)
        let readerOpened = NSPredicate { _, _ in app.staticTexts["1 / 3"].exists }
        let opened = XCTNSPredicateExpectation(predicate: readerOpened, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [opened], timeout: 15), .completed, "Il lettore non si è aperto selezionando di nuovo il file scaricato")
        Thread.sleep(forTimeInterval: 2)
        remote.press(.menu)
        let closed = NSPredicate { _, _ in !app.staticTexts["1 / 3"].exists }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: closed, object: nil)], timeout: 10), .completed, "Il lettore non si è chiuso con Menu")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(comicRow.hasFocus, "Il focus non è tornato sulla riga del fumetto dopo la chiusura del lettore")

        // Exactly one library record for it (no "Test Comic 1" duplicate).
        selectTab("Libreria", in: app)
        remote.press(.down)
        Thread.sleep(forTimeInterval: 2)
        let copies = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Test Comic")).count
        XCTAssertEqual(copies, 1, "Dovrebbe esserci un solo record \"Test Comic\" in Libreria")
    }
}
#endif
