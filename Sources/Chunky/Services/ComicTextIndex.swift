import Foundation
import CoreGraphics

/// Una riga di testo che corrisponde alla ricerca, con la pagina in cui si trova.
struct ComicTextMatch: Identifiable, Equatable {
    let pageIndex: Int
    let line: RecognizedTextLine

    /// L'indice di pagina non basta come identità: la stessa pagina può contenere più righe che
    /// corrispondono, e in una List finirebbero collassate in una sola.
    var id: String { "\(pageIndex)-\(line.boundingBox.minY)-\(line.text)" }
    var text: String { line.text }
}

/// Testo di tutte le pagine di un fumetto, per la ricerca nel lettore.
///
/// Tre vincoli hanno deciso la forma di questa classe:
///
/// - **La scansione parte dalla pagina corrente e si allarga verso l'esterno.** Indicizzare
///   dall'inizio significherebbe, su un volume da 200 pagine, minuti prima che la ricerca dia
///   un risultato utile; quasi sempre l'utente cerca qualcosa che ha appena visto.
/// - **I risultati compaiono man mano.** La stessa progressione già usata per il download da
///   iCloud: si può cercare mentre la scansione continua.
/// - **L'indice è persistito, e non nella cache.** L'OCR di un volume intero costa troppo per
///   poter essere buttato via dal sistema quando serve spazio, quindi il file sta in Application
///   Support (dov'è già lo store Core Data) ed è indicizzato sull'`objectID` del fumetto, che
///   sopravvive alle rinomine del file — cosa che `relativePath` non fa (vedi
///   `LibraryStorage.availableDestination`).
final class ComicTextIndex: ObservableObject {
    /// Righe già note, per pagina. Aggiornata sul main thread man mano che la scansione procede.
    @Published private(set) var lines: [Int: [RecognizedTextLine]] = [:]
    @Published private(set) var isScanning = false

    let pageCount: Int
    var scannedPageCount: Int { lines.count }
    var isComplete: Bool { scannedPageCount >= pageCount }

    /// Vero quando ogni pagina è stata letta e nessuna conteneva testo riconoscibile: senza
    /// distinguerlo, una tavola muta e una parola davvero assente darebbero lo stesso
    /// "Nessun riscontro", e l'utente continuerebbe a provare parole diverse a vuoto.
    var hasNoRecognizableText: Bool {
        isComplete && lines.values.allSatisfy(\.isEmpty)
    }

    private let provider: ComicPageProvider
    private let storageURL: URL?
    private let queue = DispatchQueue(label: "com.scunio.Chunky.ComicTextIndex", qos: .utility)
    private let cancelLock = NSLock()
    private var cancelledFlag = false
    /// Copia autorevole dell'indice, letta e scritta **solo** su `queue`. `lines` esiste per la
    /// UI e viaggia sul main thread: prendere da lì lo snapshot da salvare significherebbe
    /// fotografarlo mentre le ultime pagine sono ancora in coda verso il main, e scrivere su
    /// disco meno di quello che era stato riconosciuto davvero.
    private var storedLines: [Int: [RecognizedTextLine]]

    private var isCancelled: Bool {
        get { cancelLock.lock(); defer { cancelLock.unlock() }; return cancelledFlag }
        set { cancelLock.lock(); cancelledFlag = newValue; cancelLock.unlock() }
    }

    init(provider: ComicPageProvider, comicIdentifier: String) {
        self.provider = provider
        self.pageCount = provider.pageCount
        self.storageURL = Self.storageURL(forComicIdentifier: comicIdentifier)
        let loaded = Self.loadIndex(at: storageURL)
        self.lines = loaded
        self.storedLines = loaded
    }

    deinit { isCancelled = true }

    // MARK: - Scansione

    /// Avvia (o riprende) la scansione delle pagine non ancora indicizzate, partendo da
    /// `page` e allargandosi verso l'esterno. Chiamarla più volte è innocuo: se una scansione
    /// è già in corso non ne parte una seconda.
    func startScanning(from page: Int) {
        guard !isScanning, !isComplete else { return }
        isCancelled = false
        isScanning = true

        let known = Set(lines.keys)
        let order = Self.scanOrder(from: page, pageCount: pageCount).filter { !known.contains($0) }

        queue.async { [weak self] in
            guard let self = self else { return }
            var sincePersist = 0

            for index in order {
                if self.isCancelled { break }
                // Un `autoreleasepool` per pagina: la pagina decodificata di un fumetto può
                // pesare decine di MB, e senza il rilascio esplicito la scansione di un volume
                // intero le accumulerebbe tutte fino alla fine del ciclo.
                autoreleasepool {
                    let pageLines = self.recognizeLines(atPage: index)
                    self.storedLines[index] = pageLines
                    DispatchQueue.main.async {
                        self.lines[index] = pageLines
                    }
                }

                // Salvataggi intermedi: se l'app viene chiusa (o uccisa) a metà scansione di un
                // volume lungo, salvare solo alla fine butterebbe via minuti di OCR già fatto.
                sincePersist += 1
                if sincePersist >= Self.pagesPerPersist {
                    sincePersist = 0
                    self.persist()
                }
            }

            self.persist()
            DispatchQueue.main.async { self.isScanning = false }
        }
    }

