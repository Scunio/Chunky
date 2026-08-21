import Foundation
import Testing

@Suite("ComicInfo.xml")
struct ComicInfoMetadataTests {
    @Test("Legge serie, titolo e numero da un file completo")
    func parsesFullFile() throws {
        let metadata = try #require(ComicInfoMetadata.parse(from: try Fixtures.data("comicinfo-full.xml")))
        #expect(metadata.series == "Topolino")
        #expect(metadata.title == "La grande fuga")
        #expect(metadata.number == "3595")
    }

    @Test("Un file parziale restituisce solo i campi presenti")
    func parsesPartialFile() throws {
        let metadata = try #require(ComicInfoMetadata.parse(from: try Fixtures.data("comicinfo-partial.xml")))
        #expect(metadata.series == "Dylan Dog")
        #expect(metadata.title == nil)
        #expect(metadata.number == nil)
    }

    @Test("Un XML malformato restituisce nil invece di dati parziali")
    func rejectsMalformedFile() throws {
        #expect(ComicInfoMetadata.parse(from: try Fixtures.data("comicinfo-malformed.xml")) == nil)
    }

    @Test("Dati vuoti o non XML restituiscono nil")
    func rejectsNonXML() {
        #expect(ComicInfoMetadata.parse(from: Data()) == nil)
        #expect(ComicInfoMetadata.parse(from: Data("non è xml".utf8)) == nil)
    }

    /// A valid ComicInfo that has none of the three fields must not produce "empty" metadata:
    /// otherwise the import would skip deriving the series name from the file title.
    @Test("Un ComicInfo senza campi utili restituisce nil")
    func rejectsEmptyComicInfo() {
        let xml = Data("<?xml version=\"1.0\"?><ComicInfo><Publisher>Panini</Publisher></ComicInfo>".utf8)
        #expect(ComicInfoMetadata.parse(from: xml) == nil)
    }

    @Test("Gli spazi attorno ai valori vengono rimossi")
    func trimsWhitespace() {
        let xml = Data("<?xml version=\"1.0\"?><ComicInfo><Series>  Tex  </Series></ComicInfo>".utf8)
        #expect(ComicInfoMetadata.parse(from: xml)?.series == "Tex")
    }
}

@Suite("Derivazione del nome serie")
struct SeriesNameDerivationTests {
    @Test("Rimuove il numero finale dal titolo", arguments: [
        ("Topolino 3595", "Topolino"),
        ("Topolino #3595", "Topolino"),
        ("Topolino   3595   ", "Topolino"),
        ("Dylan Dog 442", "Dylan Dog"),
        ("Corto Maltese #7", "Corto Maltese"),
        // Trailing decorations found on scanned releases: without stripping them the title
        // wouldn't end with a number and the comic would stay in "Other comics".
        ("Topolino 3652 (Panini 2025-11-19) [c2c CPPT Edition] 1.0", "Topolino"),
        ("Topolino 3653 (Panini 2025-11-26) [c2c CPPT Edition] 1.1 (corrette pagine doppie)", "Topolino"),
        ("Topolino 3636 + Cover Abbonati", "Topolino"),
        ("Topolino 3654 (Panini) + Cover Abbonati", "Topolino"),
        ("Topolino 3655 {HD}", "Topolino"),
        // Scanned release with a bare (unbracketed) date after the publisher: "(Panini)" is
        // stripped first, leaving a trailing date that isn't inside any bracket.
        ("Topolino 3661 (Panini) 2026-01-21 [c2c CPPT Edition]", "Topolino")
    ])
    func derivesSeries(title: String, expected: String) {
        #expect(LibraryViewModel.deriveSeriesName(fromFallbackTitle: title) == expected)
    }

    @Test("Restituisce nil quando non c'è una serie da dedurre", arguments: [
        "Batman",          // no number
        "3595",            // just a number: nothing is left as the series
        "#12",
        "",
        "Watchmen Vol",    // missing number
        "Batman + Robin",  // after stripping the "+" tail, no number is left
        "(2025)"           // after stripping the parenthesis, nothing is left
    ])
    func returnsNil(title: String) {
        #expect(LibraryViewModel.deriveSeriesName(fromFallbackTitle: title) == nil)
    }

    /// A number in the middle of the title is not an issue number: "Fantastici 4" is the series name.
    @Test("Non tocca i numeri che non sono in fondo")
    func ignoresMidTitleNumbers() {
        #expect(LibraryViewModel.deriveSeriesName(fromFallbackTitle: "Fantastici 4 contro Doom") == nil)
    }
}
