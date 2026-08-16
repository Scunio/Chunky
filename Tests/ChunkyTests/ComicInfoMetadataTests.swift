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

    /// Un ComicInfo valido ma senza nessuno dei tre campi non deve produrre metadati "vuoti":
    /// altrimenti l'import salterebbe la derivazione del nome serie dal titolo del file.
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
        ("Corto Maltese #7", "Corto Maltese")
    ])
    func derivesSeries(title: String, expected: String) {
        #expect(LibraryViewModel.deriveSeriesName(fromFallbackTitle: title) == expected)
    }

    @Test("Restituisce nil quando non c'è una serie da dedurre", arguments: [
        "Batman",          // nessun numero
        "3595",            // solo un numero: non resta nulla come serie
        "#12",
        "",
        "Watchmen Vol"     // numero assente
    ])
    func returnsNil(title: String) {
        #expect(LibraryViewModel.deriveSeriesName(fromFallbackTitle: title) == nil)
    }

    /// Un numero a metà titolo non è un numero di albo: "Fantastici 4" è il nome della serie.
    @Test("Non tocca i numeri che non sono in fondo")
    func ignoresMidTitleNumbers() {
        #expect(LibraryViewModel.deriveSeriesName(fromFallbackTitle: "Fantastici 4 contro Doom") == nil)
    }
}
