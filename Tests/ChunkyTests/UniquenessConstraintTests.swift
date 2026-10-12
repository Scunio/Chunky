import CoreData
import Foundation
import Testing

/// Vincolo di unicità su `relativePath` (modello v3) e migrazione v2→v3.
/// La dedup resta testata su v2 (`LibraryDeduplicationTests`): è il backstop per duplicati
/// nati senza vincolo. Qui si testa che col vincolo non possano più nascere in locale e che
/// gli store sporchi preesistenti migrino senza perdere il progresso.
@Suite("Vincolo di unicità e migrazione v3")
struct UniquenessConstraintTests {
    @discardableResult
    private func makeStoredComic(
        in context: NSManagedObjectContext,
        path: String,
        page: Int32 = 0,
        opened: Date? = nil
    ) throws -> ComicEntity {
        let comic = ComicEntity.create(title: "Topolino 3620", relativePath: path, format: .cbz, in: context)
        comic.pageCount = 100
        comic.lastReadPage = page
        comic.dateLastOpened = opened
        try context.save()
        return comic
    }

    private func currentModel() throws -> NSManagedObjectModel {
        let bundle = Bundle(for: ComicEntity.self)
        let momd = try #require(bundle.url(forResource: "Chunky", withExtension: "momd"))
        return try #require(NSManagedObjectModel(contentsOf: momd))
    }

    /// Riapre `storeURL` col modello corrente (v3) con migrazione leggera, come fa l'app.
    private func openMigratedStore(at storeURL: URL) throws -> NSManagedObjectContext {
        let container = NSPersistentContainer(name: "Chunky", managedObjectModel: try currentModel())
        let description = NSPersistentStoreDescription(url: storeURL)
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        container.persistentStoreDescriptions = [description]
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }
        return container.viewContext
    }

    @Test("Il secondo record per lo stesso file viene rifiutato")
    func rejectsDuplicateRelativePath() throws {
        // SQLite, non in-memory: è lo store di produzione, e quello su cui il vincolo è garantito.
        let (context, _, cleanup) = try TestStore.makeSQLiteStore()
        defer { cleanup() }
        _ = try makeStoredComic(in: context, path: "Topolino 3620.cbz")

        _ = ComicEntity.create(title: "Doppione", relativePath: "Topolino 3620.cbz", format: .cbz, in: context)
        let saveThrew: Bool = {
            do {
                try context.save()
                return false
            } catch {
                return true
            }
        }()
        #expect(saveThrew)

        context.rollback()
        #expect(try context.fetch(ComicEntity.fetchRequest()).count == 1)
    }

    @Test("Il batch scarta l'insert in conflitto di unicità col mirror")
    func batchDropsConflictingInsert() throws {
        let (context, _, cleanup) = try TestStore.makeSQLiteStore()
        defer { cleanup() }
        _ = try makeStoredComic(in: context, path: "Topolino 3620.cbz", page: 10)
        // Il mirror registra lo stesso path mentre il batch è in analisi: l'insert resta in sospeso.
        _ = ComicEntity.create(title: "Doppione", relativePath: "Topolino 3620.cbz", format: .cbz, in: context)

        LibraryViewModel.saveBatchResolvingConflicts(in: context)

        let comics = try context.fetch(ComicEntity.fetchRequest())
        #expect(comics.count == 1)
        #expect(comics.first?.lastReadPage == 10)
    }

    @Test("Store v2 con duplicati: cleanup e migrazione v3 col progresso LWW")
    func migratesStoreWithDuplicates() throws {
        let (legacyContext, storeURL, cleanup) = try TestStore.makeSQLiteStore(modelVersion: "Chunky 2")
        defer { cleanup() }

        // Il tuo caso pre-migrazione: iPhone a 115, iPad a 10, stesso file.
        _ = try makeStoredComic(in: legacyContext, path: "Topolino 3620.cbz", page: 115, opened: Date().addingTimeInterval(-7200))
        let dup = ComicEntity.create(title: "Topolino 3620", relativePath: "Topolino 3620.cbz", format: .cbz, in: legacyContext)
        dup.pageCount = 100
        dup.lastReadPage = 10
        dup.dateLastOpened = Date()
        try legacyContext.save()

        #expect(PersistenceController.collapseDuplicatesWithLegacyModel(storeURL: storeURL))

        let context = try openMigratedStore(at: storeURL)
        let comics = try context.fetch(ComicEntity.fetchRequest())
        #expect(comics.count == 1)
        #expect(comics.first?.lastReadPage == 10)
    }

    @Test("Store v2 pulito migra a v3 senza interventi")
    func migratesCleanStore() throws {
        let (legacyContext, storeURL, cleanup) = try TestStore.makeSQLiteStore(modelVersion: "Chunky 2")
        defer { cleanup() }
        _ = try makeStoredComic(in: legacyContext, path: "Topolino 3620.cbz", page: 42)

        let context = try openMigratedStore(at: storeURL)
        let comics = try context.fetch(ComicEntity.fetchRequest())
        #expect(comics.count == 1)
        #expect(comics.first?.lastReadPage == 42)
    }

    @Test("Il cleanup è no-op su store già v3")
    func cleanupSkipsCurrentStores() throws {
        let (_, storeURL, cleanup) = try TestStore.makeSQLiteStore()
        defer { cleanup() }
        #expect(!PersistenceController.collapseDuplicatesWithLegacyModel(storeURL: storeURL))
    }
}
