import Foundation

/// Manages the physical folder into which imported comics are copied.
/// If the user has iCloud Drive active, it uses the app's ubiquity container (files
/// automatically sync across all devices); otherwise it falls back to the
/// sandbox's local Documents folder.
enum LibraryStorage {
    private static let ubiquityContainerID = "iCloud.com.scunio.Chunky"
    private static let comicsFolderName = "Comics"
    /// True for `--uitesting` app runs *and* (macOS only) for the unit-test bundle: both get
    /// the temporary sandbox below instead of the real library folders. The unit tests compile
    /// the app sources straight into an unsandboxed test bundle, so without this
    /// `LibraryRebuildSafetyTests` scanned — and could import/move/delete files in — the
    /// user's real `~/Documents` (or iCloud Drive container), and the download tests wrote
    /// into the real Application Support.
    private static var isRunningUITests: Bool {
        CommandLine.arguments.contains("--uitesting") || isRunningUnitTests
    }

    /// macOS unit-test process (xctest host). Not on iOS/tvOS: the simulator's app container
    /// is already isolated there.
    private static var isRunningUnitTests: Bool {
        #if os(macOS)
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
        #else
        false
        #endif
    }

    /// Dedicated sandbox for `--uitesting` runs on macOS: library files, fixtures and Core Data
    /// stores all live here, never in the user's real `~/Documents` or Application Support
    /// (an unsigned Debug build is not sandboxed, so those would be the real folders and
    /// `--uitesting-reset` would wipe them). On iOS the simulator's app container is already
    /// isolated, so nothing changes there. nil = no redirection.
    static var uiTestingSandboxURL: URL? {
        #if os(macOS)
        guard isRunningUITests else { return nil }
        let folder = isRunningUnitTests ? "ChunkyUnitTests" : "ChunkyUITests"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
        #else
        return nil
        #endif
    }

    nonisolated(unsafe) private static var cachedRootURL: URL?
    /// Whether `cachedRootURL` is the ubiquity container (decided when it was cached).
    /// Compared against `isICloudAvailable` by `isRootConsistentWithICloudAvailability`.
    nonisolated(unsafe) private static var cachedRootIsUbiquitous = false
    nonisolated(unsafe) private static var ubiquityIdentityObserver: (any NSObjectProtocol)?
    /// Guards `cachedRootURL`'s check-and-set below: without it, two callers racing on the
    /// first-ever call (e.g. a batch import overlapping the periodic rescan right after launch)
    /// could both run `migrateLegacyComicsSubfolderIfNeeded` concurrently — one thread moving a
    /// file while another removes the now-empty legacy folder underneath it, surfacing as a
    /// spurious "you don't have permission" `copyItem` failure on an unrelated import.
    private static let rootFolderLock = NSLock()

    /// True if the user has iCloud Drive active and the app's ubiquity container is reachable:
    /// in that case imported comics automatically sync across all devices.
    ///
    /// Cached: `url(forUbiquityContainerIdentifier:)` can block the calling thread
    /// (IPC to the ubiquity daemon), so calling it inside a view body on every
    /// evaluation stalled the Settings panels. Refreshed at most every minute;
    /// availability doesn't flap faster than that in practice.
    /// Always false on tvOS: no Files app/iCloud Drive there, and the entitlements lack
    /// `CloudDocuments` — querying the container hung the main thread at launch on a real Apple TV.
    static var isICloudAvailable: Bool {
        // UI tests run without the app's iCloud entitlements. Avoid waiting on the
        // ubiquity daemon and keep their fixture storage local and deterministic.
        if isRunningUITests { return false }
        #if os(tvOS)
        return false
        #else
        availabilityLock.lock()
        if let cached = cachedAvailability,
           Date().timeIntervalSince(cachedAvailabilityAt) < availabilityRefreshInterval {
            availabilityLock.unlock()
            return cached
        }
        availabilityLock.unlock()
        let available = FileManager.default.url(forUbiquityContainerIdentifier: ubiquityContainerID) != nil
        availabilityLock.lock()
        cachedAvailability = available
        cachedAvailabilityAt = Date()
        availabilityLock.unlock()
        return available
        #endif
    }

