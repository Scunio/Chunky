import Foundation
import CoreData
import Testing

@Suite("Raggruppamento della libreria")
struct LibraryGroupingTests {
    /// I titoli veri di una libreria di Topolino: alcuni puliti, altri con le decorazioni che i
    /// rilasci scansionati appendono dopo il numero.
    private static let titles = [
        "Topolino 3651",
        "Topolino 3636 + Cover Abbonati",
        "Topolino 3652 (Panini 2025-11-19) [c2c CPPT Edition] 1.0",
        "Topolino 3657 (Panini 2025-12-24) [c2c CPPT Edition] 1.0"
    ]

    private func makeLibrary(in context: NSManagedObjectContext) {
        for title in Self.titles {
            let comic = ComicEntity.create(title: title, relativePath: "\(title).cbz", format: .cbz, in: context)
            comic.seriesName = LibraryViewModel.deriveSeriesName(fromFallbackTitle: title)
        }
    }

    @Test("I titoli decorati finiscono nella stessa sezione di quelli puliti")
    func groupsDecoratedTitlesWithTheRest() throws {
        let context = try TestStore.makeContext()
        makeLibrary(in: context)

        let sections = LibraryGrouping.sections(for: try context.fetch(ComicEntity.fetchRequest()))
        #expect(sections.count == 1)
        #expect(sections.first?.title == "Topolino")
        #expect(sections.first?.comics.count == Self.titles.count)
    }

    @Test("L'header mostra l'intervallo anche con i titoli decorati")
    func headerShowsIssueRange() throws {
        let context = try TestStore.makeContext()
        makeLibrary(in: context)

        let comics = try context.fetch(ComicEntity.fetchRequest())
        #expect(LibraryGrouping.headerText(title: "Topolino", comics: comics) == "TOPOLINO 3636-3657")
    }

    @Test("Il numero dell'albo si legge anche sotto le decorazioni", arguments: [
        ("Topolino 3652 (Panini 2025-11-19) [c2c CPPT Edition] 1.0", 3652),
        ("Topolino 3636 + Cover Abbonati", 3636),
        ("Topolino 3651", 3651)
    ])
    func readsIssueNumber(title: String, expected: Int) {
        #expect(LibraryGrouping.issueNumber(fromTitle: title) == expected)
    }
}

@Suite("Recupero della serie sui fumetti già in libreria")
struct SeriesBackfillTests {
    @Test("Assegna la serie a chi non ce l'ha")
    func fillsMissingSeries() throws {
        let context = try TestStore.makeContext()
        ComicEntity.create(
            title: "Topolino 3652 (Panini 2025-11-19) [c2c CPPT Edition] 1.0",
            relativePath: "topolino-3652.cbz",
            format: .cbz,
            in: context
        )
        try context.save()

        #expect(LibraryViewModel().backfillSeriesNames(in: context) == 1)
        #expect(try context.fetch(ComicEntity.fetchRequest()).first?.seriesName == "Topolino")
    }

    /// Il gruppo scelto a mano vince sempre: ricalcolarlo vorrebbe dire disfare quello che
    /// l'utente ha appena sistemato.
    @Test("Non tocca una serie già impostata")
    func keepsExistingSeries() throws {
        let context = try TestStore.makeContext()
        ComicEntity.create(
            title: "Topolino 3652 (Panini 2025-11-19) [c2c CPPT Edition] 1.0",
            seriesName: "Le mie preferite",
            relativePath: "topolino-3652.cbz",
            format: .cbz,
            in: context
        )
        try context.save()

        #expect(LibraryViewModel().backfillSeriesNames(in: context) == 0)
        #expect(try context.fetch(ComicEntity.fetchRequest()).first?.seriesName == "Le mie preferite")
    }

    @Test("Lascia stare i titoli da cui non si deduce niente")
    func leavesUnderivableTitlesAlone() throws {
        let context = try TestStore.makeContext()
        ComicEntity.create(title: "Watchmen", relativePath: "watchmen.cbz", format: .cbz, in: context)
        try context.save()

        #expect(LibraryViewModel().backfillSeriesNames(in: context) == 0)
        #expect(try context.fetch(ComicEntity.fetchRequest()).first?.seriesName == nil)
    }
}
