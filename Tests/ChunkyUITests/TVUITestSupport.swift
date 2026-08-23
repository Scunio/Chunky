#if os(tvOS)
import XCTest

/// Shared launch/navigation helpers for tvOS UI tests. Centralizes the profile-picker dismissal
/// (see `launchPastProfilePicker`) so every test benefits from the fix instead of each one
/// reinventing its own retry loop.
extension XCTestCase {
    /// Launches Chunky and waits for the "Libreria" tab, steering past tvOS's system profile
    /// picker if it's showing. `.tap()` doesn't exist on tvOS, so this focuses the element and
    /// presses select instead of guessing blindly. Fails the test if the tab bar never appears.
    @discardableResult
    func launchPastProfilePicker(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--uitesting"] + extraArguments
        app.launch()

        let remote = XCUIRemote.shared
        _ = app.wait(for: .runningForeground, timeout: 20)

        var sawLibreria = false
        for _ in 0..<30 {
            if app.buttons["Libreria"].waitForExistence(timeout: 1.5) {
                sawLibreria = true
                break
            }
            let lorenzoProfile = app.buttons["Lorenzo"]
            if lorenzoProfile.waitForExistence(timeout: 1) {
                // "Lorenzo" is leftmost of the profile items; steer left first (no-op if already there).
                if !lorenzoProfile.hasFocus {
                    remote.press(.left)
                    Thread.sleep(forTimeInterval: 0.3)
                    remote.press(.left)
                    Thread.sleep(forTimeInterval: 0.3)
                }
                remote.press(.select)
            } else {
                remote.press(.select)
            }
            Thread.sleep(forTimeInterval: 1.5)
        }
        XCTAssertTrue(sawLibreria, "La tab bar di Chunky non è comparsa: bloccati sulla schermata profilo di sistema o su un crash al lancio.")
        Thread.sleep(forTimeInterval: 0.5)
        return app
    }

    /// Steers the remote in `direction` until `element` reports focus, instead of counting
    /// presses blindly (which breaks the moment a list gains/loses a row, e.g. an "I tuoi
    /// account" section appearing once a real account exists). Fails the test if `element`
    /// never gains focus within `maxSteps`.
    @discardableResult
    func moveFocus(to element: XCUIElement, direction: XCUIRemote.Button, maxSteps: Int = 12,
                    app: XCUIApplication? = nil, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let remote = XCUIRemote.shared
        for _ in 0..<maxSteps {
            if element.exists && element.hasFocus { return true }
            remote.press(direction)
            Thread.sleep(forTimeInterval: 0.4)
        }
        let reached = element.exists && element.hasFocus
        if !reached, let app {
            let attachment = XCTAttachment(string: app.debugDescription)
            attachment.name = "hierarchy-at-focus-failure"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertTrue(reached, "Non sono riuscito a spostare il focus sull'elemento entro \(maxSteps) passi", file: file, line: line)
        return reached
    }

    /// Types `text` into `field`: selects it (opening tvOS's full-screen text-entry keyboard),
    /// types, then confirms with the keyboard's own Done/Return via `.select` after a settle
    /// delay — the keyboard sheet needs a moment to actually appear before typing lands in it.
    func enterText(_ text: String, into field: XCUIElement, app: XCUIApplication) {
        let remote = XCUIRemote.shared
        remote.press(.select)
        Thread.sleep(forTimeInterval: 1)
        field.typeText(text)
        Thread.sleep(forTimeInterval: 0.5)
        remote.press(.select)
        Thread.sleep(forTimeInterval: 0.8)
    }

    /// Moves the tab bar's selection to `tabLabel` by pressing right/left from wherever it
    /// currently is — reads the actual focused tab first instead of assuming a starting position,
    /// so tests can call this in any order. Fails the test if `tabLabel` isn't a real tab.
    func selectTab(_ tabLabel: String, in app: XCUIApplication) {
        let order = ["Libreria", "In lettura", "Preferiti", "Account", "Impostazioni"]
        guard let targetIndex = order.firstIndex(of: tabLabel) else {
            XCTFail("Tab sconosciuta: \(tabLabel)")
            return
        }
        let remote = XCUIRemote.shared
        // Find which tab is currently focused by checking each in turn — cheap (5 elements)
        // and avoids assuming the bar starts on "Libreria" (true right after launch, not
        // necessarily true mid-test).
        let currentIndex = order.firstIndex { app.buttons[$0].exists && app.buttons[$0].hasFocus } ?? 0
        let delta = targetIndex - currentIndex
        let direction: XCUIRemote.Button = delta > 0 ? .right : .left
        for _ in 0..<abs(delta) {
            remote.press(direction)
            Thread.sleep(forTimeInterval: 0.4)
        }
        Thread.sleep(forTimeInterval: 0.8)
    }
}
#endif
