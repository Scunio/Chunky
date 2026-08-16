import Foundation
import Combine

/// Keeps an up-to-date list of the library's comics that on this device are still
/// only iCloud placeholders (not downloaded locally), used by the grid for the
/// "to download" badge. This needs a live `NSMetadataQuery`: a file's status can change
/// even without the app doing anything (a download started from the Files app or by the
/// system), and reading the filesystem only when the view appears would leave the badge
/// out of date.
///
/// `NSMetadataQuery` delivers updates on the queue set in `operationQueue`
/// (here `.main`): it must therefore be started and stopped from the main thread.
final class ICloudDownloadTracker: ObservableObject {
    static let shared = ICloudDownloadTracker()

    /// Relative paths (the same strings stored in `ComicEntity.relativePath`) of files
    /// not yet downloaded. Empty if iCloud isn't active: in that case all files are local.
    @Published private(set) var pendingRelativePaths: Set<String> = []

    /// All relative paths seen in the ubiquity container, downloaded or not. Used by
    /// `ICloudSyncFolderView` to notice new files dropped in by another device
    /// (via Files/Finder) without a polling `Timer`: the same query that feeds the
    /// "to download" badge already enumerates everything needed.
    @Published private(set) var allRelativePaths: Set<String> = []

    private let query = NSMetadataQuery()
    private var isRunning = false

    private init() {}

    func start() {
        guard !isRunning, LibraryStorage.isICloudAvailable else { return }
        isRunning = true
        // No predicate on the folder path: the path reported by the query can be in
        // the `/private/var/...` form while the library's is `/var/...`, and a
        // BEGINSWITH would fail silently, returning zero results. Filtering is done
        // on the results instead, by comparing the resolved paths.
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
        // Targeted removal instead of `removeObserver(self)`: this class only observes
        // its own query, and a blanket removal would also cancel any other
        // observations registered elsewhere on the same object.
        NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidUpdate, object: query)
        NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: query)
    }

    @objc private func handleUpdate() {
        let rootPath = LibraryStorage.rootFolderURL().resolvingSymlinksInPath().standardizedFileURL.path
        var pending: Set<String> = []
        var all: Set<String> = []

        query.disableUpdates()
        for case let item as NSMetadataItem in query.results {
            guard let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL else { continue }
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            let relativePath = String(path.dropFirst(rootPath.count + 1))
            all.insert(relativePath)
            let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
            guard status != NSMetadataUbiquitousItemDownloadingStatusCurrent else { continue }
            pending.insert(relativePath)
        }
        query.enableUpdates()

        if pending != pendingRelativePaths {
            pendingRelativePaths = pending
        }
        if all != allRelativePaths {
            allRelativePaths = all
        }
    }
}
