import Foundation
import CoreData
import Testing

@Suite("Deduplica libreria")
struct LibraryDeduplicationTests {
    /// I record duplicati nascono con lo stesso `relativePath` (il file su disco è uno solo):
    /// è quello, non il titolo, il criterio con cui vanno riconosciuti.
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

    /// UUID fissi, non casuali: il superstite si sceglie anche in base all'`id`, quindi i test
    /// devono poter dire quale dei due record si aspettano.
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

    /// Senza la fusione, deduplicare si mangerebbe il progresso fatto sull'altro dispositivo:
    /// il superstite non è necessariamente quello con cui si è letto di più.
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

    /// iPad e Mac deduplicano ciascuno per conto proprio sugli stessi record sincronizzati: se
    /// scegliessero superstiti diversi, ognuno cancellerebbe quello tenuto dall'altro e il
    /// fumetto sparirebbe da entrambi.
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

    /// È il guard che rende `registerComic` idempotente: un file già in libreria non va
    /// registrato una seconda volta.
    @Test("Un path già registrato viene riconosciuto")
    func detectsAlreadyRegisteredPath() throws {
        let context = try TestStore.makeContext()
        makeComic(in: context, path: "Topolino 3620.cbz")
        try context.save()

        let viewModel = LibraryViewModel()
        #expect(viewModel.isRegistered(relativePath: "Topolino 3620.cbz", in: context))
        #expect(!viewModel.isRegistered(relativePath: "Topolino 3621.cbz", in: context))
    }

    /// Cancellare un duplicato non deve portarsi via il file: è lo stesso del gemello, che
    /// resterebbe a puntare nel vuoto e verrebbe poi rimosso dalla scansione successiva.
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
