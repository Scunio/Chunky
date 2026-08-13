import Foundation
import Combine

/// Un download in corso, mostrato nella schermata "Downloads": da un account remoto
/// (WebDAV/OPDS, con `URLSessionTask` sotto) oppure un fumetto iCloud non ancora scaricato
/// in locale (senza task di sistema — il progresso viene aggiornato a mano via `updateProgress`).
final class DownloadItem: ObservableObject, Identifiable {
    let id = UUID()
    let title: String
    @Published var fractionCompleted: Double = 0
    @Published private(set) var isCancelled = false

    private let task: URLSessionTask?
    private var observation: NSKeyValueObservation?

    /// `task` è nil per i download senza `URLSessionTask` sotto (es. da iCloud): in quel caso
    /// il progresso arriva da un polling esterno tramite `updateProgress` invece che da KVO.
    init(title: String, task: URLSessionTask? = nil) {
        self.title = title
        self.task = task
        observation = task?.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            DispatchQueue.main.async {
                self?.fractionCompleted = progress.fractionCompleted
            }
        }
    }

    func updateProgress(_ value: Double) {
        DispatchQueue.main.async { self.fractionCompleted = value }
    }

    func cancel() {
        isCancelled = true
        task?.cancel()
    }
}

/// Tiene traccia dei download attivi — da account remoti (WebDAV/OPDS) e di fumetti iCloud
/// non ancora scaricati in locale aperti dal lettore — mostrati nella schermata "Downloads"
/// raggiunta da Accounts. Un solo punto di registrazione per tipo (`RemoteBrowsing.downloadFile`,
/// `ReaderView.loadComic`) aggiunge/rimuove le voci, così qualsiasi client finisce qui.
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var activeDownloads: [DownloadItem] = []

    /// Download già attivi indicizzati per `key` (es. il percorso del fumetto iCloud): riaprire
    /// lo stesso fumetto mentre si sta scaricando deve agganciarsi al download in corso, non
    /// avviarne un secondo con una seconda riga nella schermata Downloads.
    private var itemsByKey: [String: DownloadItem] = [:]

    private init() {}

    /// `task` è nil per i download senza `URLSessionTask` sotto (es. un fumetto iCloud non
    /// ancora scaricato). `key` identifica la risorsa scaricata: se è già in corso un download
    /// con la stessa chiave viene restituito quello esistente. Con `key` nil non c'è deduplica
    /// (due download distinti senza chiave restano due voci separate).
    func register(title: String, task: URLSessionTask? = nil, key: String? = nil) -> DownloadItem {
        if let key = key, let existing = itemsByKey[key] {
            return existing
        }
        let item = DownloadItem(title: title, task: task)
        activeDownloads.append(item)
        if let key = key {
            itemsByKey[key] = item
        }
        return item
    }

    func remove(_ item: DownloadItem) {
        activeDownloads.removeAll { $0.id == item.id }
        // Va tolto anche dalla mappa, altrimenti un download annullato resterebbe in cache e
        // la successiva apertura dello stesso fumetto riceverebbe un item già `isCancelled`,
        // fallendo subito senza aver mai ricominciato a scaricare.
        itemsByKey = itemsByKey.filter { $0.value.id != item.id }
    }

    func stopAll() {
        for item in activeDownloads {
            item.cancel()
        }
        itemsByKey.removeAll()
    }
}
