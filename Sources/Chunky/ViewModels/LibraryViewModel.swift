import Foundation
import CoreData
import Combine

final class LibraryViewModel: ObservableObject {
    @Published var isImporting = false
    /// Cosa sta facendo la libreria in questo momento, mostrato nell'overlay di caricamento.
    /// `nil` quando non c'è lavoro in corso: le scansioni automatiche che non trovano niente da
    /// registrare non devono far comparire nessun indicatore.
    @Published var importStatus: String?
    @Published var importError: String?

    /// Tutte le scritture in libreria passano da qui, una alla volta. Prima ogni funzione si
    /// dispatchava per conto proprio su `DispatchQueue.global`, e con quattro trigger di scansione
    /// (vedi `ContentView`) due passate potevano sovrapporsi: entrambe leggevano i path già noti
    /// prima che l'altra salvasse, e registravano gli stessi file due volte.
    private let workQueue = DispatchQueue(label: "com.scunio.Chunky.library-scan", qos: .userInitiated)

    /// Contesto di background unico e di lunga vita, non uno nuovo per chiamata: due passate
    /// consecutive devono vedere ciascuna quello che l'altra ha appena salvato.
    private var scanContext: NSManagedObjectContext?

    /// Scansioni già in coda ma non ancora partite: un secondo trigger dello stesso tipo non
    /// aggiunge una passata identica, aspetta quella che sta per girare. La chiave viene tolta
    /// all'inizio dell'esecuzione, così un trigger arrivato *durante* la passata ne accoda
    /// comunque un'altra alla fine (ed è proprio quello che serve: lo stato su disco è cambiato).
    private let pendingLock = NSLock()
    private var pendingScans: Set<ScanKind> = []
    /// Operazioni che stanno mostrando l'indicatore di caricamento, dalla più vecchia alla più
    /// recente, ciascuna col proprio testo corrente (vedi `beginStatus`).
    private var statusStack: [(token: Int, text: String)] = []
    private var nextStatusToken = 0

    private enum ScanKind: Hashable {
        case rebuild
        case adopt
        case deduplicate
        case placeholderMetadata
    }

    /// Percorsi il cui archivio si è rifiutato di aprirsi durante il completamento dei
    /// segnaposto. Un file corrotto resta indistinguibile da uno appena scaricato (zero pagine,
    /// nessuna copertina) e verrebbe riaperto a ogni passata: qui li ricordiamo per la durata
    /// della sessione. Non è persistito apposta — un riavvio dell'app è l'occasione giusta per
    /// riprovare, il file nel frattempo può essere stato risincronizzato.
    private var pathsWithUnreadableArchive: Set<String> = []

    // MARK: - Import esplicito

    func importFiles(_ urls: [URL], into context: NSManagedObjectContext) {
        let backgroundContext = sharedScanContext(for: context)
        let statusToken = beginStatus(urls.count == 1 ? "Importazione…" : "Importazione di \(urls.count) fumetti…")

        workQueue.async { [weak self] in
            guard let self = self else { return }
            defer { self.endStatus(token: statusToken) }
            for (index, url) in urls.enumerated() {
                if urls.count > 1 {
                    self.updateStatus("Importazione di \(index + 1) di \(urls.count)…", token: statusToken)
                }
                self.importSingleFile(url, into: backgroundContext)
            }
            self.deduplicateComics(in: backgroundContext)
            self.backfillSeriesNames(in: backgroundContext)
        }
    }

    /// Il contesto va creato sul thread del chiamante (sempre il main: le entry point pubbliche
    /// sono invocate da SwiftUI), non dentro `workQueue`, così l'accesso a `scanContext` resta
    /// confinato a un solo thread.
    private func sharedScanContext(for context: NSManagedObjectContext) -> NSManagedObjectContext {
        if let existing = scanContext, existing.persistentStoreCoordinator === context.persistentStoreCoordinator {
            return existing
        }
        guard let coordinator = context.persistentStoreCoordinator else { return context }

        let bg = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        bg.persistentStoreCoordinator = coordinator
        bg.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        // Vive quanto l'app: senza queste due, continuerebbe a servire i valori con cui ha
        // caricato gli oggetti la prima volta, ignorando sia le modifiche fatte dall'interfaccia
        // sia i record arrivati da CloudKit.
        bg.automaticallyMergesChangesFromParent = true
        bg.stalenessInterval = 0
        scanContext = bg
        return bg
    }

