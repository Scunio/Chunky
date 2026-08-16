import Foundation

/// Gestisce la cartella fisica in cui vengono copiati i fumetti importati.
/// Se l'utente ha iCloud Drive attivo, usa il container ubiquity dell'app (i file
/// sincronizzano automaticamente su tutti i dispositivi); altrimenti ricade sulla
/// cartella Documents locale della sandbox.
enum LibraryStorage {
    private static let ubiquityContainerID = "iCloud.com.scunio.Chunky"
    private static let comicsFolderName = "Comics"

    nonisolated(unsafe) private static var cachedRootURL: URL?

    /// True se l'utente ha iCloud Drive attivo e il container ubiquity dell'app è raggiungibile:
    /// in tal caso i fumetti importati sincronizzano automaticamente su tutti i dispositivi.
    static var isICloudAvailable: Bool {
        FileManager.default.url(forUbiquityContainerIdentifier: ubiquityContainerID) != nil
    }

    static func rootFolderURL() -> URL {
        if let cached = cachedRootURL {
            return cached
        }
        let root: URL
        if let ubiquityURL = FileManager.default.url(forUbiquityContainerIdentifier: ubiquityContainerID) {
            // La cartella root deve essere "Documents" (non un livello sotto, es.
            // "Documents/Comics"): il messaggio mostrato all'utente in ICloudSyncFolderView dice
            // di mettere i fumetti direttamente "dentro Chunky", quindi il comportamento reale
            // deve allinearsi a quel messaggio.
            root = ubiquityURL.appendingPathComponent("Documents")
        } else {
            root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        migrateLegacyComicsSubfolderIfNeeded(newRoot: root)
        cachedRootURL = root
        return root
    }

    /// Sposta alla radice i fumetti lasciati da un layout di cartelle precedente nella
    /// sottocartella "Comics" (vedi il commento in `rootFolderURL()`): senza questo passaggio, chi aveva già
    /// una libreria se la ritroverebbe "sparita" al primo avvio dopo l'update, pur restando i
    /// file fisicamente presenti su iCloud/disco. In caso di collisione di nome (es. un file che
    /// l'utente aveva già messo per sbaglio alla radice) rinomina l'arrivo, con lo stesso schema
    /// usato da `importFile`.
    private static func migrateLegacyComicsSubfolderIfNeeded(newRoot: URL) {
        let legacyRoot = newRoot.appendingPathComponent(comicsFolderName)
        guard FileManager.default.fileExists(atPath: legacyRoot.path) else { return }

        let items = (try? FileManager.default.contentsOfDirectory(at: legacyRoot, includingPropertiesForKeys: nil)) ?? []
        for item in items {
            let destinationURL = availableDestination(forFileNamed: item.lastPathComponent, in: newRoot)
            try? FileManager.default.moveItem(at: item, to: destinationURL)
        }
        try? FileManager.default.removeItem(at: legacyRoot)
    }

    /// Percorso libero dentro `folder` per un file di nome `fileName`: se il nome è già occupato
    /// aggiunge un progressivo ("Topolino 1.cbz"). Unica implementazione per tutti i punti in cui
    /// un file entra nella libreria, così i duplicati si comportano allo stesso modo ovunque.
    private static func availableDestination(forFileNamed fileName: String, in folder: URL) -> URL {
        var destinationURL = folder.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: destinationURL.path) else { return destinationURL }

        let baseName = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var suffix = 1
        repeat {
            destinationURL = folder.appendingPathComponent("\(baseName) \(suffix).\(ext)")
            suffix += 1
        } while FileManager.default.fileExists(atPath: destinationURL.path)
        return destinationURL
    }

