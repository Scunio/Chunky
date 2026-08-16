import Foundation

/// Manages the physical folder into which imported comics are copied.
/// If the user has iCloud Drive active, it uses the app's ubiquity container (files
/// automatically sync across all devices); otherwise it falls back to the
/// sandbox's local Documents folder.
enum LibraryStorage {
    private static let ubiquityContainerID = "iCloud.com.scunio.Chunky"
    private static let comicsFolderName = "Comics"

    nonisolated(unsafe) private static var cachedRootURL: URL?

    /// True if the user has iCloud Drive active and the app's ubiquity container is reachable:
    /// in that case imported comics automatically sync across all devices.
    static var isICloudAvailable: Bool {
        FileManager.default.url(forUbiquityContainerIdentifier: ubiquityContainerID) != nil
    }

    static func rootFolderURL() -> URL {
        if let cached = cachedRootURL {
            return cached
        }
        let root: URL
        if let ubiquityURL = FileManager.default.url(forUbiquityContainerIdentifier: ubiquityContainerID) {
            // The root folder must be "Documents" (not one level below, e.g.
            // "Documents/Comics"): the message shown to the user in ICloudSyncFolderView says
            // to put comics directly "inside Chunky", so the actual behavior
            // must match that message.
            root = ubiquityURL.appendingPathComponent("Documents")
        } else {
            root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        migrateLegacyComicsSubfolderIfNeeded(newRoot: root)
        cachedRootURL = root
        return root
    }

    /// Moves to the root any comics left by a previous folder layout in the
    /// "Comics" subfolder (see the comment in `rootFolderURL()`): without this step, anyone who already had
    /// a library would find it "gone" on the first launch after the update, even though the
    /// files are physically still present on iCloud/disk. In case of a name collision (e.g. a file
    /// the user had already mistakenly placed at the root) the incoming one is renamed, using the same scheme
    /// used by `importFile`.
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

    /// A free path inside `folder` for a file named `fileName`: if the name is already taken,
    /// it appends a counter ("Topolino 1.cbz"). The single implementation for every place where
    /// a file enters the library, so duplicates behave the same way everywhere.
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

    /// Finder copies into the Documents folder while the app is alive, so a file can still
    /// be mid-transfer at the moment we find it: moving or opening it now
    /// would mean truncating the copy or registering an unreadable archive in the library.
    /// Anything written in the last few seconds is left where it is: it's picked up by the
    /// next pass (foreground or periodic rescan), so skipping it doesn't lose it.
    private static func isBeingWritten(_ url: URL) -> Bool {
        guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
            return false
        }
        return Date().timeIntervalSince(modified) < 5
    }

    /// The sandbox's local Documents folder. This is what iOS exposes in Files and in the
    /// "Files" tab of Finder thanks to `UIFileSharingEnabled`, so it's where comics dragged
    /// from the Mac with the device connected via USB land. It coincides with `rootFolderURL()` only
    /// when iCloud Drive isn't available: with iCloud active the library lives in the
    /// ubiquity container, and without `adoptFilesDroppedInLocalDocuments()` dragged files would stay
    /// here without ever appearing in the library.
    static var localDocumentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Brings into the library the comics left in the local Documents folder and returns their
    /// paths relative to the root, ready for registration in Core Data. If the library is
    /// already that folder (no iCloud) it moves nothing and lists them where they were.
    /// It doesn't delete or register anything: deduplication against the existing library is
    /// up to the caller, which knows what's already in Core Data.
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

    /// Copies a file chosen by the user (via file importer / document picker) into the library,
    /// handling any duplicate names, and returns the relative path saved in the model.
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

    /// On a second device a file in the iCloud library can be only a
    /// placeholder not yet downloaded: this requests it and waits (blocking, so it must be
    /// called off the main thread) before it's opened as an archive.
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

    /// True if `url` is an iCloud comic whose bytes aren't all local yet
    /// (undownloaded placeholder). Used in the library to show a "to download" badge.
    static func isPendingDownload(_ url: URL) -> Bool {
        guard FileManager.default.isUbiquitousItem(at: url) else { return false }
        let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
        return status != .current
    }

    /// Like `ensureDownloaded`, but without a fixed timeout: reports the real percentage via
    /// `onProgress` (0...1), through `NSMetadataQuery` — resourceValues on `URL` alone don't
    /// expose byte-by-byte progress on iOS, only the status (downloaded or not).
    /// `isCancelled` is checked periodically to allow manual cancellation.
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

    /// Includes or excludes the library folder from iCloud/iTunes backups. Relevant only
    /// when falling back to the local folder (without iCloud Drive active; the iCloud one is already
    /// handled by sync itself).
    static func setExcludedFromBackup(_ excluded: Bool) {
        var url = rootFolderURL()
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = excluded
        try? url.setResourceValues(resourceValues)
    }
}

/// Tracks the progress of a single iCloud download with `NSMetadataQuery` (the only API that
/// exposes byte-by-byte percentage, not just the "downloaded/not downloaded" status).
/// `NSMetadataQuery` delivers its updates on the queue set in `operationQueue`
/// (here `.main`): it must therefore be started/stopped from the main thread.
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
        // Targeted removal instead of `removeObserver(self)`: this class only observes
        // its own query, and a blanket removal would also cancel any other
        // observations registered elsewhere on the same object.
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