    /// Copia `url` nella cartella della libreria, poi la registra. Usato per file esterni
    /// (picker di sistema, download da account remoto, "apri con").
    private func importSingleFile(_ url: URL, into context: NSManagedObjectContext) {
        let ext = url.pathExtension
        guard let format = ComicFormat(fileExtension: ext) else {
            reportError("Formato non supportato: .\(ext)")
            return
        }

        do {
            let relativePath = try LibraryStorage.importFile(from: url)
            registerComic(relativePath: relativePath, format: format, into: context)
        } catch {
            reportError(error.localizedDescription)
        }
    }

    /// Quanto si ricava aprendo l'archivio di un fumetto. Nessun oggetto Core Data dentro:
    /// l'analisi è la parte lenta e vive fuori dal contesto, l'inserimento è a parte.
    struct ComicAnalysis {
        let pageCount: Int
        let coverData: Data?
        let metadata: ComicInfoMetadata?
    }

    /// Apre l'archivio e ne ricava pagine, copertina e metadati ComicInfo. `nil` se il file non
    /// è apribile (archivio corrotto o protetto): il chiamante decide se registrarlo comunque.
    ///
    /// Costosa: decomprime la pagina 0 per intero. Non va mai chiamata su un file che è ancora
    /// un segnaposto iCloud — vedi `registerComic`.
    static func analyzeComic(at url: URL, format: ComicFormat) -> ComicAnalysis? {
        guard let provider = try? ComicPageProviderFactory.makeProvider(for: url, format: format) else {
            return nil
        }

        var coverData: Data?
        if provider.pageCount > 0 {
            let rawCoverData = (try? provider.rawData(atPage: 0)).flatMap { $0 }
            if let rawCoverData = rawCoverData {
                coverData = ThumbnailGenerator.makeThumbnailData(fromSourceData: rawCoverData)
            } else if let coverImage = try? provider.image(atPage: 0) {
                coverData = ThumbnailGenerator.makeThumbnailData(from: coverImage)
            }
        }

        let metadata = provider.comicInfoXML.flatMap { ComicInfoMetadata.parse(from: $0) }
        return ComicAnalysis(pageCount: provider.pageCount, coverData: coverData, metadata: metadata)
    }

    /// Titolo da mostrare: quello del ComicInfo se c'è, altrimenti serie + numero, altrimenti
    /// il nome del file. Condiviso fra la registrazione e il completamento posticipato dei
    /// segnaposto iCloud, così un fumetto non cambia titolo a seconda di quando è stato letto.
    static func displayTitle(from metadata: ComicInfoMetadata?, fallbackTitle: String) -> String {
        if let title = metadata?.title { return title }
        if let series = metadata?.series {
            return metadata?.number.map { "\(series) #\($0)" } ?? series
        }
        return fallbackTitle
    }

