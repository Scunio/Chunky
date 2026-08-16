import Testing

@Suite("Spread e riallineamento")
struct ReaderPaginationSpreadTests {
    @Test("spreadStarts con passo 1 è ogni pagina", arguments: [2, 5, 10])
    func stepOneEveryPage(pageCount: Int) {
        let sut = ReaderPagination(pageCount: pageCount, pageStep: 1, isRightToLeft: false)
        #expect(sut.spreadStarts == Array(0..<pageCount))
    }

    @Test("spreadStarts con passo 2, pageCount pari")
    func stepTwoEvenCount() {
        let sut = ReaderPagination(pageCount: 10, pageStep: 2, isRightToLeft: false)
        #expect(sut.spreadStarts == [0, 2, 4, 6, 8])
    }

    @Test("spreadStarts con passo 2, pageCount dispari (l'ultima pagina resta da sola)")
    func stepTwoOddCount() {
        let sut = ReaderPagination(pageCount: 9, pageStep: 2, isRightToLeft: false)
        #expect(sut.spreadStarts == [0, 2, 4, 6, 8])
    }

    @Test("pageCount 0 o 1 non produce un array vuoto")
    func degenerateCounts() {
        #expect(ReaderPagination(pageCount: 0, pageStep: 2, isRightToLeft: false).spreadStarts == [0])
        #expect(ReaderPagination(pageCount: 1, pageStep: 2, isRightToLeft: false).spreadStarts == [0])
    }

    @Test("Riallineamento da pagina dispari a passo 2 torna all'inizio dello spread")
    func realignsOddPage() {
        let sut = ReaderPagination(pageCount: 10, pageStep: 2, isRightToLeft: false)
        #expect(sut.realigned(3) == 2)
        #expect(sut.realigned(0) == 0)
        #expect(sut.realigned(9) == 8)
    }

    @Test("Riallineamento con passo 1 è sempre un no-op")
    func realignWithStepOneIsNoOp() {
        let sut = ReaderPagination(pageCount: 10, pageStep: 1, isRightToLeft: false)
        for page in 0..<10 {
            #expect(sut.realigned(page) == page)
        }
    }

    @Test("spreadIndex(containing:) trova lo spread giusto per lo slider")
    func spreadIndexLookup() {
        let sut = ReaderPagination(pageCount: 10, pageStep: 2, isRightToLeft: false)
        #expect(sut.spreadIndex(containing: 0) == 0)
        #expect(sut.spreadIndex(containing: 1) == 0)
        #expect(sut.spreadIndex(containing: 2) == 1)
        #expect(sut.spreadIndex(containing: 9) == 4)
    }
}

@Suite("Passo di lettura: LTR")
struct ReaderPaginationStepLTRTests {
    @Test("Avanti di un passo alla volta, passo singolo")
    func forwardSingle() {
        let sut = ReaderPagination(pageCount: 5, pageStep: 1, isRightToLeft: false)
        #expect(sut.step(from: 0, direction: 1) == .page(1))
        #expect(sut.step(from: 3, direction: 1) == .page(4))
    }

    @Test("Indietro di un passo alla volta, passo singolo")
    func backwardSingle() {
        let sut = ReaderPagination(pageCount: 5, pageStep: 1, isRightToLeft: false)
        #expect(sut.step(from: 4, direction: -1) == .page(3))
        #expect(sut.step(from: 1, direction: -1) == .page(0))
    }

    @Test("Avanti oltre l'ultima pagina propone il fumetto successivo")
    func forwardPastEndTriggersNext() {
        let sut = ReaderPagination(pageCount: 5, pageStep: 1, isRightToLeft: false)
        #expect(sut.step(from: 4, direction: 1) == .endReached(triggersNextComic: true))
    }

    @Test("Indietro prima della prima pagina non fa nulla")
    func backwardPastStart() {
        let sut = ReaderPagination(pageCount: 5, pageStep: 1, isRightToLeft: false)
        #expect(sut.step(from: 0, direction: -1) == .beginningReached)
    }

    @Test("Passo doppio avanza di due pagine")
    func forwardDoubleStep() {
        let sut = ReaderPagination(pageCount: 10, pageStep: 2, isRightToLeft: false)
        #expect(sut.step(from: 0, direction: 1) == .page(2))
        #expect(sut.step(from: 2, direction: 1) == .page(4))
    }

    @Test("L'ultimo spread dispari avanza correttamente fino in fondo")
    func forwardDoubleStepOddTail() {
        let sut = ReaderPagination(pageCount: 9, pageStep: 2, isRightToLeft: false)
        #expect(sut.step(from: 6, direction: 1) == .page(8))
        #expect(sut.step(from: 8, direction: 1) == .endReached(triggersNextComic: true))
    }
}

