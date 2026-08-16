import Foundation
import CoreData
import Testing

@Suite("Deduplica libreria")
struct LibraryDeduplicationTests {
    /// Duplicate records are born with the same `relativePath` (there's only one file on disk):
    /// that, not the title, is the criterion by which they must be recognized.
    @discardableResult
    private func makeComic(
        in context: NSManagedObjectContext,
        path: String,
        title: String = "Topolino 3620",
        id: UUID = UUID(),
        dateAdded: Date = Date(timeIntervalSince1970: 1_000),
        lastReadPage: Int32 = 0,
        cover: Data? = nil,
        favorite: Bool = false,
        dateLastOpened: Date? = nil
    ) -> ComicEntity {
        let comic = ComicEntity.create(title: title, relativePath: path, format: .cbz, in: context)
        comic.id = id
        comic.dateAdded = dateAdded
        comic.lastReadPage = lastReadPage
        comic.pageCount = 100
        comic.coverImageData = cover
        comic.isFavorite = favorite
        comic.dateLastOpened = dateLastOpened
        return comic
    }

    private func comics(in context: NSManagedObjectContext) throws -> [ComicEntity] {
        try context.fetch(ComicEntity.fetchRequest())
    }

    /// Fixed UUIDs, not random ones: the survivor is also chosen based on `id`, so the tests
    /// need to be able to say which of the two records they expect.
    private func uuid(_ string: String) throws -> UUID {
        try #require(UUID(uuidString: string))
    }

    @Test("Due record per lo stesso file diventano uno")
    func collapsesDuplicates() throws {
        let context = try TestStore.makeContext()
        makeComic(in: context, path: "Topolino 3620.cbz")
        makeComic(in: context, path: "Topolino 3620.cbz")
        try context.save()

        let collapsed = LibraryViewModel().deduplicateComics(in: context)

        #expect(collapsed == 1)
        #expect(try comics(in: context).count == 1)
    }

    @Test("File diversi non vengono toccati")
    func keepsDistinctFiles() throws {
        let context = try TestStore.makeContext()
        makeComic(in: context, path: "Topolino 3620.cbz")
        makeComic(in: context, path: "Topolino 3621.cbz")
        try context.save()

        #expect(LibraryViewModel().deduplicateComics(in: context) == 0)
        #expect(try comics(in: context).count == 2)
    }

    /// Without the merge, deduplicating would eat up the progress made on the other device:
    /// the survivor is not necessarily the one that was read the furthest.
    @Test("Il superstite eredita il progresso più avanzato e la copertina")
    func mergesProgressIntoSurvivor() throws {
        let context = try TestStore.makeContext()
        let opened = Date(timeIntervalSince1970: 90_000)
        makeComic(
            in: context,
            path: "Topolino 3620.cbz",
            id: try uuid("00000000-0000-0000-0000-000000000001"),
            lastReadPage: 3,
            cover: nil
        )
        makeComic(
            in: context,
            path: "Topolino 3620.cbz",
            id: try uuid("FFFFFFFF-0000-0000-0000-000000000002"),
            lastReadPage: 42,
            cover: Data([0x01]),
            favorite: true,
            dateLastOpened: opened
        )
        try context.save()

        LibraryViewModel().deduplicateComics(in: context)

        let survivor = try #require(try comics(in: context).first)
        #expect(survivor.lastReadPage == 42)
        #expect(survivor.coverImageData == Data([0x01]))
        #expect(survivor.isFavorite)
        #expect(survivor.dateLastOpened == opened)
    }

    /// iPad and Mac each deduplicate on their own over the same synced records: if
    /// they picked different survivors, each would delete the one the other kept, and the
    /// comic would disappear from both.
    @Test("Il superstite è lo stesso a prescindere dall'ordine di inserimento")
    func picksDeterministicSurvivor() throws {
        let older = try uuid("00000000-0000-0000-0000-0000000000AA")
        let newer = try uuid("FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")

        func survivorID(insertingNewerFirst: Bool) throws -> UUID? {
            let context = try TestStore.makeContext()
            let ids = insertingNewerFirst ? [newer, older] : [older, newer]
            for id in ids {
                makeComic(in: context, path: "Topolino 3620.cbz", id: id)
            }
            try context.save()
            LibraryViewModel().deduplicateComics(in: context)
            return try comics(in: context).first?.id
        }

        #expect(try survivorID(insertingNewerFirst: false) == older)
        #expect(try survivorID(insertingNewerFirst: true) == older)
    }

    /// This is the guard that makes `registerComic` idempotent: a file already in the library
    /// shouldn't be registered a second time.
    @Test("Un path già registrato viene riconosciuto")
    func detectsAlreadyRegisteredPath() throws {
        let context = try TestStore.makeContext()
        makeComic(in: context, path: "Topolino 3620.cbz")
        try context.save()

        let viewModel = LibraryViewModel()
        #expect(viewModel.isRegistered(relativePath: "Topolino 3620.cbz", in: context))
        #expect(!viewModel.isRegistered(relativePath: "Topolino 3621.cbz", in: context))
    }

    /// Deleting a duplicate must not take the file with it: it's the same file as its twin's,
    /// which would be left pointing at nothing and would then get removed by the next scan.
    @Test("Il file resta finché un altro record lo referenzia")
    func keepsFileWhileAnotherRecordReferencesIt() throws {
        let context = try TestStore.makeContext()
        let first = makeComic(in: context, path: "Topolino 3620.cbz")
        makeComic(in: context, path: "Topolino 3620.cbz")
        try context.save()

        let viewModel = LibraryViewModel()
        context.delete(first)
        try context.save()
        #expect(!viewModel.shouldRemoveFile(forRelativePath: "Topolino 3620.cbz", in: context))

        context.delete(try #require(try comics(in: context).first))
        try context.save()
        #expect(viewModel.shouldRemoveFile(forRelativePath: "Topolino 3620.cbz", in: context))
    }
}
