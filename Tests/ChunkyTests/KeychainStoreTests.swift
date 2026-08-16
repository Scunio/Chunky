import Foundation
import Testing

private let service = "com.scunio.Chunky.remoteAccounts"

/// The tests use a fake keychain: the `kSecUseDataProtectionKeychain` entitlement belongs
/// to the host process, and an unsigned test bundle doesn't have it, so the real
/// keychain isn't reachable from here. What matters and can regress is the logic —
/// writing to the modern keychain, reading with fallback to the legacy one, migration — and
/// that's exactly what these tests cover.
@Suite("Keychain", .serialized)
struct KeychainStoreTests {
    private func withFakeKeychain(_ body: (FakeKeychain) throws -> Void) rethrows {
        let fake = FakeKeychain()
        let previous = KeychainStore.backend
        KeychainStore.backend = fake
        defer { KeychainStore.backend = previous }
        try body(fake)
    }

    @Test("Salva e rilegge una password")
    func saveAndRead() {
        withFakeKeychain { _ in
            let id = UUID()
            KeychainStore.savePassword("segreta", forAccount: id)
            #expect(KeychainStore.password(forAccount: id) == "segreta")
        }
    }

    @Test("La password viene scritta nel portachiavi data-protection, non in quello storico")
    func writesToDataProtectionKeychain() {
        withFakeKeychain { fake in
            let id = UUID()
            KeychainStore.savePassword("segreta", forAccount: id)
            #expect(fake.value(service: service, account: id.uuidString, dataProtection: true) == "segreta")
            #expect(fake.value(service: service, account: id.uuidString, dataProtection: false) == nil)
        }
    }

    @Test("Salvare due volte sostituisce il valore invece di duplicarlo")
    func overwrite() {
        withFakeKeychain { _ in
            let id = UUID()
            KeychainStore.savePassword("prima", forAccount: id)
            KeychainStore.savePassword("seconda", forAccount: id)
            #expect(KeychainStore.password(forAccount: id) == "seconda")
        }
    }

    @Test("Cancellare rimuove la password da entrambi i portachiavi")
    func deleteRemovesBoth() {
        withFakeKeychain { fake in
            let id = UUID()
            fake.seedLegacy(service: service, account: id.uuidString, password: "vecchia")
            KeychainStore.savePassword("nuova", forAccount: id)
            KeychainStore.deletePassword(forAccount: id)

            #expect(KeychainStore.password(forAccount: id) == nil)
            #expect(fake.value(service: service, account: id.uuidString, dataProtection: false) == nil)
        }
    }

    @Test("Un account mai salvato restituisce nil")
    func unknownAccount() {
        withFakeKeychain { _ in
            #expect(KeychainStore.password(forAccount: UUID()) == nil)
        }
    }

    @Test("Le password non ASCII sopravvivono al round-trip")
    func unicodeRoundTrip() {
        withFakeKeychain { _ in
            let id = UUID()
            let password = "pàsswörd-日本語-🔐"
            KeychainStore.savePassword(password, forAccount: id)
            #expect(KeychainStore.password(forAccount: id) == password)
        }
    }

    /// The case of a user who updates: the password only exists in the legacy keychain.
    /// Without migration, the update would make the remote account credentials
    /// and the parental lock passcode vanish.
    @Test("Una password nel portachiavi storico viene letta e migrata")
    func migratesLegacyEntry() {
        withFakeKeychain { fake in
            let id = UUID()
            fake.seedLegacy(service: service, account: id.uuidString, password: "vecchia")

            #expect(KeychainStore.password(forAccount: id) == "vecchia")
            // After migration the value lives in the modern keychain...
            #expect(fake.value(service: service, account: id.uuidString, dataProtection: true) == "vecchia")
            // ...and no duplicate is left in the legacy one.
            #expect(fake.value(service: service, account: id.uuidString, dataProtection: false) == nil)
        }
    }

    /// If writing to the modern keychain fails, the legacy copy must remain:
    /// it's the only one the user still has.
    @Test("Una scrittura fallita non distrugge la copia storica")
    func failedWriteKeepsLegacyCopy() {
        withFakeKeychain { fake in
            let id = UUID()
            fake.seedLegacy(service: service, account: id.uuidString, password: "vecchia")
            fake.addStatusOverride = errSecMissingEntitlement

            KeychainStore.savePassword("nuova", forAccount: id)

            #expect(fake.value(service: service, account: id.uuidString, dataProtection: false) == "vecchia")
            fake.addStatusOverride = nil
            #expect(KeychainStore.password(forAccount: id) == "vecchia")
        }
    }

    @Test("La migrazione avviene una volta sola")
    func migratesOnce() {
        withFakeKeychain { fake in
            let id = UUID()
            fake.seedLegacy(service: service, account: id.uuidString, password: "vecchia")

            _ = KeychainStore.password(forAccount: id)
            let addsAfterMigration = fake.addCount
            _ = KeychainStore.password(forAccount: id)
            #expect(fake.addCount == addsAfterMigration, "la seconda lettura non deve riscrivere")
        }
    }
}
