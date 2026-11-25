import CoreData
import Foundation
import Testing
// Niente `@testable import Chunky`: i test compilano i sorgenti direttamente
// nello stesso modulo (vedi template `ChunkyUnitTest` in project.yml).

/// Un fumetto scaricato da un account poi eliminato, con il file nella radice iCloud (versioni
/// vecchie): gli altri dispositivi lo conoscono come fumetto iCloud, qui restava legato a un
/// account che non c'è più. `adoptOrphanedRootDownloads` lo porta nella libreria iCloud.
@Suite("Adozione dei download di account eliminati")
struct OrphanAdoptionTests {
    private let path = "Topolino 3618 (2025-03-26).cbr"

    private func accountComic(accountID: UUID, page: Int32, openedAt: Date?, in context: NSManagedObjectContext) -> ComicEntity {
        let comic = ComicEntity.create(
            title: "Topolino 3618 (2025-03-26)",
            relativePath: path,
            format: .cbr,
            sourceAccountID: accountID,
            sourceRelativePath: "smb://nas.local/Fumetti/\(path)",
            in: context
        )
        comic.pageCount = 164
        comic.lastReadPage = page
        comic.dateLastOpened = openedAt
        comic.isFavorite = true
        return comic
    }

    private func libraryComic(page: Int32, openedAt: Date?, in context: NSManagedObjectContext) -> ComicEntity {
        let comic = ComicEntity.create(title: "Topolino 3618 (2025-03-26)", relativePath: path, format: .cbr, in: context)
        comic.pageCount = 164
        comic.lastReadPage = page
        comic.dateLastOpened = openedAt
        return comic
    }

    /// Only this comic's rows: other suites run in parallel and may drop files in the shared
    /// test library root, which nothing here should depend on.
    private func comics(in context: NSManagedObjectContext) throws -> [ComicEntity] {
        let request = ComicEntity.fetchRequest()
        request.predicate = NSPredicate(format: "relativePath == %@", path)
        return try context.fetch(request)
    }

    private func isLocalOnly(_ comic: ComicEntity) -> Bool {
        comic.objectID.persistentStore?.configurationName == PersistenceController.localOnlyConfigurationName
    }

    @Test("Con un fumetto iCloud gemello si fondono e vince la lettura più recente")
    func mergesIntoExistingLibraryRow() throws {
        let context = try TestStore.makeContext()
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)
        _ = libraryComic(page: 10, openedAt: older, in: context)
        _ = accountComic(accountID: UUID(), page: 75, openedAt: newer, in: context)
        try context.save()

        let adopted = ComicEntity.adoptOrphanedRootDownloads(in: context, isLegacyRootDownload: { _, _ in true })
        try context.save()

        #expect(adopted == 1)
        let rows = try comics(in: context)
        #expect(rows.count == 1, "righe: \(rows.map { "\($0.relativePath ?? "-")|\($0.sourceAccountID?.uuidString ?? "nil")|\($0.title ?? "")" })")
        let survivor = try #require(rows.first)
        #expect(survivor.sourceAccountID == nil)
        #expect(survivor.lastReadPage == 75)
        #expect(survivor.dateLastOpened == newer)
        #expect(survivor.isFavorite)
        #expect(!isLocalOnly(survivor))
    }

    @Test("Senza gemello diventa un fumetto iCloud con gli stessi dati")
    func createsLibraryRowWhenMissing() throws {
        let context = try TestStore.makeContext()
        let opened = Date(timeIntervalSince1970: 3_000)
        let orphan = accountComic(accountID: UUID(), page: 43, openedAt: opened, in: context)
        let added = Date(timeIntervalSince1970: 500)
        orphan.dateAdded = added
        try context.save()

        ComicEntity.adoptOrphanedRootDownloads(in: context, isLegacyRootDownload: { _, _ in true })
        try context.save()

        let rows = try comics(in: context)
        #expect(rows.count == 1)
        let comic = try #require(rows.first)
        #expect(comic.sourceAccountID == nil)
        #expect(comic.relativePath == path)
        #expect(comic.lastReadPage == 43)
        #expect(comic.pageCount == 164)
        #expect(comic.dateLastOpened == opened)
        #expect(comic.dateAdded == added)
        #expect(comic.isFavorite)
        #expect(!isLocalOnly(comic))
    }

    @Test("Con l'account ancora presente non tocca nulla")
    func keepsRowsOfLiveAccounts() throws {
        let context = try TestStore.makeContext()
        let accountID = UUID()
        let account = try #require(NSEntityDescription.insertNewObject(forEntityName: "RemoteAccountEntity", into: context) as? RemoteAccountEntity)
        account.id = accountID
        account.name = "NAS"
        account.serverURLString = "smb://nas.local"
        _ = accountComic(accountID: accountID, page: 5, openedAt: nil, in: context)
        try context.save()

        let adopted = ComicEntity.adoptOrphanedRootDownloads(in: context, isLegacyRootDownload: { _, _ in true })
        #expect(adopted == 0)
        #expect(try comics(in: context).first?.sourceAccountID == accountID)
    }

    @Test("Una copia nella cache privata non viene adottata")
    func keepsRemoteCacheCopies() throws {
        let context = try TestStore.makeContext()
        let accountID = UUID()
        _ = accountComic(accountID: accountID, page: 5, openedAt: nil, in: context)
        try context.save()

        let adopted = ComicEntity.adoptOrphanedRootDownloads(in: context, isLegacyRootDownload: { _, _ in false })
        #expect(adopted == 0)
        #expect(try comics(in: context).first?.sourceAccountID == accountID)
    }

    @Test("I segnaposto mai scaricati restano a deletePlaceholdersWithMissingAccount")
    func ignoresPlaceholders() throws {
        let context = try TestStore.makeContext()
        let placeholder = accountComic(accountID: UUID(), page: 0, openedAt: nil, in: context)
        placeholder.isRemotePlaceholder = true
        try context.save()

        let adopted = ComicEntity.adoptOrphanedRootDownloads(in: context, isLegacyRootDownload: { _, _ in true })
        #expect(adopted == 0)
        #expect(try comics(in: context).first?.isRemotePlaceholder == true)
    }
}