    nonisolated(unsafe) private static var cachedAvailability: Bool?
    nonisolated(unsafe) private static var cachedAvailabilityAt = Date.distantPast
    private static let availabilityLock = NSLock()
    private static let availabilityRefreshInterval: TimeInterval = 60

    /// Warms `isICloudAvailable` off the main thread so the first panel that reads it
    /// never pays the daemon round-trip. Safe to call repeatedly (the TTL applies).
    static func warmICloudAvailability() {
        #if !os(tvOS)
        DispatchQueue.global(qos: .utility).async {
            _ = isICloudAvailable
        }
        #endif
    }

    /// Forgets the cached root and the cached availability when the iCloud account changes
    /// (sign-in, sign-out, iCloud Drive toggled for the app): without this the root picked at
    /// launch stayed in use for the whole process, pointing at a container that may no longer
    /// be reachable — or at local Documents while iCloud had become available. Installed once,
    /// at the first `rootFolderURL()` call.
    private static func observeUbiquityIdentityChangesIfNeeded() {
        #if !os(tvOS)
        guard ubiquityIdentityObserver == nil else { return }
        ubiquityIdentityObserver = NotificationCenter.default.addObserver(
            forName: .NSUbiquityIdentityDidChange, object: nil, queue: nil
        ) { _ in
            rootFolderLock.lock()
            cachedRootURL = nil
            cachedRootIsUbiquitous = false
            rootFolderLock.unlock()
            availabilityLock.lock()
            cachedAvailability = nil
            availabilityLock.unlock()
            DiagnosticLog.log("Identità iCloud cambiata: cartella libreria e disponibilità ricalcolate al prossimo accesso")
        }
        #endif
    }

    /// False when the cached library root and the current iCloud availability disagree —
    /// e.g. the root was resolved to the ubiquity container but iCloud is now unavailable,
    /// or the reverse, until the root is recomputed. In that window the files a rebuild sees
    /// are those of the wrong folder, so `performRebuildLibrary` must not delete records
    /// based on them. Always true on tvOS and under UI tests (fixed local roots).
    static var isRootConsistentWithICloudAvailability: Bool {
        if isRunningUITests { return true }
        #if os(tvOS)
        return true
        #else
        _ = rootFolderURL()
        rootFolderLock.lock()
        let rootIsUbiquitous = cachedRootIsUbiquitous
        rootFolderLock.unlock()
        return rootIsUbiquitous == isICloudAvailable
        #endif
    }

