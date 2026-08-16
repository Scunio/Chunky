import Foundation

/// Downloads from iCloud a comic that on the device is still only a placeholder, registering
/// it in `DownloadManager` so it shows up on the Downloads screen with real progress and
/// the ability to cancel it.
///
/// Exists as a single entry point because the download can start from two different paths —
/// opening it in the reader and the explicit command in the library's context menu — and
/// they need to latch onto the same transfer instead of starting two: `DownloadManager`'s
/// deduplication is keyed, and the key (the file's path) has to be chosen the same way by both.
enum ComicDownloadService {
    /// Must be called from the main queue (`DownloadManager` is observed by the UI).
    /// Returns the registered item, which the caller can use to cancel; `nil` if the file
    /// was already local and there was nothing to download.
    ///
    /// `onProgress` (0...1) and `completion` arrive on the main queue. `completion` receives
    /// `nil` if the comic is now readable, otherwise the error — including cancellation.
    @discardableResult
    static func downloadIfNeeded(
        title: String,
        at url: URL,
        onProgress: ((Double) -> Void)? = nil,
        completion: ((Error?) -> Void)? = nil
    ) -> DownloadItem? {
        // No `onProgress` here: a file that's already local never had a download, and
        // publishing a 100% progress value would make the reader's download overlay
        // flash for an instant on a comic that opens right away.
        guard LibraryStorage.isPendingDownload(url) else {
            completion?(nil)
            return nil
        }

        // The key is the file's path: reopening the same comic while it's downloading latches
        // onto the already-running download instead of starting a second one.
        let item = DownloadManager.shared.register(title: title, key: url.path)
        onProgress?(item.fractionCompleted)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try LibraryStorage.downloadIfNeeded(url, isCancelled: { item.isCancelled }) { progress in
                    // This `onProgress` arrives from the main queue during the download but from
                    // the background one in the "already downloaded" case: the UI can't be
                    // touched without explicitly bouncing to main.
                    DispatchQueue.main.async {
                        item.updateProgress(progress)
                        onProgress?(progress)
                    }
                }
                finish(item, error: nil, completion: completion)
            } catch {
                finish(item, error: error, completion: completion)
            }
        }
        return item
    }

    /// Convenience for callers that have the library record on hand.
    @discardableResult
    static func downloadIfNeeded(
        comic: ComicEntity,
        onProgress: ((Double) -> Void)? = nil,
        completion: ((Error?) -> Void)? = nil
    ) -> DownloadItem? {
        let url = LibraryStorage.fileURL(forRelativePath: comic.relativePath ?? "")
        return downloadIfNeeded(
            title: comic.title ?? "Fumetto",
            at: url,
            onProgress: onProgress,
            completion: completion
        )
    }

    /// The row must be removed from `DownloadManager` on every outcome, success or failure:
    /// leaving it would mean a stuck entry in Downloads and, worse, an already-cancelled item
    /// cached that would make the next attempt on the same comic fail immediately.
    private static func finish(_ item: DownloadItem, error: Error?, completion: ((Error?) -> Void)?) {
        DispatchQueue.main.async {
            DownloadManager.shared.remove(item)
            completion?(error)
        }
    }
}
