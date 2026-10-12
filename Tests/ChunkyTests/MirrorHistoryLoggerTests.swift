import CoreData
import Foundation
import Testing

/// Il logger di history del mirror: baseline al primo giro, riepilogo dopo,
/// senza mai cancellare le transazioni (servono a CloudKit).
@Suite("Log della history del mirror")
struct MirrorHistoryLoggerTests {
    private func cleanBaseline() {
        UserDefaults.standard.removeObject(forKey: "mirrorHistoryLogDate")
    }

    @Test("Primo giro: baseline silenziosa, secondo: consuma senza cancellare")
    func baselineThenConsume() throws {
        cleanBaseline()
        defer { cleanBaseline() }
        let (context, cleanup) = try TestStore.makeSQLiteContext(historyTracking: true)
        defer { cleanup() }

        let comic = ComicEntity.create(
            title: "Topolino", relativePath: "topolino.cbz", format: .cbz, in: context
        )
        comic.lastReadPage = 10
        try context.save()

        // Primo giro: fissa la baseline, non deve restare niente da consumare dopo.
        context.performAndWait { MirrorHistoryLogger.logNewTransactions(in: context) }
        let baseline = try #require(MirrorHistoryLogger.storedBaselineDate())

        // Nessuna transazione pendente oltre la baseline.
        let drain = NSPersistentHistoryChangeRequest.fetchHistory(after: baseline)
        let drained = try context.execute(drain) as? NSPersistentHistoryResult
        let remaining = drained?.result as? [NSPersistentHistoryTransaction] ?? []
        #expect(remaining.isEmpty)

        // La history resta lì (non cancellata): il mirror ne ha ancora bisogno.
        let everything = NSPersistentHistoryChangeRequest.fetchHistory(after: .distantPast)
        let all = try context.execute(everything) as? NSPersistentHistoryResult
        let transactions = all?.result as? [NSPersistentHistoryTransaction] ?? []
        #expect(!transactions.isEmpty)
    }
}
