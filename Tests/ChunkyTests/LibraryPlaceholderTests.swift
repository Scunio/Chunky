import Foundation
import Testing

/// Copre le due funzioni pure estratte per far convivere la registrazione immediata di un
/// fumetto e il suo completamento posticipato: un fumetto iCloud non ancora scaricato entra in
/// libreria senza aprire l'archivio, e copertina/pagine/metadati arrivano dopo. Le due strade
/// devono ricavare titolo e serie allo stesso modo, altrimenti il fumetto si rinominerebbe da
/// solo appena finisce di scaricarsi.
@Suite("Segnaposto iCloud")
struct LibraryPlaceholderTests {
    @Test("Senza ComicInfo resta il nome del file")
    func fallsBackToFileName() {
        let title = LibraryViewModel.displayTitle(from: nil, fallbackTitle: "Topolino 3651")
        #expect(title == "Topolino 3651")
    }

    @Test("Il titolo del ComicInfo vince sul nome del file")
    func prefersMetadataTitle() {
        let metadata = ComicInfoMetadata(series: "Topolino", title: "La banda Bassotti", number: "3651")
        #expect(LibraryViewModel.displayTitle(from: metadata, fallbackTitle: "topolino_3651") == "La banda Bassotti")
    }

    @Test("Senza titolo, serie e numero si compongono")
    func composesSeriesAndNumber() {
        let metadata = ComicInfoMetadata(series: "Topolino", title: nil, number: "3651")
        #expect(LibraryViewModel.displayTitle(from: metadata, fallbackTitle: "qualsiasi") == "Topolino #3651")
    }

    @Test("Senza titolo né numero resta la sola serie")
    func fallsBackToSeriesAlone() {
        let metadata = ComicInfoMetadata(series: "Topolino", title: nil, number: nil)
        #expect(LibraryViewModel.displayTitle(from: metadata, fallbackTitle: "qualsiasi") == "Topolino")
    }

    @Test("Un ComicInfo senza campi utili non sovrascrive il nome del file")
    func ignoresEmptyMetadata() {
        let metadata = ComicInfoMetadata(series: nil, title: nil, number: nil)
        #expect(LibraryViewModel.displayTitle(from: metadata, fallbackTitle: "Topolino 3651") == "Topolino 3651")
    }

    @Test("Le durate nel log distinguono i secondi dai minuti")
    func formatsDurationsForTheLog() {
        #expect(LibraryViewModel.formatted(duration: 0) == "0s")
        #expect(LibraryViewModel.formatted(duration: 12.4) == "12s")
        #expect(LibraryViewModel.formatted(duration: 59.6) == "1m 0s")
        #expect(LibraryViewModel.formatted(duration: 270) == "4m 30s")
    }
}
