import Foundation
import Combine

/// An in-progress download, shown in the "Downloads" screen: from a remote account
/// (WebDAV/OPDS, backed by a `URLSessionTask`) or an iCloud comic not yet downloaded
/// locally (no system task underneath — progress is updated by hand via `updateProgress`).
final class DownloadItem: ObservableObject, Identifiable {
    let id = UUID()
    let title: String
    @Published var fractionCompleted: Double = 0
    @Published private(set) var isCancelled = false

    private let task: URLSessionTask?
    private var observation: NSKeyValueObservation?

    /// `task` is nil for downloads with no `URLSessionTask` underneath (e.g. from iCloud): in that
    /// case progress arrives from external polling via `updateProgress` instead of from KVO.
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

/// Keeps track of active downloads — from remote accounts (WebDAV/OPDS) and iCloud comics
/// not yet downloaded locally that were opened from the reader — shown in the "Downloads"
/// screen reached from Accounts. A single registration point per type (`RemoteBrowsing.downloadFile`,
/// `ReaderView.loadComic`) adds/removes entries, so any client ends up here.
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var activeDownloads: [DownloadItem] = []

    /// Already-active downloads indexed by `key` (e.g. the iCloud comic's path): reopening
    /// the same comic while it's downloading must hook into the download in progress, not
    /// start a second one with a second row in the Downloads screen.
    private var itemsByKey: [String: DownloadItem] = [:]

    private init() {}

    /// `task` is nil for downloads with no `URLSessionTask` underneath (e.g. an iCloud comic not
    /// yet downloaded). `key` identifies the downloaded resource: if a download with the same
    /// key is already in progress, the existing one is returned. With `key` nil there's no
    /// deduplication (two distinct downloads without a key stay as two separate entries).
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
        // It also needs to be removed from the map, otherwise a cancelled download would stay
        // cached and the next time the same comic is opened it would receive an item already
        // `isCancelled`, failing immediately without ever restarting the download.
        itemsByKey = itemsByKey.filter { $0.value.id != item.id }
    }

    func stopAll() {
        for item in activeDownloads {
            item.cancel()
        }
        itemsByKey.removeAll()
    }
}