@Suite("Passo di lettura: RTL (manga)")
struct ReaderPaginationStepRTLTests {
    /// The input direction is always "right = forward in reading order": in RTL this means
    /// moving toward LOWER indices, not higher ones — the inversion is entirely internal to
    /// `step`, the caller doesn't need to know about it.
    @Test("In RTL, avanti nella lettura corrisponde a un input positivo che diminuisce l'indice")
    func rtlForwardDecreasesIndex() {
        let sut = ReaderPagination(pageCount: 5, pageStep: 1, isRightToLeft: true)
        // Start from the last page (the "first" one in RTL reading order) and go forward.
        #expect(sut.step(from: 4, direction: 1) == .page(3))
        #expect(sut.step(from: 3, direction: 1) == .page(2))
    }

    @Test("In RTL, indietro nella lettura corrisponde a un input negativo che aumenta l'indice")
    func rtlBackwardIncreasesIndex() {
        let sut = ReaderPagination(pageCount: 5, pageStep: 1, isRightToLeft: true)
        #expect(sut.step(from: 2, direction: -1) == .page(3))
    }

    /// A surprise verified by hand against the original code, not a behavior I chose: the
    /// "end of comic" check in `step()` only looks at `next >= pageCount`, never
    /// `next < 0`. In RTL, moving forward (`direction: 1`) makes the index DECREASE, so
    /// reaching the end of the reading order in RTL falls into the `next < 0` branch — which
    /// returns `.beginningReached`, not `.endReached` — and **never proposes the next comic**.
    /// This test locks in the current behavior as it is, without declaring it correct: it's a
    /// candidate for a future fix, but changing it now would be a silent behavior change
    /// inside a phase that must leave everything identical.
    @Test("In RTL, avanti fino in fondo (indice 0) NON propone il fumetto successivo")
    func rtlForwardToEndDoesNotTriggerNext() {
        let sut = ReaderPagination(pageCount: 5, pageStep: 1, isRightToLeft: true)
        #expect(sut.step(from: 0, direction: 1) == .beginningReached)
    }

    /// Mirror image of the case above: "backward" (`direction: -1`) from the last page makes
    /// the index increase past `pageCount`, falling into the `next >= pageCount` branch —
    /// which returns `.endReached`. With `direction: -1`, `effectiveDirection` still ends up
    /// positive in RTL, so `triggersNextComic` comes out `true` even though the user pressed
    /// "backward".
    @Test("In RTL, indietro dall'ultima pagina cade nel ramo 'fine fumetto'")
    func rtlBackwardFromLastPageHitsEndBranch() {
        let sut = ReaderPagination(pageCount: 5, pageStep: 1, isRightToLeft: true)
        #expect(sut.step(from: 4, direction: -1) == .endReached(triggersNextComic: true))
    }

    @Test("RTL con passo doppio")
    func rtlDoubleStep() {
        let sut = ReaderPagination(pageCount: 10, pageStep: 2, isRightToLeft: true)
        #expect(sut.step(from: 8, direction: 1) == .page(6))
        #expect(sut.step(from: 0, direction: 1) == .beginningReached)
    }
}

@Suite("Transizione tra passo singolo e doppio")
struct ReaderPaginationStepTransitionTests {
    /// This is the scenario the original comment in ReaderView described: switching from
    /// single to double page while on an odd page leaves an index that is no longer a valid
    /// spread start.
    @Test("Passare da passo 1 a passo 2 su pagina dispari richiede un riallineamento")
    func oddPageNeedsRealignAfterStepChange() {
        let doubled = ReaderPagination(pageCount: 10, pageStep: 2, isRightToLeft: false)
        #expect(doubled.realigned(3) == 2)
        #expect(doubled.spreadStarts.contains(doubled.realigned(3)))
    }

    @Test("Tornare da passo 2 a passo 1 non richiede riallineamento: ogni pagina è già un inizio-spread")
    func everyPageValidAtStepOne() {
        let single = ReaderPagination(pageCount: 10, pageStep: 1, isRightToLeft: false)
        for page in 0..<10 {
            #expect(single.spreadStarts.contains(page))
        }
    }
}

@Suite("Seconda pagina di uno spread")
struct ReaderPaginationShowsSecondPageTests {
    @Test("Con passo 1 non c'è mai una seconda pagina")
    func stepOneNeverPairs() {
        let sut = ReaderPagination(pageCount: 10, pageStep: 1, isRightToLeft: false)
        #expect(!sut.showsSecondPage(from: 0))
        #expect(!sut.showsSecondPage(from: 5))
    }