    /// Il Finder copia nella cartella Documents mentre l'app è viva, quindi un file può essere
    /// ancora a metà trasferimento nel momento in cui lo troviamo: spostarlo o aprirlo adesso
    /// significherebbe troncare la copia o registrare in libreria un archivio illeggibile.
    /// Chi è stato scritto negli ultimi secondi viene lasciato dov'è: lo riprende il passaggio
    /// successivo (foreground o rescan periodico), quindi saltarlo non lo perde.
    private static func isBeingWritten(_ url: URL) -> Bool {
        guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
            return false
        }
        return Date().timeIntervalSince(modified) < 5
    }

    /// Cartella Documents locale della sandbox. È quella che iOS espone in Files e nella tab
    /// "File" del Finder grazie a `UIFileSharingEnabled`, quindi è dove atterrano i fumetti
    /// trascinati dal Mac con il device collegato via USB. Coincide con `rootFolderURL()` solo
    /// quando iCloud Drive non è disponibile: con iCloud attivo la libreria vive nel container
    /// ubiquity, e senza `adoptFilesDroppedInLocalDocuments()` i file trascinati resterebbero
    /// qui senza mai comparire in libreria.
    static var localDocumentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Porta nella libreria i fumetti lasciati nella Documents locale e restituisce i loro
    /// percorsi relativi alla root, pronti per la registrazione in Core Data. Se la libreria è
    /// già quella cartella (niente iCloud) non sposta niente e li elenca dov'erano.
    /// Non cancella e non registra nulla: la deduplica contro la libreria esistente spetta al
    /// chiamante, che sa cosa c'è già in Core Data.
    static func adoptFilesDroppedInLocalDocuments() -> [String] {
        let inbox = localDocumentsURL
        let root = rootFolderURL()
        let files = (try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let comicFiles = files.filter { ComicFormat(fileExtension: $0.pathExtension) != nil && !isBeingWritten($0) }

        guard inbox.standardizedFileURL != root.standardizedFileURL else {
            return comicFiles.map { $0.lastPathComponent }
        }

        var adopted: [String] = []
        for file in comicFiles {
            let destinationURL = availableDestination(forFileNamed: file.lastPathComponent, in: root)
            do {
                try FileManager.default.moveItem(at: file, to: destinationURL)
                adopted.append(destinationURL.lastPathComponent)
            } catch {
                DiagnosticLog.log("Impossibile spostare in libreria \"\(file.lastPathComponent)\": \(error.localizedDescription)")
            }
        }
        return adopted
    }

    static func fileURL(forRelativePath relativePath: String) -> URL {
        rootFolderURL().appendingPathComponent(relativePath)
    }

    /// Copia un file scelto dall'utente (via file importer / document picker) nella libreria,
    /// gestendo eventuali nomi duplicati, e restituisce il percorso relativo salvato nel modello.
    static func importFile(from sourceURL: URL) throws -> String {
        let needsSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if needsSecurityScope { sourceURL.stopAccessingSecurityScopedResource() }
        }

        let root = rootFolderURL()
        let destinationURL = availableDestination(forFileNamed: sourceURL.lastPathComponent, in: root)
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL.lastPathComponent
    }

    static func removeFile(relativePath: String) {
        let url = fileURL(forRelativePath: relativePath)
        try? FileManager.default.removeItem(at: url)
    }

    /// Su un secondo dispositivo un file nella libreria iCloud può essere solo un
    /// placeholder non ancora scaricato: lo richiede e attende (bloccando, va quindi
    /// chiamata fuori dal thread principale) prima che venga aperto come archivio.
    static func ensureDownloaded(_ url: URL, timeout: TimeInterval = 30) throws {
        guard FileManager.default.isUbiquitousItem(at: url) else { return }

        func currentStatus() -> URLUbiquitousItemDownloadingStatus? {
            try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
        }

        if currentStatus() == .current { return }

        try FileManager.default.startDownloadingUbiquitousItem(at: url)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if currentStatus() == .current { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw ComicReadError.notDownloaded
    }

    /// Vero se `url` è un fumetto iCloud i cui byte non sono ancora tutti in locale
    /// (placeholder non scaricato). Usata in libreria per mostrare un badge "da scaricare".
    static func isPendingDownload(_ url: URL) -> Bool {
        guard FileManager.default.isUbiquitousItem(at: url) else { return false }
        let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
        return status != .current
    }

    /// Come `ensureDownloaded`, ma senza timeout fisso: riporta la percentuale reale via
    /// `onProgress` (0...1), tramite `NSMetadataQuery` — le resourceValues su `URL` da sole non
    /// espongono l'avanzamento byte-per-byte su iOS, solo lo stato (scaricato o no).
    /// `isCancelled` viene controllato periodicamente per permettere l'annullamento manuale.
    static func downloadIfNeeded(
        _ url: URL,
        isCancelled: @escaping () -> Bool = { false },
        onProgress: @escaping (Double) -> Void
    ) throws {
        guard isPendingDownload(url) else { onProgress(1); return }

        try FileManager.default.startDownloadingUbiquitousItem(at: url)

        let semaphore = DispatchSemaphore(value: 0)
        var downloadError: Error?
        let observer = UbiquitousDownloadObserver(url: url, onProgress: onProgress) { error in
            downloadError = error
            semaphore.signal()
        }
        DispatchQueue.main.async { observer.start() }

        while semaphore.wait(timeout: .now() + 0.25) == .timedOut {
            if isCancelled() {
                DispatchQueue.main.async { observer.stop() }
                throw ComicReadError.downloadCancelled
            }
        }
        DispatchQueue.main.async { observer.stop() }
        if let downloadError = downloadError { throw downloadError }
    }

    /// Include o esclude la cartella della libreria dai backup di iCloud/iTunes. Rilevante solo
    /// quando si ricade sulla cartella locale (senza iCloud Drive attivo, quella iCloud è già
    /// gestita dalla sincronizzazione stessa).
    static func setExcludedFromBackup(_ excluded: Bool) {
        var url = rootFolderURL()
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = excluded
        try? url.setResourceValues(resourceValues)
    }
}

