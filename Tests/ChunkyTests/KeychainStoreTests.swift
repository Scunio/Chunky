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

    @Test("La password viene scritta nel portachiavi semplice, non in quello moderno")
    func writesToPlainKeychain() {
        withFakeKeychain { fake in
            let id = UUID()
            KeychainStore.savePassword("segreta", forAccount: id)
            #expect(fake.value(service: service, account: id.uuidString, dataProtection: false) == "segreta")
            #expect(fake.value(service: service, account: id.uuidString, dataProtection: true) == nil)
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

    /// Il caso di chi aggiorna: la password esiste solo nel portachiavi moderno
    /// (vecchie build). Senza migrazione, credenziali e codice parentale sparirebbero.
    @Test("Una password nel portachiavi moderno viene letta e migrata nel semplice")
    func migratesModernEntry() {
        withFakeKeychain { fake in
            let id = UUID()
            fake.seedModern(service: service, account: id.uuidString, password: "vecchia")

            #expect(KeychainStore.password(forAccount: id) == "vecchia")
            // After migration the value lives in the plain keychain...
            #expect(fake.value(service: service, account: id.uuidString, dataProtection: false) == "vecchia")
            // ...and no duplicate is left in the modern one.
            #expect(fake.value(service: service, account: id.uuidString, dataProtection: true) == nil)
        }
    }

    /// If writing fails, the modern copy must remain: it's the only one the user has.
    @Test("Una scrittura fallita non distrugge la copia moderna")
    func failedWriteKeepsModernCopy() {
        withFakeKeychain { fake in
            let id = UUID()
            fake.seedModern(service: service, account: id.uuidString, password: "vecchia")
            fake.addStatusOverride = errSecMissingEntitlement

            KeychainStore.savePassword("nuova", forAccount: id)

            #expect(fake.value(service: service, account: id.uuidString, dataProtection: true) == "vecchia")
            fake.addStatusOverride = nil
            #expect(KeychainStore.password(forAccount: id) == "vecchia")
        }
    }

    /// Se la riscrittura fallisce, la password semplice esistente deve restare.
    @Test("Una riscrittura fallita non distrugge la password esistente")
    func failedOverwriteKeepsPlainCopy() {
        withFakeKeychain { fake in
            let id = UUID()
            fake.seedLegacy(service: service, account: id.uuidString, password: "buona")
            fake.addStatusOverride = errSecMissingEntitlement

            KeychainStore.savePassword("nuova", forAccount: id)

            fake.addStatusOverride = nil
            #expect(KeychainStore.password(forAccount: id) == "buona")
        }
    }

    @Test("Se il semplice non è verificabile, ripiega sul moderno e la password si rilegge")
    func fallsBackToModernWhenPlainUnverifiable() {
        withFakeKeychain { fake in
            fake.plainWriteBlackhole = true // add ok, read vuota
            let id = UUID()
            let status = KeychainStore.savePassword("Lorenzo98", forAccount: id)
            #expect(status == errSecSuccess)
            #expect(KeychainStore.password(forAccount: id) == "Lorenzo98")
            #expect(fake.value(service: service, account: id.uuidString, dataProtection: true) == "Lorenzo98")
        }
    }

    @Test("Se il semplice rifiuta la scrittura, ripiega sul moderno")
    func fallsBackToModernWhenPlainAddFails() {
        withFakeKeychain { fake in
            fake.plainAddStatusOverride = errSecMissingEntitlement
            let id = UUID()
            let status = KeychainStore.savePassword("segreta", forAccount: id)
            #expect(status == errSecSuccess)
            #expect(KeychainStore.password(forAccount: id) == "segreta")
        }
    }

    @Test("La migrazione avviene una volta sola")    func migratesOnce() {
        withFakeKeychain { fake in
            let id = UUID()
            fake.seedModern(service: service, account: id.uuidString, password: "vecchia")

            _ = KeychainStore.password(forAccount: id)
            let addsAfterMigration = fake.addCount
            _ = KeychainStore.password(forAccount: id)
            #expect(fake.addCount == addsAfterMigration, "la seconda lettura non deve riscrivere")
        }
    }
}
