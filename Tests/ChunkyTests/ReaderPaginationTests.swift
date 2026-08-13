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
    /// La direzione dell'input è sempre "destra = avanti nella lettura": in RTL questo
    /// significa muoversi verso indici PIÙ BASSI, non più alti — l'inversione è interamente
    /// interna a `step`, il chiamante non deve saperlo.
    @Test("In RTL, avanti nella lettura corrisponde a un input positivo che diminuisce l'indice")
    func rtlForwardDecreasesIndex() {
        let sut = ReaderPagination(pageCount: 5, pageStep: 1, isRightToLeft: true)
        // Si parte dall'ultima pagina (la "prima" in ordine di lettura RTL) e si va avanti.
        #expect(sut.step(from: 4, direction: 1) == .page(3))
        #expect(sut.step(from: 3, direction: 1) == .page(2))
    }

    @Test("In RTL, indietro nella lettura corrisponde a un input negativo che aumenta l'indice")
    func rtlBackwardIncreasesIndex() {
        let sut = ReaderPagination(pageCount: 5, pageStep: 1, isRightToLeft: true)
        #expect(sut.step(from: 2, direction: -1) == .page(3))
    }

    /// Sorpresa verificata a mano sul codice originale, non un comportamento che ho scelto:
    /// il controllo "fine fumetto" in `step()` guarda solo `next >= pageCount`, mai
    /// `next < 0`. In RTL, avanzare (`direction: 1`) porta l'indice a DIMINUIRE, quindi
    /// arrivare a fondo lettura in RTL cade nel ramo `next < 0` — che restituisce
    /// `.beginningReached`, non `.endReached` — e **non propone mai il fumetto successivo**.
    /// Questo test blinda il comportamento attuale così com'è, non lo dichiara corretto:
    /// è un candidato per una correzione futura, ma cambiarlo ora sarebbe un cambio di
    /// comportamento silenzioso dentro una fase che deve lasciare tutto identico.
    @Test("In RTL, avanti fino in fondo (indice 0) NON propone il fumetto successivo")
    func rtlForwardToEndDoesNotTriggerNext() {
        let sut = ReaderPagination(pageCount: 5, pageStep: 1, isRightToLeft: true)
        #expect(sut.step(from: 0, direction: 1) == .beginningReached)
    }

    /// Speculare al caso sopra: "indietro" (`direction: -1`) dall'ultima pagina fa aumentare
    /// l'indice oltre `pageCount`, cadendo nel ramo `next >= pageCount` — che restituisce
    /// `.endReached`. Con `direction: -1`, `effectiveDirection` resta comunque positivo in
    /// RTL, quindi `triggersNextComic` risulta `true` anche se l'utente ha premuto "indietro".
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
    /// È lo scenario che il commento originale in ReaderView descriveva: passare da singola a
    /// doppia pagina mentre si è su una pagina dispari lascia un indice che non è più un
    /// inizio-spread valido.
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
        // Senza copertina da sola sarebbe [0, 2, 4, 6, 8]: con la copertina da sola, l'accoppiamento
        // si sposta di una posizione dopo il primo spread.
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
        // In lettura RTL la "prima" pagina in ordine di lettura è comunque indice 0 (vedi gli
        // altri test RTL): la copertina-da-sola riguarda sempre l'indice 0, indipendentemente
        // dal verso di lettura — è la stessa pagina fisica del file, non una nozione derivata.
        let sut = ReaderPagination(pageCount: 9, pageStep: 2, isRightToLeft: true, coverIsAlone: true)
        #expect(sut.spreadStarts == [0, 1, 3, 5, 7])
    }
}
