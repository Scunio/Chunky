import Foundation
import Combine

/// Tiene aggiornato l'elenco dei fumetti della libreria che su questo dispositivo sono ancora
/// solo placeholder iCloud (non scaricati in locale), usato dalla griglia per il badge
/// "da scaricare". Serve una `NSMetadataQuery` viva: lo stato di un file può cambiare anche
/// senza che l'app faccia nulla (download avviato dall'app File o dal sistema), e leggendo il
/// filesystem solo quando la vista appare il badge resterebbe indietro.
///
/// `NSMetadataQuery` consegna gli aggiornamenti sulla coda impostata in `operationQueue`
/// (qui `.main`): va quindi avviata e fermata dal thread principale.
final class ICloudDownloadTracker: ObservableObject {
    static let shared = ICloudDownloadTracker()

    /// Percorsi relativi (le stesse stringhe salvate in `ComicEntity.relativePath`) dei file
    /// non ancora scaricati. Vuoto se iCloud non è attivo: in quel caso i file sono tutti locali.
    @Published private(set) var pendingRelativePaths: Set<String> = []

    private let query = NSMetadataQuery()
    private var isRunning = false

    private init() {}

    func start() {
        guard !isRunning, LibraryStorage.isICloudAvailable else { return }
        isRunning = true
        // Nessun predicato sul percorso della cartella: il path riportato dalla query può essere
        // la forma `/private/var/...` mentre quello della libreria è `/var/...`, e un
        // BEGINSWITH fallirebbe silenziosamente restituendo zero risultati. Si filtra invece
        // sui risultati, confrontando i percorsi risolti.
        query.predicate = NSPredicate(format: "%K LIKE '*'", NSMetadataItemFSNameKey)
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.operationQueue = .main
        NotificationCenter.default.addObserver(self, selector: #selector(handleUpdate), name: .NSMetadataQueryDidUpdate, object: query)
        NotificationCenter.default.addObserver(self, selector: #selector(handleUpdate), name: .NSMetadataQueryDidFinishGathering, object: query)
        query.start()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        query.stop()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleUpdate() {
        let rootPath = LibraryStorage.rootFolderURL().resolvingSymlinksInPath().standardizedFileURL.path
        var pending: Set<String> = []

        query.disableUpdates()
        for case let item as NSMetadataItem in query.results {
            guard let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL else { continue }
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
            guard status != NSMetadataUbiquitousItemDownloadingStatusCurrent else { continue }
            pending.insert(String(path.dropFirst(rootPath.count + 1)))
        }
        query.enableUpdates()

        if pending != pendingRelativePaths {
            pendingRelativePaths = pending
        }
    }
}
