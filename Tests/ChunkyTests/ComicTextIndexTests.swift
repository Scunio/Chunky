import CoreGraphics
import Foundation
import Testing

@Suite("ComicTextIndex")
struct ComicTextIndexTests {
    private func line(_ text: String, y: CGFloat = 0.5) -> RecognizedTextLine {
        RecognizedTextLine(text: text, boundingBox: CGRect(x: 0.1, y: y, width: 0.5, height: 0.05))
    }

    /// Indicizzare dalla prima pagina renderebbe la ricerca inutile per minuti su un volume
    /// lungo: l'ordine deve partire da dove sta l'utente e allargarsi da lì.
    @Test("La scansione parte dalla pagina corrente e si allarga")
    func scanOrderStartsAtCurrentPage() {
        #expect(ComicTextIndex.scanOrder(from: 5, pageCount: 10) == [5, 6, 4, 7, 3, 8, 2, 9, 1, 0])
    }

    @Test("L'ordine di scansione copre tutte le pagine anche ai bordi")
    func scanOrderCoversEveryPage() {
        for start in [0, 3, 9] {
            let order = ComicTextIndex.scanOrder(from: start, pageCount: 10)
            #expect(Set(order) == Set(0..<10))
            #expect(order.count == 10)
            #expect(order.first == start)
        }
        #expect(ComicTextIndex.scanOrder(from: 0, pageCount: 0).isEmpty)
        // Una pagina richiesta fuori intervallo viene riportata dentro invece di far saltare
        // pagine: succede quando la ricerca si apre su uno spread a cavallo della fine.
        #expect(ComicTextIndex.scanOrder(from: 99, pageCount: 3) == [2, 1, 0])
    }

    /// L'OCR sbaglia regolarmente gli accenti, e nessuno scrive le maiuscole quando cerca.
    @Test("La ricerca ignora maiuscole e accenti")
    func searchIsCaseAndDiacriticInsensitive() {
        let lines = [0: [line("PERCHÉ SEI QUI?")]]
        #expect(ComicTextIndex.matches(for: "perche", in: lines).count == 1)
        #expect(ComicTextIndex.matches(for: "SEI qui", in: lines).count == 1)
        #expect(ComicTextIndex.matches(for: "altrove", in: lines).isEmpty)
    }

    @Test("Una query troppo corta non restituisce nulla")
    func shortQueryReturnsNothing() {
        #expect(ComicTextIndex.matches(for: "a", in: [0: [line("abcdef")]]).isEmpty)
    }

    @Test("I riscontri sono ordinati per pagina")
    func matchesAreSortedByPage() {
        let lines = [7: [line("bang")], 2: [line("bang")], 4: [line("bang")]]
        #expect(ComicTextIndex.matches(for: "bang", in: lines).map(\.pageIndex) == [2, 4, 7])
    }

    /// Più righe sulla stessa pagina devono restare distinte: con l'indice di pagina come
    /// identità, una `ForEach` ne mostrerebbe una sola.
    @Test("Righe diverse sulla stessa pagina hanno identità diverse")
    func matchesOnTheSamePageAreDistinct() {
        let lines = [3: [line("bang", y: 0.2), line("bang!", y: 0.7)]]
        let matches = ComicTextIndex.matches(for: "bang", in: lines)
        #expect(matches.count == 2)
        #expect(Set(matches.map(\.id)).count == 2)
    }

    /// L'indice su disco è l'unica cosa che evita di rifare l'OCR di un volume intero: se il
    /// round-trip perdesse le chiavi di pagina (un dizionario con chiavi Int non è un oggetto
    /// JSON) il lavoro verrebbe ributtato via a ogni apertura, in silenzio.
    @Test("L'indice sopravvive al round-trip su JSON")
    func indexSurvivesJSONRoundTrip() throws {
        let original: [Int: [RecognizedTextLine]] = [
            0: [line("prima pagina", y: 0.8)],
            17: [line("diciottesima", y: 0.1), line("ancora", y: 0.4)]
        ]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([Int: [RecognizedTextLine]].self, from: data)

        #expect(decoded == original)
        #expect(decoded[17]?.first?.boundingBox == original[17]?.first?.boundingBox)
    }

    /// L'URI di un objectID Core Data contiene "/" e ":": usato tale e quale come nome di file
    /// l'indice non verrebbe mai scritto, e nessuno se ne accorgerebbe (si rifarebbe solo l'OCR).
    @Test("L'identificatore del fumetto diventa un nome di file valido")
    func sanitizesIdentifierIntoFilename() {
        let name = ComicTextIndex.sanitized("x-coredata://ABC-123/ComicEntity/p42")
        #expect(!name.contains("/"))
        #expect(!name.contains(":"))
        #expect(name.hasSuffix("p42"))
        // Identificatori diversi devono restare diversi anche dopo la sostituzione.
        #expect(name != ComicTextIndex.sanitized("x-coredata://ABC-123/ComicEntity/p43"))
    }
}