/// Segue l'avanzamento di un singolo download iCloud con `NSMetadataQuery` (l'unica API che
/// espone la percentuale byte-per-byte, non solo lo stato "scaricato/non scaricato").
/// `NSMetadataQuery` consegna i suoi aggiornamenti sulla coda impostata in `operationQueue`
/// (qui `.main`): va quindi avviata/fermata dal thread principale.
private final class UbiquitousDownloadObserver: NSObject {
    private let query = NSMetadataQuery()
    private let url: URL
    private let onProgress: (Double) -> Void
    private let onFinish: (Error?) -> Void

    init(url: URL, onProgress: @escaping (Double) -> Void, onFinish: @escaping (Error?) -> Void) {
        self.url = url
        self.onProgress = onProgress
        self.onFinish = onFinish
        super.init()
    }

    func start() {
        query.predicate = NSPredicate(format: "%K == %@", NSMetadataItemURLKey, url as NSURL)
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope, NSMetadataQueryUbiquitousDataScope]
        query.operationQueue = .main
        NotificationCenter.default.addObserver(self, selector: #selector(handleUpdate), name: .NSMetadataQueryDidUpdate, object: query)
        NotificationCenter.default.addObserver(self, selector: #selector(handleUpdate), name: .NSMetadataQueryDidFinishGathering, object: query)
        query.start()
    }

    func stop() {
        query.stop()
        // Rimozione mirata invece di `removeObserver(self)`: questa classe osserva solo la
        // propria query, e la rimozione in blocco cancellerebbe anche eventuali altre
        // osservazioni registrate altrove sullo stesso oggetto.
        NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidUpdate, object: query)
        NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: query)
    }

    @objc private func handleUpdate() {
        guard let item = query.results.first as? NSMetadataItem else { return }
        if let percent = item.value(forAttribute: NSMetadataUbiquitousItemPercentDownloadedKey) as? Double {
            onProgress(percent / 100)
        }
        let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
        if status == NSMetadataUbiquitousItemDownloadingStatusCurrent {
            onProgress(1)
            onFinish(nil)
        }
    }
}