    /// Analizza ed inserisce in Core Data un file GIÀ presente nella cartella della libreria
    /// (nessuna copia). Usato da `rebuildLibrary`, dove il file esiste ma manca il record.
    ///
    /// Non fa nulla se quel `relativePath` è già in libreria: un file è un fumetto solo, e il
    /// controllo sta prima di aprire l'archivio perché è anche quello che evita di rigenerare
    /// le miniature di mezza libreria a ogni passata.
    func registerComic(relativePath: String, format: ComicFormat, into context: NSManagedObjectContext) {
        guard !isRegistered(relativePath: relativePath, in: context) else { return }

        let destinationURL = LibraryStorage.fileURL(forRelativePath: relativePath)
        let defaultDirectionRawValue = UserDefaults.standard.string(forKey: "defaultReadingDirection")
        let defaultDirection = ReadingDirection(rawValue: defaultDirectionRawValue ?? "") ?? .leftToRight

        // Un fumetto iCloud non ancora scaricato si registra "vuoto", senza aprire l'archivio:
        // leggerlo ne forzerebbe la materializzazione, cioè il download completo del file — e
        // con una libreria appena sincronizzata significa scaricare decine di fumetti in serie,
        // senza che l'utente l'abbia chiesto e senza che i download compaiano da nessuna parte.
        // Copertina e numero pagine li mette `backfillPlaceholderMetadata` quando il file arriva.
        let isPlaceholder = LibraryStorage.isPendingDownload(destinationURL)
        let analysis = isPlaceholder ? nil : Self.analyzeComic(at: destinationURL, format: format)

        let pageCount = analysis?.pageCount ?? 0
        let coverData = analysis?.coverData
        let metadata = analysis?.metadata

        let fallbackTitle = (relativePath as NSString).deletingPathExtension
        let title = Self.displayTitle(from: metadata, fallbackTitle: fallbackTitle)
        let seriesName = metadata?.series ?? Self.deriveSeriesName(fromFallbackTitle: fallbackTitle)

        context.performAndWait {
            // Ricontrollo dopo la lettura dell'archivio: aprirlo e generare la miniatura può
            // durare secondi, abbastanza perché nel frattempo lo stesso path sia arrivato da
            // CloudKit e sia stato unito in questo contesto.
            guard !isRegisteredWithinContext(relativePath: relativePath, in: context) else { return }
            let comic = ComicEntity.create(
                title: title,
                seriesName: seriesName,
                relativePath: relativePath,
                format: format,
                readingDirection: defaultDirection,
                in: context
            )
            comic.pageCount = Int32(pageCount)
            comic.coverImageData = coverData
            try? context.save()
            if isPlaceholder {
                DiagnosticLog.log("Registrato \"\(title)\" (\(format.rawValue), da scaricare da iCloud)")
            } else {
                DiagnosticLog.log("Importato \"\(title)\" (\(format.rawValue), \(pageCount) pagine)")
            }
        }
    }

    func isRegistered(relativePath: String, in context: NSManagedObjectContext) -> Bool {
        var found = false
        context.performAndWait {
            found = isRegisteredWithinContext(relativePath: relativePath, in: context)
        }
        return found
    }

    /// Da chiamare già dentro un `perform` del contesto.
    private func isRegisteredWithinContext(relativePath: String, in context: NSManagedObjectContext) -> Bool {
        let request = ComicEntity.fetchRequest()
        request.predicate = NSPredicate(format: "relativePath == %@", relativePath)
        request.fetchLimit = 1
        return ((try? context.count(for: request)) ?? 0) > 0
    }

