import CoreGraphics
import Foundation
import Testing

/// Minimal provider that returns text that's already digital (as a native PDF would): avoids
/// having to actually run OCR just to test index persistence and deletion.
private struct FakeTextProvider: ComicPageProvider {
    let pageCount: Int
    let lines: [[RecognizedTextLine]]
    func image(atPage index: Int) throws -> PlatformImage { throw ComicReadError.pageOutOfRange }
    func textLines(atPage index: Int) throws -> [RecognizedTextLine]? { lines[index] }
}

@Suite("ComicTextIndex")
struct ComicTextIndexTests {
    private func line(_ text: String, y: CGFloat = 0.5) -> RecognizedTextLine {
        RecognizedTextLine(text: text, boundingBox: CGRect(x: 0.1, y: y, width: 0.5, height: 0.05))
    }

    /// Indexing from the first page would make search useless for minutes on a long
    /// volume: the order must start where the user is and expand outward from there.
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
        // A requested page outside the valid range is clamped back in instead of skipping
        // pages: this happens when the search opens on a spread straddling the end.
        #expect(ComicTextIndex.scanOrder(from: 99, pageCount: 3) == [2, 1, 0])
    }

    /// OCR regularly gets accents wrong, and nobody types uppercase when searching.
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

    /// Multiple lines on the same page must remain distinct: with the page index as the
    /// identity, a `ForEach` would show only one of them.
    @Test("Righe diverse sulla stessa pagina hanno identità diverse")
    func matchesOnTheSamePageAreDistinct() {
        let lines = [3: [line("bang", y: 0.2), line("bang!", y: 0.7)]]
        let matches = ComicTextIndex.matches(for: "bang", in: lines)
        #expect(matches.count == 2)
        #expect(Set(matches.map(\.id)).count == 2)
    }

    /// The on-disk index is the only thing that avoids redoing OCR on an entire volume: if the
    /// round-trip lost the page keys (a dictionary with Int keys is not a JSON object) the
    /// work would be silently thrown away on every reopen.
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

    /// A Core Data objectID URI contains "/" and ":": used as-is as a filename, the
    /// index would never get written, and nobody would notice (OCR would just get redone).
    @Test("L'identificatore del fumetto diventa un nome di file valido")
    func sanitizesIdentifierIntoFilename() {
        let name = ComicTextIndex.sanitized("x-coredata://ABC-123/ComicEntity/p42")
        #expect(!name.contains("/"))
        #expect(!name.contains(":"))
        #expect(name.hasSuffix("p42"))
        // Different identifiers must remain different even after sanitization.
        #expect(name != ComicTextIndex.sanitized("x-coredata://ABC-123/ComicEntity/p43"))
    }

    /// Senza `deleteIndex`, l'indice di un fumetto rimosso dalla libreria resterebbe orfano per
    /// sempre in Application Support: qui si verifica il round-trip completo attraverso la sola
    /// API pubblica, non il percorso interno del file (privato apposta).
    @Test("deleteIndex rimuove l'indice persistito, non solo quello in memoria")
    func deleteIndexRemovesPersistedFile() async throws {
        let identifier = "test-\(UUID().uuidString)"
        let scanned = ComicTextIndex(
            provider: FakeTextProvider(pageCount: 1, lines: [[line("trovami")]]),
            comicIdentifier: identifier
        )
        scanned.startScanning(from: 0)
        while scanned.isScanning {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        // A new index for the same identifier, with a provider that would never find
        // "trovami" on its own: if the result shows up, it comes from the persisted file.
        let reopened = ComicTextIndex(
            provider: FakeTextProvider(pageCount: 1, lines: [[]]),
            comicIdentifier: identifier
        )
        #expect(reopened.matches(for: "trovami").count == 1)

        ComicTextIndex.deleteIndex(forComicIdentifier: identifier)

        let afterDelete = ComicTextIndex(
            provider: FakeTextProvider(pageCount: 1, lines: [[]]),
            comicIdentifier: identifier
        )
        #expect(afterDelete.matches(for: "trovami").isEmpty)
    }
}
