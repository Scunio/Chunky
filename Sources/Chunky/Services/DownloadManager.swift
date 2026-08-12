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

    private init() {}

    /// `task` è nil per i download senza `URLSessionTask` sotto (es. un fumetto iCloud non
    /// ancora scaricato).
    func register(title: String, task: URLSessionTask? = nil) -> DownloadItem {
        let item = DownloadItem(title: title, task: task)
        activeDownloads.append(item)
        return item
    }

    func remove(_ item: DownloadItem) {
        activeDownloads.removeAll { $0.id == item.id }
    }

    func stopAll() {
        for item in activeDownloads {
            item.cancel()
        }
    }
}