    /// Molti CBZ/CBR scansionati non hanno un ComicInfo.xml con la serie: senza un fallback,
    /// finirebbero tutti ammassati in "Altri fumetti" invece che raggruppati per testata. Se il
    /// titolo finisce con un numero (es. "Topolino 3595"), lo togliamo e usiamo il resto come
    /// nome serie ("Topolino"). Prima però si tolgono le decorazioni di coda dei rilasci
    /// scansionati (vedi `LibraryGrouping.titleWithoutTrailingDecorations`), altrimenti un
    /// "Topolino 3652 (Panini 2025-11-19) [c2c CPPD]" non finirebbe con un numero e resterebbe
    /// senza serie.
    static func deriveSeriesName(fromFallbackTitle title: String) -> String? {
        let title = LibraryGrouping.titleWithoutTrailingDecorations(title)
        guard let range = title.range(of: #"\s+#?\d+\s*$"#, options: .regularExpression) else { return nil }
        let series = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        return series.isEmpty ? nil : series
    }

    private func reportError(_ message: String) {
        DiagnosticLog.log("Errore import: \(message)")
        DispatchQueue.main.async {
            self.importError = message
        }
    }

    /// Una pila, non un contatore: un import esplicito può partire mentre una scansione
    /// automatica è ancora in corso sulla stessa `workQueue`, e la prima che finisce non deve
    /// spegnere l'indicatore mentre l'altra sta ancora lavorando. Tenere anche il testo di
    /// ciascuna operazione (e non solo quante sono) serve alle passate lunghe: possono
    /// aggiornare il proprio conteggio anche mentre un'altra ha temporaneamente l'etichetta, e
    /// quando questa finisce l'indicatore torna alla frase giusta invece di restare congelato
    /// su quella di un'operazione ormai conclusa.
    @discardableResult
    private func beginStatus(_ text: String) -> Int {
        pendingLock.lock()
        nextStatusToken += 1
        let token = nextStatusToken
        statusStack.append((token: token, text: text))
        pendingLock.unlock()
        publishStatus(text)
        return token
    }

    /// Cambia il testo dell'operazione `token` senza toccare la pila. Pubblica solo se quella
    /// operazione è in cima, cioè se è la sua etichetta a essere visibile in questo momento.
    private func updateStatus(_ text: String, token: Int) {
        pendingLock.lock()
        guard let index = statusStack.firstIndex(where: { $0.token == token }) else {
            pendingLock.unlock()
            return
        }
        statusStack[index].text = text
        let isVisible = index == statusStack.count - 1
        pendingLock.unlock()
        guard isVisible else { return }
        publishStatus(text)
    }

    private func endStatus(token: Int) {
        pendingLock.lock()
        statusStack.removeAll { $0.token == token }
        let resumed = statusStack.last?.text
        pendingLock.unlock()
        publishStatus(resumed)
    }

    private func publishStatus(_ status: String?) {
        let apply = {
            self.importStatus = status
            self.isImporting = status != nil
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    /// Il file viene rimosso solo se nessun altro record punta allo stesso `relativePath`:
    /// finché esistono record duplicati (vedi `deduplicateComics`), cancellarne uno cancellerebbe
    /// il file condiviso e lascerebbe il gemello a puntare nel vuoto — fumetto sparito.
    func delete(_ comic: ComicEntity, from context: NSManagedObjectContext) {
        let relativePath = comic.relativePath ?? ""
        context.delete(comic)
        try? context.save()

        guard shouldRemoveFile(forRelativePath: relativePath, in: context) else { return }
        LibraryStorage.removeFile(relativePath: relativePath)
    }

    /// Il file su disco è uno solo e i record duplicati se lo dividono: si può cancellare
    /// soltanto quando in libreria non ne resta più nessuno che lo referenzia.
    func shouldRemoveFile(forRelativePath relativePath: String, in context: NSManagedObjectContext) -> Bool {
        guard !relativePath.isEmpty else { return false }
        return !isRegistered(relativePath: relativePath, in: context)
    }

    /// Passata di sola deduplica, senza scansione del disco: serve perché i duplicati possono
    /// arrivare da CloudKit anche quando la cartella di sincronizzazione è disattivata e quindi
    /// `rebuildLibrary` non gira mai.
    func deduplicateLibrary(context: NSManagedObjectContext) {
        let backgroundContext = sharedScanContext(for: context)
        enqueue(.deduplicate) { [weak self] in
            self?.deduplicateComics(in: backgroundContext)
            self?.backfillSeriesNames(in: backgroundContext)
        }
    }

    // MARK: - Scansioni automatiche

    /// Accoda `work` sulla coda seriale saltando le richieste già in attesa dello stesso tipo.
    private func enqueue(_ kind: ScanKind, _ work: @escaping () -> Void) {
        pendingLock.lock()
        let alreadyQueued = pendingScans.contains(kind)
        pendingScans.insert(kind)
        pendingLock.unlock()
        guard !alreadyQueued else { return }

        workQueue.async { [weak self] in
            self?.pendingLock.lock()
            self?.pendingScans.remove(kind)
            self?.pendingLock.unlock()
            work()
        }
    }

    /// Registra in libreria i fumetti trascinati nella cartella Documents dell'app dal Finder
    /// (`UIFileSharingEnabled`, device collegato via USB → tab "File") o da Files.
    ///
    /// È volutamente separata da `rebuildLibrary`, non un suo caso particolare: quella cancella i
    /// record il cui file non esiste più, e su una libreria iCloud i file non ancora scaricati
    /// possono benissimo non esistere su disco. Questo passaggio invece è solo additivo, quindi
    /// può girare a ogni foreground senza gate su iCloud e senza rischiare di svuotare la libreria.
    func adoptFilesDroppedInDocuments(context: NSManagedObjectContext) {
        let backgroundContext = sharedScanContext(for: context)
        enqueue(.adopt) { [weak self] in
            self?.performAdoptFilesDroppedInDocuments(in: backgroundContext)
        }
    }

    func performAdoptFilesDroppedInDocuments(in context: NSManagedObjectContext) {
        let candidates = LibraryStorage.adoptFilesDroppedInLocalDocuments()
        guard !candidates.isEmpty else { return }

        var knownPaths: Set<String> = []
        context.performAndWait {
            let request = ComicEntity.fetchRequest()
            guard let comics = try? context.fetch(request) else { return }
            knownPaths = Set(comics.compactMap { $0.relativePath })
        }

        let newPaths = candidates.filter { !knownPaths.contains($0) }
        guard !newPaths.isEmpty else { return }

        let statusToken = beginStatus(newPaths.count == 1 ? "Aggiungo 1 fumetto…" : "Aggiungo \(newPaths.count) fumetti…")
        defer { endStatus(token: statusToken) }
        let startedAt = Date()
        for (index, relativePath) in newPaths.enumerated() {
            if newPaths.count > 1 {
                updateStatus("Aggiungo \(index + 1) di \(newPaths.count)…", token: statusToken)
            }
            guard let format = ComicFormat(fileExtension: (relativePath as NSString).pathExtension) else { continue }
            registerComic(relativePath: relativePath, format: format, into: context)
        }
        DiagnosticLog.log("File Sharing: aggiunti \(newPaths.count) fumetti dalla cartella Documents in \(Self.formatted(duration: Date().timeIntervalSince(startedAt)))")
        deduplicateComics(in: context)
        backfillSeriesNames(in: context)
    }

    /// Strumento di recupero: rimuove dalla libreria i fumetti il cui file non esiste più
    /// (es. cancellato manualmente dal Finder/Files), e registra i file trovati nella cartella
    /// della libreria ma non ancora presenti — utile dopo un ripristino da backup o un problema
    /// di sincronizzazione.
    func rebuildLibrary(context: NSManagedObjectContext) {
        let backgroundContext = sharedScanContext(for: context)
        enqueue(.rebuild) { [weak self] in
            self?.performRebuildLibrary(in: backgroundContext)
        }
    }

    func performRebuildLibrary(in context: NSManagedObjectContext) {
        var removedCount = 0
        var knownPaths: Set<String> = []
        context.performAndWait {
            let request = ComicEntity.fetchRequest()
            guard let comics = try? context.fetch(request) else { return }
            for comic in comics {
                let path = comic.relativePath ?? ""
                let url = LibraryStorage.fileURL(forRelativePath: path)
                if path.isEmpty || !FileManager.default.fileExists(atPath: url.path) {
                    context.delete(comic)
                    removedCount += 1
                } else {
                    knownPaths.insert(path)
                }
            }
            try? context.save()
        }

        let root = LibraryStorage.rootFolderURL()
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let unknownComicFiles = files.filter { url in
            ComicFormat(fileExtension: url.pathExtension) != nil && !knownPaths.contains(url.lastPathComponent)
        }

        // L'indicatore si accende solo ora, non all'inizio della passata: la scansione gira a ogni
        // foreground e ogni 3 minuti, e quasi sempre non trova niente da fare — mostrare
        // "Importazione…" in quei casi lasciava l'utente davanti a un banner senza spiegazione.
        let statusToken = unknownComicFiles.isEmpty
            ? nil
            : beginStatus(unknownComicFiles.count == 1 ? "Aggiungo 1 fumetto…" : "Aggiungo \(unknownComicFiles.count) fumetti…")
        defer { if let statusToken = statusToken { endStatus(token: statusToken) } }

        let startedAt = Date()
        for (index, url) in unknownComicFiles.enumerated() {
            if let statusToken = statusToken, unknownComicFiles.count > 1 {
                updateStatus("Aggiungo \(index + 1) di \(unknownComicFiles.count)…", token: statusToken)
            }
            guard let format = ComicFormat(fileExtension: url.pathExtension) else { continue }
            registerComic(relativePath: url.lastPathComponent, format: format, into: context)
        }

        if removedCount > 0 || !unknownComicFiles.isEmpty {
            let elapsed = Self.formatted(duration: Date().timeIntervalSince(startedAt))
            DiagnosticLog.log("Rebuild library: rimossi \(removedCount), ritrovati \(unknownComicFiles.count) in \(elapsed)")
        }

        deduplicateComics(in: context)
        backfillSeriesNames(in: context)
    }

    // MARK: - Completamento dei segnaposto iCloud

    /// Riempie copertina, numero pagine e metadati dei fumetti registrati come segnaposto
    /// iCloud (vedi `registerComic`), ora che i loro byte sono arrivati in locale.
    func backfillPlaceholderMetadata(context: NSManagedObjectContext) {
        let backgroundContext = sharedScanContext(for: context)
        enqueue(.placeholderMetadata) { [weak self] in
            self?.performBackfillPlaceholderMetadata(in: backgroundContext)
        }
    }

    func performBackfillPlaceholderMetadata(in context: NSManagedObjectContext) {
        var candidates: [(objectID: NSManagedObjectID, relativePath: String, format: ComicFormat)] = []
        context.performAndWait {
            let request = ComicEntity.fetchRequest()
            // Solo la copertina, non anche "pageCount == 0": aprendo il fumetto appena scaricato
            // il lettore scrive già il numero di pagine (vedi `ReaderView.openProvider`), e con
            // quella seconda condizione il record smetteva di essere un candidato restando senza
            // copertina fino a un reinstallo. Un fumetto in libreria senza copertina è per
            // definizione uno da completare, qualunque strada l'abbia portato lì.
            //
            // Non serve un attributo dedicato nel modello: sarebbe uno stato locale del
            // dispositivo che CloudKit sincronizzerebbe sugli altri, dove il file magari è già
            // scaricato.
            request.predicate = NSPredicate(format: "coverImageData == nil")
            guard let comics = try? context.fetch(request) else { return }
            for comic in comics {
                guard let relativePath = comic.relativePath, !relativePath.isEmpty else { continue }
                guard !pathsWithUnreadableArchive.contains(relativePath) else { continue }
                let url = LibraryStorage.fileURL(forRelativePath: relativePath)
                guard FileManager.default.fileExists(atPath: url.path),
                      !LibraryStorage.isPendingDownload(url) else { continue }
                candidates.append((comic.objectID, relativePath, comic.format))
            }
        }
        guard !candidates.isEmpty else { return }

        let statusToken = beginStatus(candidates.count == 1
            ? "Preparo 1 fumetto…"
            : "Preparo \(candidates.count) fumetti…")
        defer { endStatus(token: statusToken) }

        let startedAt = Date()
        var completed = 0
        for (index, candidate) in candidates.enumerated() {
            if candidates.count > 1 {
                updateStatus("Preparo \(index + 1) di \(candidates.count)…", token: statusToken)
            }
            let url = LibraryStorage.fileURL(forRelativePath: candidate.relativePath)
            // Un archivio che si apre ma da cui non esce una copertina lascerebbe il record
            // candidato anche alla prossima passata: per questa lista vale come illeggibile,
            // altrimenti ogni scansione lo riaprirebbe per niente.
            let analysis = Self.analyzeComic(at: url, format: candidate.format)
            guard let analysis = analysis, analysis.coverData != nil else {
                pathsWithUnreadableArchive.insert(candidate.relativePath)
                DiagnosticLog.log("Nessuna copertina ricavabile da \"\(candidate.relativePath)\"")
                continue
            }
            apply(analysis, toComicWith: candidate.objectID, relativePath: candidate.relativePath, in: context)
            completed += 1
        }

        if completed > 0 {
            let elapsed = Self.formatted(duration: Date().timeIntervalSince(startedAt))
            DiagnosticLog.log("Completati \(completed) fumetti scaricati da iCloud in \(elapsed)")
        }
    }

    /// Il titolo viene riscritto solo se il ComicInfo ne propone uno diverso dal nome del file:
    /// altrimenti un fumetto che l'utente ha già visto in griglia cambierebbe nome da solo.
    private func apply(
        _ analysis: ComicAnalysis,
        toComicWith objectID: NSManagedObjectID,
        relativePath: String,
        in context: NSManagedObjectContext
    ) {
        context.performAndWait {
            guard let comic = try? context.existingObject(with: objectID) as? ComicEntity else { return }
            comic.pageCount = Int32(analysis.pageCount)
            comic.coverImageData = analysis.coverData

            let fallbackTitle = (relativePath as NSString).deletingPathExtension
            let title = Self.displayTitle(from: analysis.metadata, fallbackTitle: fallbackTitle)
            if title != fallbackTitle {
                comic.title = title
            }
            if let series = analysis.metadata?.series {
                comic.seriesName = series
            }
            try? context.save()
        }
    }

    /// Durata leggibile per il log di Diagnostica: distinguere "12s" da "4m 30s" dice subito se
    /// una passata lenta è analisi degli archivi o attesa della rete.
    static func formatted(duration: TimeInterval) -> String {
        let seconds = Int(duration.rounded())
        guard seconds >= 60 else { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }
}