    static func rootFolderURL() -> URL {
        if isRunningUITests {
            #if os(tvOS)
            return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ComicsLibrary")
            #else
            if let sandbox = uiTestingSandboxURL {
                // Created here too: a UI-test run gets it from `UITestReset`, a unit-test run
                // (where nothing else creates it) would otherwise fail every move into it.
                let library = sandbox.appendingPathComponent("Library", isDirectory: true)
                try? FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
                return library
            }
            return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            #endif
        }
        rootFolderLock.lock()
        defer { rootFolderLock.unlock() }

        observeUbiquityIdentityChangesIfNeeded()
        if let cached = cachedRootURL {
            return cached
        }
        let root: URL
        var isUbiquitous = false
        #if os(tvOS)
        // Not `.documentDirectory`: tvOS gives apps no persistent Documents storage at all —
        // confirmed on a physical Apple TV, every write API (Cocoa and raw POSIX) fails with
        // EPERM there, while the identical call against `.cachesDirectory` succeeds. Apple's own
        // tvOS storage guidance is Caches/Temporary only; Core Data's `defaultDirectoryURL()`
        // already lands here for the same reason (see `PersistenceController`).
        root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ComicsLibrary")
        #else
        if let ubiquityURL = FileManager.default.url(forUbiquityContainerIdentifier: ubiquityContainerID) {
            // The root folder must be "Documents" (not one level below, e.g.
            // "Documents/Comics"): the message shown to the user in ICloudSyncFolderView says
            // to put comics directly "inside Chunky", so the actual behavior
            // must match that message.
            root = ubiquityURL.appendingPathComponent("Documents")
            isUbiquitous = true
        } else {
            root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        }
        #endif
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        migrateLegacyComicsSubfolderIfNeeded(newRoot: root)
        cachedRootURL = root
        cachedRootIsUbiquitous = isUbiquitous
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
    ///
    /// tvOS has no Files app/USB drop target at all — this is `rootFolderURL()` there instead of
    /// the (unwritable, see `rootFolderURL()`) Documents folder, so callers that don't special-case
    /// platforms, like `UITestSeed`, still land where the library actually scans.
    static var localDocumentsURL: URL {
        #if os(tvOS)
        rootFolderURL()
        #else
        uiTestingSandboxURL?.appendingPathComponent("Library", isDirectory: true)
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #endif
    }

    /// Brings into the library the comics left in the local Documents folder and returns their
    /// paths relative to the root, ready for registration in Core Data. If the library is
    /// already that folder (no iCloud) it moves nothing and lists them where they were.
    /// It doesn't delete or register anything: deduplication against the existing library is
    /// up to the caller, which knows what's already in Core Data.
    /// `excluding`: file names (relative paths) left untouched — remote-account downloads.
    static func adoptFilesDroppedInLocalDocuments(excluding excluded: Set<String> = []) -> [String] {
        let inbox = localDocumentsURL
        let root = rootFolderURL()
        let files = (try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let comicFiles = files.filter {
            ComicFormat(fileExtension: $0.pathExtension) != nil && !isBeingWritten($0)
                && !excluded.contains($0.lastPathComponent)
        }

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

    // MARK: - Remote-account downloads

    /// Where files downloaded from a remote account (SMB/WebDAV/OPDS) live: a per-account
    /// folder in Application Support, *not* the library root. The root is usually the iCloud
    /// Drive container, and remote downloads written there were uploaded to iCloud and then
    /// "discovered" by every other device's rebuild as brand-new local comics — while their
    /// records (local-only store) never travel. Excluded from backup: it's a re-downloadable
    /// copy of what's on the NAS.
    ///
    /// tvOS keeps the root (Caches, never synced): nothing to fix there, and moving files
    /// would only orphan existing downloads.
    static func remoteCacheFolderURL(accountID: UUID) -> URL {
        #if os(tvOS)
        return rootFolderURL()
        #else
        if isRunningUITests { return rootFolderURL() }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RemoteCache", isDirectory: true)
        let folder = base.appendingPathComponent(accountID.uuidString, isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var excluded = base
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? excluded.setResourceValues(values)
        }
        return folder
        #endif
    }

    /// Destination for a *new* download of a remote-account comic (always the remote cache).
    static func remoteCacheFileURL(relativePath: String, accountID: UUID) -> URL {
        remoteCacheFolderURL(accountID: accountID).appendingPathComponent(relativePath)
    }

    /// The file of a library record. Local/iCloud comics (`sourceAccountID == nil`) live in
    /// the root; remote-account comics in the remote cache — except those downloaded by
    /// earlier versions, which still sit in the root under the same `relativePath`. Those are
    /// used where they are, never moved: they are in the iCloud container, and moving them
    /// out would delete them on every other device too (where a rebuild may already have
    /// registered them as local comics).
    static func fileURL(forRelativePath relativePath: String, sourceAccountID: UUID?) -> URL {
        guard let sourceAccountID, !relativePath.isEmpty else {
            return fileURL(forRelativePath: relativePath)
        }
        let cached = remoteCacheFileURL(relativePath: relativePath, accountID: sourceAccountID)
        if FileManager.default.fileExists(atPath: cached.path) { return cached }
        let legacy = fileURL(forRelativePath: relativePath)
        if isPresent(legacy) { return legacy }
        return cached
    }

    /// True if the file exists locally *or* is an iCloud item whose bytes were evicted:
    /// `fileExists` is false for an offloaded file at its logical path, which would make an
    /// older remote download in the iCloud root look gone (see `isPendingDownload` for the
    /// same logical-URL check).
    static func isPresent(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) || FileManager.default.isUbiquitousItem(at: url)
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

    /// Reserves a library-relative path for a file that doesn't exist locally yet (a remote
    /// placeholder, downloaded only when the comic is first opened) — same collision-avoidance
    /// as `importFile`, just without copying anything.
    static func uniqueRelativePath(suggestedName: String) -> String {
        availableDestination(forFileNamed: suggestedName, in: rootFolderURL()).lastPathComponent
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
