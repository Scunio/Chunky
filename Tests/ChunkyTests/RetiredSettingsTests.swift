import Foundation
import Testing
// Niente `@testable import Chunky`: i test compilano i sorgenti direttamente
// nello stesso modulo (vedi template `ChunkyUnitTest` in project.yml).

/// Le impostazioni tolte non devono restare a comandare il comportamento senza un controllo
/// per cambiarle, e chi usava "Modalità una mano" deve ritrovarla in "Avanza al tocco sui bordi".
struct RetiredSettingsTests {
    private func makeDefaults() throws -> UserDefaults {
        let name = "RetiredSettingsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func oneHandedModeCarriesOverToTapToAdvance() throws {
        let defaults = try makeDefaults()
        defaults.set(true, forKey: "oneHandedMode")
        RetiredSettings.clean(defaults)
        #expect(defaults.bool(forKey: "tapToPanEnabled"))
        #expect(defaults.object(forKey: "oneHandedMode") == nil)
    }

    @Test func tapToAdvanceIsLeftAloneWithoutOneHandedMode() throws {
        let defaults = try makeDefaults()
        defaults.set(false, forKey: "oneHandedMode")
        RetiredSettings.clean(defaults)
        #expect(defaults.object(forKey: "tapToPanEnabled") == nil)
    }

    @Test func removedKeysAreCleared() throws {
        let defaults = try makeDefaults()
        for key in RetiredSettings.removedKeys {
            defaults.set(true, forKey: key)
        }
        defaults.set(true, forKey: "autoCropEnabled")
        RetiredSettings.clean(defaults)
        for key in RetiredSettings.removedKeys {
            #expect(defaults.object(forKey: key) == nil)
        }
        // Settings that still exist are untouched.
        #expect(defaults.bool(forKey: "autoCropEnabled"))
    }
}
