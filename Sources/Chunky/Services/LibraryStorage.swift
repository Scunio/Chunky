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
            root = ubiquityURL.appendingPathComponent("Documents").appendingPathComponent(comicsFolderName)
        } else {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            root = documents.appendingPathComponent(comicsFolderName)
        }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        cachedRootURL = root
        return root
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
        var destinationName = sourceURL.lastPathComponent
        var destinationURL = root.appendingPathComponent(destinationName)

        var suffix = 1
        let baseName = (destinationName as NSString).deletingPathExtension
        let ext = (destinationName as NSString).pathExtension
        while FileManager.default.fileExists(atPath: destinationURL.path) {
            destinationName = "\(baseName) \(suffix).\(ext)"
            destinationURL = root.appendingPathComponent(destinationName)
            suffix += 1
        }

        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return destinationName
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
        NotificationCenter.default.removeObserver(self)
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