    private static let pagesPerPersist = 10

    func cancelScanning() {
        isCancelled = true
    }

    private func recognizeLines(atPage index: Int) -> [RecognizedTextLine] {
        // Prima il testo già digitale (PDF nativi): è esatto e istantaneo, l'OCR è il ripiego.
        if let embedded = try? provider.textLines(atPage: index) {
            return embedded
        }
        guard let image = try? provider.image(atPage: index),
              let cgImage = image.cgImageRepresentation else { return [] }
        return (try? PageTextRecognizer.recognizeLines(in: cgImage)) ?? []
    }

    /// Pagine in ordine di utilità: prima quella che si sta guardando, poi via via quelle
    /// attorno, alternando avanti e indietro.
    static func scanOrder(from page: Int, pageCount: Int) -> [Int] {
        guard pageCount > 0 else { return [] }
        let start = min(max(page, 0), pageCount - 1)
        var order = [start]
        var offset = 1
        while order.count < pageCount {
            if start + offset < pageCount { order.append(start + offset) }
            if start - offset >= 0 { order.append(start - offset) }
            offset += 1
        }
        return order
    }

    // MARK: - Ricerca

    /// Righe che contengono `query`, in ordine di pagina. Il confronto ignora maiuscole e
    /// diacritici: l'OCR sbaglia spesso gli accenti, e cercare "perche" deve trovare "perché".
    func matches(for query: String) -> [ComicTextMatch] {
        Self.matches(for: query, in: lines)
    }

    /// Rettangoli (normalizzati) da evidenziare su una singola pagina.
    func highlights(for query: String, onPage pageIndex: Int) -> [CGRect] {
        Self.matches(for: query, in: [pageIndex: lines[pageIndex] ?? []]).map(\.line.boundingBox)
    }

    /// Il confronto vero e proprio, separato dallo stato dell'oggetto perché è l'unica parte
    /// verificabile senza far girare davvero l'OCR.
    static func matches(for query: String, in lines: [Int: [RecognizedTextLine]]) -> [ComicTextMatch] {
        let needle = normalized(query)
        guard needle.count >= 2 else { return [] }

        return lines.keys.sorted().flatMap { pageIndex -> [ComicTextMatch] in
            (lines[pageIndex] ?? [])
                .filter { normalized($0.text).contains(needle) }
                .map { ComicTextMatch(pageIndex: pageIndex, line: $0) }
        }
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Persistenza

    private struct IndexFile: Codable {
        /// Cambiarla invalida gli indici vecchi: serve se un domani cambiano il formato delle
        /// righe o i parametri dell'OCR, altrimenti si continuerebbe a leggere risultati
        /// prodotti da regole diverse da quelle correnti.
        let version: Int
        let lines: [Int: [RecognizedTextLine]]
    }

    private static let currentVersion = 1

    private static func storageURL(forComicIdentifier identifier: String) -> URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        let folder = support.appendingPathComponent("TextIndex", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("\(sanitized(identifier)).json")
    }

    /// L'URI di un objectID contiene "/" e ":", che in un nome di file non possono starci.
    static func sanitized(_ identifier: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let name = String(identifier.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        // Un identificatore lungo produrrebbe un nome oltre il limite del filesystem: teniamo
        // la coda, che è la parte che distingue un fumetto dall'altro (il prefisso è comune).
        return String(name.suffix(120))
    }

    private static func loadIndex(at url: URL?) -> [Int: [RecognizedTextLine]] {
        guard let url = url,
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(IndexFile.self, from: data),
              file.version == currentVersion else { return [:] }
        return file.lines
    }

    /// Da chiamare solo su `queue`: legge `storedLines` senza attraversare il main thread.
    private func persist() {
        guard let storageURL = storageURL, !storedLines.isEmpty,
              let data = try? JSONEncoder().encode(IndexFile(version: Self.currentVersion, lines: storedLines))
        else { return }
        try? data.write(to: storageURL, options: .atomic)
    }
}
