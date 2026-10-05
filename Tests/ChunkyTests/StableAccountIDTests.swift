import CoreData
import Foundation
import Testing
// Niente `@testable import Chunky`: i test compilano i sorgenti direttamente
// nello stesso modulo (vedi template `ChunkyUnitTest` in project.yml).

/// L'`id` è opzionale nel modello e gli account creati prima della sua introduzione
/// ce l'hanno a nil: senza backfill ogni accesso al Keychain userebbe un UUID diverso
/// e la password sembrerebbe sempre "sbiancata" (salvataggio e lettura non si
/// incontrano mai). Questi test coprono backfill, stabilità e round-trip.
@Suite("ID stabile degli account remoti")
struct StableAccountIDTests {
    private func withFakeKeychain(_ body: (FakeKeychain) throws -> Void) rethrows {
        let fake = FakeKeychain()
        let previous = KeychainStore.backend
        KeychainStore.backend = fake
        defer { KeychainStore.backend = previous }
        try body(fake)
    }

    /// Simula un account storico: creato senza passare da `create(...)`, quindi con `id` nil.
    private func legacyAccount(in context: NSManagedObjectContext) -> RemoteAccountEntity {
        let account = RemoteAccountEntity(context: context)
        account.name = "NAS"
        account.serverURLString = "smb://192.168.1.10"
        return account
    }

    @Test("Il backfill assegna e persiste un id agli account che ne sono privi")
    func backfillAssignsMissingIDs() throws {
        let context = try TestStore.makeContext()
        let account = legacyAccount(in: context)
        #expect(account.id == nil)
        try context.save()

        RemoteAccountEntity.backfillMissingIDs(in: context)
        #expect(account.id != nil)

        // Persistito: un fetch fresco lo ritrova con lo stesso id.
        let request = RemoteAccountEntity.fetchRequest()
        let fetched = try context.fetch(request)
        #expect(fetched.count == 1)
        #expect(fetched.first?.id == account.id)
    }

    @Test("Il backfill non tocca gli account che hanno già un id")
    func backfillLeavesExistingIDsAlone() throws {
        let context = try TestStore.makeContext()
        let account = RemoteAccountEntity.create(
            kind: .smb,
            name: "NAS",
            serverURLString: "smb://192.168.1.10",
            username: nil,
            password: nil,
            in: context
        )
        let original = try #require(account.id)
        try context.save()

        RemoteAccountEntity.backfillMissingIDs(in: context)
        #expect(account.id == original)
    }

    @Test("stableID restituisce sempre lo stesso valore")
    func stableIDIsStable() throws {
        let context = try TestStore.makeContext()
        let account = legacyAccount(in: context)
        #expect(account.stableID == account.stableID)
    }

    @Test("La password di un account senza id sopravvive al round-trip")
    func passwordRoundTripWithoutID() throws {
        try withFakeKeychain { _ in
            let context = try TestStore.makeContext()
            let account = legacyAccount(in: context)
            try context.save()

            account.password = "segreta"
            #expect(account.password == "segreta")

            // Scarica la persistenza accodata da `stableID` (su thread non-main il save
            // è `perform` async): così il refetch sotto è deterministico.
            context.performAndWait { try? context.save() }

            // Anche dopo un refetch (altro oggetto, stessa riga): la chiave è stabile.
            context.refreshAllObjects()
            let request = RemoteAccountEntity.fetchRequest()
            let fetched = try #require(try context.fetch(request).first)
            #expect(fetched.password == "segreta")
        }
    }
}