    @Test("Con passo 2 ogni inizio-spread mostra la seconda pagina, tranne l'ultimo se dispari")
    func stepTwoPairsExceptOddTail() {
        let sut = ReaderPagination(pageCount: 9, pageStep: 2, isRightToLeft: false)
        #expect(sut.showsSecondPage(from: 0))
        #expect(sut.showsSecondPage(from: 6))
        #expect(!sut.showsSecondPage(from: 8))
    }

    @Test("Con la copertina da sola, il suo spread non ha una seconda pagina")
    func coverAloneHasNoSecondPage() {
        let sut = ReaderPagination(pageCount: 9, pageStep: 2, isRightToLeft: false, coverIsAlone: true)
        #expect(!sut.showsSecondPage(from: 0))
        #expect(sut.showsSecondPage(from: 1))
    }

    @Test("Un indice che non è inizio-spread non altera il conteggio")
    func nonSpreadStartStillReports() {
        let sut = ReaderPagination(pageCount: 10, pageStep: 2, isRightToLeft: false)
        // 3 isn't a valid spread start, but the function must not crash: it responds
        // based on the step, consistent with the fallback already present in the original implementation.
        #expect(sut.showsSecondPage(from: 3))
    }
}

@Suite("Copertina da sola")
struct ReaderPaginationCoverAloneTests {
    @Test("Con passo 1 non cambia nulla: ogni pagina è già a sé")
    func noEffectAtStepOne() {
        let withCover = ReaderPagination(pageCount: 9, pageStep: 1, isRightToLeft: false, coverIsAlone: true)
        let withoutCover = ReaderPagination(pageCount: 9, pageStep: 1, isRightToLeft: false, coverIsAlone: false)
        #expect(withCover.spreadStarts == withoutCover.spreadStarts)
    }

    @Test("La copertina è il suo spread, l'accoppiamento riprende dalla seconda pagina")
    func coverIsOwnSpread() {
        let sut = ReaderPagination(pageCount: 9, pageStep: 2, isRightToLeft: false, coverIsAlone: true)
        // Without a lone cover this would be [0, 2, 4, 6, 8]: with the lone cover, the pairing
        // shifts by one position after the first spread.
        #expect(sut.spreadStarts == [0, 1, 3, 5, 7])
    }

    @Test("pageCount pari: l'ultima pagina resta da sola con la copertina attiva")
    func evenCountLeavesLastPageAlone() {
        let sut = ReaderPagination(pageCount: 10, pageStep: 2, isRightToLeft: false, coverIsAlone: true)
        #expect(sut.spreadStarts == [0, 1, 3, 5, 7, 9])
    }

    @Test("pageCount 1: solo la copertina, nessun accoppiamento possibile")
    func singlePageComic() {
        let sut = ReaderPagination(pageCount: 1, pageStep: 2, isRightToLeft: false, coverIsAlone: true)
        #expect(sut.spreadStarts == [0])
    }

    @Test("Avanzando dalla copertina si passa allo spread successivo, non a metà")
    func forwardFromCoverEntersFirstPair() {
        let sut = ReaderPagination(pageCount: 9, pageStep: 2, isRightToLeft: false, coverIsAlone: true)
        #expect(sut.step(from: 0, direction: 1) == .page(1))
        #expect(sut.step(from: 1, direction: 1) == .page(3))
    }

    @Test("Tornando indietro dal primo spread si arriva alla copertina, non a una pagina intermedia")
    func backwardFromFirstPairReturnsToCover() {
        let sut = ReaderPagination(pageCount: 9, pageStep: 2, isRightToLeft: false, coverIsAlone: true)
        #expect(sut.step(from: 1, direction: -1) == .page(0))
    }

    @Test("Riallineare una pagina dispari qualsiasi cade sull'inizio-spread corretto")
    func realignsToCorrectSpread() {
        let sut = ReaderPagination(pageCount: 9, pageStep: 2, isRightToLeft: false, coverIsAlone: true)
        #expect(sut.realigned(0) == 0)
        #expect(sut.realigned(2) == 1)
        #expect(sut.realigned(4) == 3)
        #expect(sut.realigned(8) == 7)
    }

    @Test("RTL con copertina da sola: la copertina resta l'ultimo indice, da sola")
    func rtlCoverAloneAtLastIndex() {
        // In RTL reading the "first" page in reading order is still index 0 (see the other
        // RTL tests): the lone-cover behavior always applies to index 0, regardless of
        // reading direction — it's the same physical page of the file, not a derived notion.
        let sut = ReaderPagination(pageCount: 9, pageStep: 2, isRightToLeft: true, coverIsAlone: true)
        #expect(sut.spreadStarts == [0, 1, 3, 5, 7])
    }
}
