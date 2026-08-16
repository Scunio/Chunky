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
    /// Quante operazioni stanno mostrando l'indicatore di caricamento (vedi `beginStatus`).
    private var statusDepth = 0

    private enum ScanKind: Hashable {
        case rebuild
        case adopt
        case deduplicate
    }

    // MARK: - Import esplicito

    func importFiles(_ urls: [URL], into context: NSManagedObjectContext) {
        let backgroundContext = sharedScanContext(for: context)
        beginStatus(urls.count == 1 ? "Importazione…" : "Importazione di \(urls.count) fumetti…")

        workQueue.async { [weak self] in
            guard let self = self else { return }
            defer { self.endStatus() }
            for url in urls {
                self.importSingleFile(url, into: backgroundContext)
            }
            self.deduplicateComics(in: backgroundContext)
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

        var pageCount = 0
        var coverData: Data?
        var metadata: ComicInfoMetadata?
        if let provider = try? ComicPageProviderFactory.makeProvider(for: destinationURL, format: format) {
            pageCount = provider.pageCount
            if provider.pageCount > 0 {
                let rawCoverData = (try? provider.rawData(atPage: 0)).flatMap { $0 }
                if let rawCoverData = rawCoverData {
                    coverData = ThumbnailGenerator.makeThumbnailData(fromSourceData: rawCoverData)
                } else if let coverImage = try? provider.image(atPage: 0) {
                    coverData = ThumbnailGenerator.makeThumbnailData(from: coverImage)
                }
            }
            if let xml = provider.comicInfoXML {
                metadata = ComicInfoMetadata.parse(from: xml)
            }
        }

        let fallbackTitle = (relativePath as NSString).deletingPathExtension
        let title = metadata?.title ?? metadata?.series.map { series in
            metadata?.number.map { "\(series) #\($0)" } ?? series
        } ?? fallbackTitle

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
            DiagnosticLog.log("Importato \"\(title)\" (\(format.rawValue), \(pageCount) pagine)")
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
    /// nome serie ("Topolino").
    static func deriveSeriesName(fromFallbackTitle title: String) -> String? {
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

    /// Contate, non booleane: un import esplicito può partire mentre una scansione automatica è
    /// ancora in coda sulla stessa `workQueue`, e la prima che finisce non deve spegnere
    /// l'indicatore mentre l'altra sta ancora lavorando.
    private func beginStatus(_ text: String) {
        pendingLock.lock()
        statusDepth += 1
        pendingLock.unlock()
        publishStatus(text)
    }

    private func endStatus() {
        pendingLock.lock()
        statusDepth = max(0, statusDepth - 1)
        let isIdle = statusDepth == 0
        pendingLock.unlock()
        guard isIdle else { return }
        publishStatus(nil)
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

    // MARK: - Deduplica

    /// Collassa i record che puntano allo stesso file. Ne servono due sorgenti: le scansioni
    /// sovrapposte (ora serializzate, ma i duplicati già creati restano) e i due dispositivi —
    /// iPad e Mac creano ciascuno il proprio `ComicEntity` per lo stesso file nel container
    /// iCloud, e CloudKit sincronizza entrambi i record.
    ///
    /// Non tocca MAI i file: il file è uno solo ed è quello che i record duplicati condividono.
    @discardableResult
    func deduplicateComics(in context: NSManagedObjectContext) -> Int {
        var collapsed = 0
        context.performAndWait {
            guard let duplicatePaths = duplicateRelativePaths(in: context), !duplicatePaths.isEmpty else { return }

            let request = ComicEntity.fetchRequest()
            request.predicate = NSPredicate(format: "relativePath IN %@", duplicatePaths)
            // Il contesto di scansione vive quanto l'app e può avere in memoria questi oggetti da
            // una passata precedente: senza forzare il refresh, la fusione leggerebbe i valori
            // vecchi e butterebbe via il progresso di lettura arrivato nel frattempo da CloudKit.
            request.shouldRefreshRefetchedObjects = true
            guard let comics = try? context.fetch(request) else { return }

            for (path, group) in Dictionary(grouping: comics, by: { $0.relativePath ?? "" }) where group.count > 1 {
                let ordered = group.sorted(by: Self.precedesAsSurvivor)
                guard let survivor = ordered.first else { continue }
                for loser in ordered.dropFirst() {
                    Self.merge(loser, into: survivor)
                    context.delete(loser)
                    collapsed += 1
                }
                DiagnosticLog.log("Deduplica: \(group.count) record per \"\(path)\", ne resta 1")
            }

            if collapsed > 0 { try? context.save() }
        }
        if collapsed > 0 {
            DiagnosticLog.log("Deduplica libreria: rimossi \(collapsed) record duplicati")
        }
        return collapsed
    }

    /// Solo i path con più di un record, letti come dizionari: caricare tutti i `ComicEntity`
    /// significherebbe tirare in memoria anche le copertine di tutta la libreria a ogni passata.
    private func duplicateRelativePaths(in context: NSManagedObjectContext) -> [String]? {
        let request = NSFetchRequest<NSDictionary>(entityName: "ComicEntity")
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = ["relativePath"]
        guard let rows = try? context.fetch(request) else { return nil }

        var counts: [String: Int] = [:]
        for row in rows {
            guard let path = row["relativePath"] as? String, !path.isEmpty else { continue }
            counts[path, default: 0] += 1
        }
        return counts.filter { $0.value > 1 }.map(\.key)
    }

    /// Ordinamento deterministico: `dateAdded` e `id` sono attributi sincronizzati, quindi iPad e
    /// Mac vedono gli stessi valori e scelgono lo stesso superstite. Se scegliessero record
    /// diversi, ognuno cancellerebbe quello che l'altro tiene e il fumetto sparirebbe da entrambi.
    private static func precedesAsSurvivor(_ lhs: ComicEntity, _ rhs: ComicEntity) -> Bool {
        let leftDate = lhs.dateAdded ?? .distantFuture
        let rightDate = rhs.dateAdded ?? .distantFuture
        if leftDate != rightDate { return leftDate < rightDate }
        return (lhs.id?.uuidString ?? "") < (rhs.id?.uuidString ?? "")
    }

    /// Fonde nel superstite quello che c'è di buono nel record scartato: senza questo passaggio la
    /// deduplica si mangerebbe il progresso di lettura fatto sull'altro dispositivo.
    private static func merge(_ source: ComicEntity, into target: ComicEntity) {
        target.lastReadPage = max(target.lastReadPage, source.lastReadPage)
        if target.pageCount <= 0 { target.pageCount = source.pageCount }
        if let opened = source.dateLastOpened, (target.dateLastOpened ?? .distantPast) < opened {
            target.dateLastOpened = opened
        }
        if target.coverImageData == nil { target.coverImageData = source.coverImageData }
        if source.isFavorite { target.isFavorite = true }
        if (target.seriesName ?? "").isEmpty { target.seriesName = source.seriesName }
        if (target.title ?? "").isEmpty { target.title = source.title }
    }

    /// Passata di sola deduplica, senza scansione del disco: serve perché i duplicati possono
    /// arrivare da CloudKit anche quando la cartella di sincronizzazione è disattivata e quindi
    /// `rebuildLibrary` non gira mai.
    func deduplicateLibrary(context: NSManagedObjectContext) {
        let backgroundContext = sharedScanContext(for: context)
        enqueue(.deduplicate) { [weak self] in
            self?.deduplicateComics(in: backgroundContext)
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

        beginStatus(newPaths.count == 1 ? "Aggiungo 1 fumetto…" : "Aggiungo \(newPaths.count) fumetti…")
        defer { endStatus() }
        for relativePath in newPaths {
            guard let format = ComicFormat(fileExtension: (relativePath as NSString).pathExtension) else { continue }
            registerComic(relativePath: relativePath, format: format, into: context)
        }
        DiagnosticLog.log("File Sharing: aggiunti \(newPaths.count) fumetti dalla cartella Documents")
        deduplicateComics(in: context)
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
        let showsIndicator = !unknownComicFiles.isEmpty
        if showsIndicator {
            beginStatus(unknownComicFiles.count == 1 ? "Aggiungo 1 fumetto…" : "Aggiungo \(unknownComicFiles.count) fumetti…")
        }
        defer { if showsIndicator { endStatus() } }

        for url in unknownComicFiles {
            guard let format = ComicFormat(fileExtension: url.pathExtension) else { continue }
            registerComic(relativePath: url.lastPathComponent, format: format, into: context)
        }

        if removedCount > 0 || !unknownComicFiles.isEmpty {
            DiagnosticLog.log("Rebuild library: rimossi \(removedCount), ritrovati \(unknownComicFiles.count)")
        }

        deduplicateComics(in: context)
    }
}
