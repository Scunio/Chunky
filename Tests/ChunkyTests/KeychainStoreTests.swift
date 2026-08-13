import Foundation
import Testing

private let service = "com.scunio.Chunky.remoteAccounts"

/// I test usano un portachiavi finto: l'entitlement `kSecUseDataProtectionKeychain` appartiene
/// al processo ospite, e un bundle di test non firmato non ce l'ha, quindi il portachiavi
/// reale non è raggiungibile da qui. Ciò che conta e che può regredire è la logica —
/// scrittura nel portachiavi moderno, lettura con fallback su quello storico, migrazione — ed
/// è esattamente ciò che questi test coprono.
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

    /// Il caso dell'utente che aggiorna: la password esiste solo nel portachiavi storico.
    /// Senza migrazione, l'aggiornamento farebbe sparire le credenziali degli account
    /// remoti e il passcode del blocco genitori.
    @Test("Una password nel portachiavi storico viene letta e migrata")
    func migratesLegacyEntry() {
        withFakeKeychain { fake in
            let id = UUID()
            fake.seedLegacy(service: service, account: id.uuidString, password: "vecchia")

            #expect(KeychainStore.password(forAccount: id) == "vecchia")
            // Dopo la migrazione il valore sta nel portachiavi moderno...
            #expect(fake.value(service: service, account: id.uuidString, dataProtection: true) == "vecchia")
            // ...e non è rimasto duplicato in quello storico.
            #expect(fake.value(service: service, account: id.uuidString, dataProtection: false) == nil)
        }
    }

    /// Se la scrittura nel portachiavi moderno fallisce, la copia storica deve restare:
    /// è l'unica che l'utente ha ancora.
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
