import CoreData
import Foundation
import Testing
// Niente `@testable import Chunky`: i test compilano i sorgenti direttamente
// nello stesso modulo (vedi template `ChunkyUnitTest` in project.yml).

@Suite("Stato scansione account")
struct RemoteAccountStatusTests {
    @Test("Il modello traccia l'ultimo errore di scansione")
    func modelTracksLastScanError() throws {
        let context = try TestStore.makeContext()
        let account = RemoteAccountEntity.create(
            kind: .opds,
            name: "Test",
            serverURLString: "http://192.168.1.10:8080/opds",
            username: nil,
            password: nil,
            in: context
        )
        #expect(account.lastScanError == nil)
        account.lastScanError = "Connessione bloccata dal sistema."
        try context.save()

        let request = RemoteAccountEntity.fetchRequest()
        request.predicate = NSPredicate(format: "name == %@", "Test")
        let fetched = try context.fetch(request)
        #expect(fetched.first?.lastScanError == "Connessione bloccata dal sistema.")
    }
}
