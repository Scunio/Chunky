import Foundation
import CoreData
import Combine

final class LibraryViewModel: ObservableObject {
    @Published var isImporting = false
    /// What the library is doing right now, shown in the loading overlay.
    /// `nil` when there's no work in progress: automatic scans that don't find anything to
    /// register must not make any indicator appear.
    @Published var importStatus: String?
    @Published var importError: String?

    /// All writes to the library go through here, one at a time. Previously each function
    /// dispatched on its own onto `DispatchQueue.global`, and with four scan triggers
    /// (see `ContentView`) two passes could overlap: both would read the already-known paths
    /// before the other saved, and would register the same files twice.
    private let workQueue = DispatchQueue(label: "com.scunio.Chunky.library-scan", qos: .userInitiated)

    /// A single, long-lived background context, not a new one per call: two consecutive
    /// passes each need to see what the other has just saved.
    private var scanContext: NSManagedObjectContext?

    /// Scans already queued but not yet started: a second trigger of the same kind doesn't
    /// add an identical pass, it waits for the one that's about to run. The key is removed
    /// at the start of execution, so a trigger arriving *during* the pass still queues
    /// another one at the end (and that's exactly what's needed: the on-disk state has changed).
    private let pendingLock = NSLock()
    private var pendingScans: Set<ScanKind> = []
    /// Operations currently showing the loading indicator, from oldest to most recent,
    /// each with its own current text (see `beginStatus`).
    private var statusStack: [(token: Int, text: String)] = []
    private var nextStatusToken = 0

    private enum ScanKind: Hashable {
        case rebuild
        case adopt
        case deduplicate
        case placeholderMetadata
    }

    /// Paths whose archive refused to open while completing placeholders. A corrupted file
    /// stays indistinguishable from one that just finished downloading (zero pages,
    /// no cover) and would get reopened on every pass: here we remember them for the
    /// duration of the session. Deliberately not persisted — an app restart is the right
    /// occasion to retry, and the file may have been re-synced in the meantime.
    private var pathsWithUnreadableArchive: Set<String> = []

    // MARK: - Explicit import

    func importFiles(_ urls: [URL], into context: NSManagedObjectContext) {
        let backgroundContext = sharedScanContext(for: context)
        let statusToken = beginStatus(urls.count == 1 ? "Importazione…" : "Importazione di \(urls.count) fumetti…")

        workQueue.async { [weak self] in
            guard let self = self else { return }
            defer { self.endStatus(token: statusToken) }
            for (index, url) in urls.enumerated() {
                if urls.count > 1 {
                    self.updateStatus("Importazione di \(index + 1) di \(urls.count)…", token: statusToken)
                }
                self.importSingleFile(url, into: backgroundContext)
            }
            self.deduplicateComics(in: backgroundContext)
            self.backfillSeriesNames(in: backgroundContext)
        }
    }

    /// The context must be created on the caller's thread (always the main one: the public
    /// entry points are invoked by SwiftUI), not inside `workQueue`, so that access to
    /// `scanContext` stays confined to a single thread.
    private func sharedScanContext(for context: NSManagedObjectContext) -> NSManagedObjectContext {
        if let existing = scanContext, existing.persistentStoreCoordinator === context.persistentStoreCoordinator {
            return existing
        }
        guard let coordinator = context.persistentStoreCoordinator else { return context }

        let bg = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        bg.persistentStoreCoordinator = coordinator
        bg.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        // Lives as long as the app: without these two, it would keep serving the values it
        // loaded the objects with the first time, ignoring both changes made from the UI
        // and records that arrived from CloudKit.
        bg.automaticallyMergesChangesFromParent = true
        bg.stalenessInterval = 0
        scanContext = bg
        return bg
    }

    /// Copies `url` into the library folder, then registers it. Used for external files
    /// (system picker, download from a remote account, "open with").
    private func importSingleFile(_ url: URL, into context: NSManagedObjectContext) {
        let ext = url.pathExtension
        guard let format = ComicFormat(fileExtension: ext) else {
            reportError("Formato non supportato: .\(ext)")
            return
        }

        do {
            let relativePath = try LibraryStorage.importFile(from: url)
            registerComic(relativePath: relativePath, format: format, into: context)
        } catch {
            reportError(error.localizedDescription)
        }
    }

    /// What can be extracted by opening a comic's archive. No Core Data object inside:
    /// the analysis is the slow part and lives outside the context, insertion is separate.
    struct ComicAnalysis {
        let pageCount: Int
        let coverData: Data?
        let metadata: ComicInfoMetadata?
    }

    /// Opens the archive and extracts its pages, cover and ComicInfo metadata. `nil` if the
    /// file can't be opened (corrupted or protected archive): the caller decides whether to
    /// register it anyway.
    ///
    /// Expensive: fully decompresses page 0. Must never be called on a file that's still
    /// an iCloud placeholder — see `registerComic`.
    static func analyzeComic(at url: URL, format: ComicFormat) -> ComicAnalysis? {
        guard let provider = try? ComicPageProviderFactory.makeProvider(for: url, format: format) else {
            return nil
        }

        var coverData: Data?
        if provider.pageCount > 0 {
            let rawCoverData = (try? provider.rawData(atPage: 0)).flatMap { $0 }
            if let rawCoverData = rawCoverData {
                coverData = ThumbnailGenerator.makeThumbnailData(fromSourceData: rawCoverData)
            } else if let coverImage = try? provider.image(atPage: 0) {
                coverData = ThumbnailGenerator.makeThumbnailData(from: coverImage)
            }
        }

        let metadata = provider.comicInfoXML.flatMap { ComicInfoMetadata.parse(from: $0) }
        return ComicAnalysis(pageCount: provider.pageCount, coverData: coverData, metadata: metadata)
    }

    /// Title to display: the one from ComicInfo if present, otherwise series + number,
    /// otherwise the file name. Shared between registration and the deferred completion of
    /// iCloud placeholders, so a comic's title doesn't change depending on when it was read.
    static func displayTitle(from metadata: ComicInfoMetadata?, fallbackTitle: String) -> String {
        if let title = metadata?.title { return title }
        if let series = metadata?.series {
            return metadata?.number.map { "\(series) #\($0)" } ?? series
        }
        return fallbackTitle
    }

    /// Analyzes and inserts into Core Data a file that's ALREADY present in the library folder
    /// (no copy). Used by `rebuildLibrary`, where the file exists but the record is missing.
    ///
    /// Does nothing if that `relativePath` is already in the library: a file is a single comic,
    /// and the check comes before opening the archive because that's also what prevents
    /// regenerating the thumbnails of half the library on every pass.
    func registerComic(relativePath: String, format: ComicFormat, into context: NSManagedObjectContext) {
        guard !isRegistered(relativePath: relativePath, in: context) else { return }

        let destinationURL = LibraryStorage.fileURL(forRelativePath: relativePath)
        let defaultDirectionRawValue = UserDefaults.standard.string(forKey: "defaultReadingDirection")
        let defaultDirection = ReadingDirection(rawValue: defaultDirectionRawValue ?? "") ?? .leftToRight

        // An iCloud comic not yet downloaded is registered "empty", without opening the archive:
        // reading it would force its materialization, i.e. the full download of the file — and
        // with a freshly synced library that means downloading dozens of comics in a row,
        // without the user asking for it and without the downloads showing up anywhere.
        // The cover and page count are filled in by `backfillPlaceholderMetadata` once the file arrives.
        let isPlaceholder = LibraryStorage.isPendingDownload(destinationURL)
        let analysis = isPlaceholder ? nil : Self.analyzeComic(at: destinationURL, format: format)

        let pageCount = analysis?.pageCount ?? 0
        let coverData = analysis?.coverData
        let metadata = analysis?.metadata

        let fallbackTitle = (relativePath as NSString).deletingPathExtension
        let title = Self.displayTitle(from: metadata, fallbackTitle: fallbackTitle)
        let seriesName = metadata?.series ?? Self.deriveSeriesName(fromFallbackTitle: fallbackTitle)

        context.performAndWait {
            // Re-check after reading the archive: opening it and generating the thumbnail can
            // take seconds, long enough that in the meantime the same path may have arrived
            // from CloudKit and been merged into this context.
            guard !isRegisteredWithinContext(relativePath: relativePath, in: context) else { return }
            let comic = ComicEntity.create(
                title: title,
                seriesName: seriesName,
                relativePath: relativePath,
                format: format,
                readingDirection: defaultDirection,
                in: context
            )
            comic.pageCount = Int32(pageCount)
            comic.coverImageData = coverData
            try? context.save()
            if isPlaceholder {
                DiagnosticLog.log("Registrato \"\(title)\" (\(format.rawValue), da scaricare da iCloud)")
            } else {
                DiagnosticLog.log("Importato \"\(title)\" (\(format.rawValue), \(pageCount) pagine)")
            }
        }
    }

    func isRegistered(relativePath: String, in context: NSManagedObjectContext) -> Bool {
        var found = false
        context.performAndWait {
            found = isRegisteredWithinContext(relativePath: relativePath, in: context)
        }
        return found
    }

    /// To be called from inside a context `perform` block already.
    private func isRegisteredWithinContext(relativePath: String, in context: NSManagedObjectContext) -> Bool {
        let request = ComicEntity.fetchRequest()
        request.predicate = NSPredicate(format: "relativePath == %@", relativePath)
        request.fetchLimit = 1
        return ((try? context.count(for: request)) ?? 0) > 0
    }

    /// Many scanned CBZ/CBR files don't have a ComicInfo.xml with a series: without a fallback,
    /// they'd all end up dumped into "Other comics" instead of being grouped by title. If the
    /// title ends with a number (e.g. "Topolino 3595"), we strip it and use the rest as the
    /// series name ("Topolino"). First, though, the trailing decorations of scanned releases
    /// are removed (see `LibraryGrouping.titleWithoutTrailingDecorations`), otherwise a
    /// "Topolino 3652 (Panini 2025-11-19) [c2c CPPD]" wouldn't end with a number and would be
    /// left without a series.
    static func deriveSeriesName(fromFallbackTitle title: String) -> String? {
        let title = LibraryGrouping.titleWithoutTrailingDecorations(title)
        guard let range = title.range(of: #"\s+#?\d+\s*$"#, options: .regularExpression) else { return nil }
        let series = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        return series.isEmpty ? nil : series
    }

    private func reportError(_ message: String) {
        DiagnosticLog.log("Errore import: \(message)")
        DispatchQueue.main.async {
            self.importError = message
        }
    }

    /// A stack, not a counter: an explicit import can start while an automatic scan is still
    /// running on the same `workQueue`, and whichever finishes first must not turn off the
    /// indicator while the other is still working. Keeping each operation's text too (not just
    /// how many there are) serves long passes: they can update their own count even while
    /// another one is temporarily holding the label, and when that one finishes the indicator
    /// goes back to the right phrase instead of staying frozen on one from an operation that's
    /// already done.
    @discardableResult
    private func beginStatus(_ text: String) -> Int {
        pendingLock.lock()
        nextStatusToken += 1
        let token = nextStatusToken
        statusStack.append((token: token, text: text))
        pendingLock.unlock()
        publishStatus(text)
        return token
    }

    /// Changes operation `token`'s text without touching the stack. Publishes only if that
    /// operation is at the top, i.e. if its label is the one currently visible.
    private func updateStatus(_ text: String, token: Int) {
        pendingLock.lock()
        guard let index = statusStack.firstIndex(where: { $0.token == token }) else {
            pendingLock.unlock()
            return
        }
        statusStack[index].text = text
        let isVisible = index == statusStack.count - 1
        pendingLock.unlock()
        guard isVisible else { return }
        publishStatus(text)
    }

    private func endStatus(token: Int) {
        pendingLock.lock()
        statusStack.removeAll { $0.token == token }
        let resumed = statusStack.last?.text
        pendingLock.unlock()
        publishStatus(resumed)
    }

    private func publishStatus(_ status: String?) {
        let apply = {
            self.importStatus = status
            self.isImporting = status != nil
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    /// The file is only removed if no other record points to the same `relativePath`:
    /// as long as duplicate records exist (see `deduplicateComics`), deleting one would delete
    /// the shared file and leave its twin pointing at nothing — the comic would disappear.
    func delete(_ comic: ComicEntity, from context: NSManagedObjectContext) {
        let relativePath = comic.relativePath ?? ""
        let identifier = comic.objectID.uriRepresentation().absoluteString
        context.delete(comic)
        try? context.save()
        ComicTextIndex.deleteIndex(forComicIdentifier: identifier)

        guard shouldRemoveFile(forRelativePath: relativePath, in: context) else { return }
        LibraryStorage.removeFile(relativePath: relativePath)
    }

    /// There's only one file on disk and duplicate records share it: it can only be deleted
    /// once no record in the library references it anymore.
    func shouldRemoveFile(forRelativePath relativePath: String, in context: NSManagedObjectContext) -> Bool {
        guard !relativePath.isEmpty else { return false }
        return !isRegistered(relativePath: relativePath, in: context)
    }

    /// Deduplication-only pass, without scanning the disk: needed because duplicates can
    /// arrive from CloudKit even when the sync folder is disabled and so `rebuildLibrary`
    /// never runs.
    func deduplicateLibrary(context: NSManagedObjectContext) {
        let backgroundContext = sharedScanContext(for: context)
        enqueue(.deduplicate) { [weak self] in
            self?.deduplicateComics(in: backgroundContext)
            self?.backfillSeriesNames(in: backgroundContext)
        }
    }

    // MARK: - Automatic scans

    /// Queues `work` on the serial queue, skipping requests already waiting of the same kind.
    private func enqueue(_ kind: ScanKind, _ work: @escaping () -> Void) {
        pendingLock.lock()
        let alreadyQueued = pendingScans.contains(kind)
        pendingScans.insert(kind)
        pendingLock.unlock()
        guard !alreadyQueued else { return }

        workQueue.async { [weak self] in
            self?.pendingLock.lock()
            self?.pendingScans.remove(kind)
            self?.pendingLock.unlock()
            work()
        }
    }

    /// Registers in the library the comics dropped into the app's Documents folder from the
    /// Finder (`UIFileSharingEnabled`, device connected via USB → "Files" tab) or from Files.
    ///
    /// Deliberately kept separate from `rebuildLibrary`, not a special case of it: that one
    /// deletes records whose file no longer exists, and on an iCloud library files not yet
    /// downloaded may very well not exist on disk. This pass, instead, is purely additive, so
    /// it can run on every foreground event without gating on iCloud and without risking
    /// emptying the library.
    func adoptFilesDroppedInDocuments(context: NSManagedObjectContext) {
        let backgroundContext = sharedScanContext(for: context)
        enqueue(.adopt) { [weak self] in
            self?.performAdoptFilesDroppedInDocuments(in: backgroundContext)
        }
    }

    func performAdoptFilesDroppedInDocuments(in context: NSManagedObjectContext) {
        let candidates = LibraryStorage.adoptFilesDroppedInLocalDocuments()
        guard !candidates.isEmpty else { return }

        var knownPaths: Set<String> = []
        context.performAndWait {
            let request = ComicEntity.fetchRequest()
            guard let comics = try? context.fetch(request) else { return }
            knownPaths = Set(comics.compactMap { $0.relativePath })
        }

        let newPaths = candidates.filter { !knownPaths.contains($0) }
        guard !newPaths.isEmpty else { return }

        let statusToken = beginStatus(newPaths.count == 1 ? "Aggiungo 1 fumetto…" : "Aggiungo \(newPaths.count) fumetti…")
        defer { endStatus(token: statusToken) }
        let startedAt = Date()
        for (index, relativePath) in newPaths.enumerated() {
            if newPaths.count > 1 {
                updateStatus("Aggiungo \(index + 1) di \(newPaths.count)…", token: statusToken)
            }
            guard let format = ComicFormat(fileExtension: (relativePath as NSString).pathExtension) else { continue }
            registerComic(relativePath: relativePath, format: format, into: context)
        }
        DiagnosticLog.log("File Sharing: aggiunti \(newPaths.count) fumetti dalla cartella Documents in \(Self.formatted(duration: Date().timeIntervalSince(startedAt)))")
        deduplicateComics(in: context)
        backfillSeriesNames(in: context)
    }

    /// Recovery tool: removes from the library comics whose file no longer exists
    /// (e.g. deleted manually from Finder/Files), and registers files found in the library
    /// folder that aren't present yet — useful after restoring from a backup or a sync issue.
    func rebuildLibrary(context: NSManagedObjectContext) {
        let backgroundContext = sharedScanContext(for: context)
        enqueue(.rebuild) { [weak self] in
            self?.performRebuildLibrary(in: backgroundContext)
        }
    }

    func performRebuildLibrary(in context: NSManagedObjectContext) {
        var removedCount = 0
        var knownPaths: Set<String> = []
        context.performAndWait {
            let request = ComicEntity.fetchRequest()
            guard let comics = try? context.fetch(request) else { return }
            for comic in comics {
                let path = comic.relativePath ?? ""
                let url = LibraryStorage.fileURL(forRelativePath: path)
                if path.isEmpty || !FileManager.default.fileExists(atPath: url.path) {
                    let identifier = comic.objectID.uriRepresentation().absoluteString
                    context.delete(comic)
                    removedCount += 1
                    ComicTextIndex.deleteIndex(forComicIdentifier: identifier)
                } else {
                    knownPaths.insert(path)
                }
            }
            try? context.save()
        }

        let root = LibraryStorage.rootFolderURL()
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let unknownComicFiles = files.filter { url in
            ComicFormat(fileExtension: url.pathExtension) != nil && !knownPaths.contains(url.lastPathComponent)
        }

        // The indicator only lights up now, not at the start of the pass: the scan runs on
        // every foreground event and every 3 minutes, and almost always finds nothing to do —
        // showing "Importing…" in those cases left the user staring at an unexplained banner.
        let statusToken = unknownComicFiles.isEmpty
            ? nil
            : beginStatus(unknownComicFiles.count == 1 ? "Aggiungo 1 fumetto…" : "Aggiungo \(unknownComicFiles.count) fumetti…")
        defer { if let statusToken = statusToken { endStatus(token: statusToken) } }

        let startedAt = Date()
        for (index, url) in unknownComicFiles.enumerated() {
            if let statusToken = statusToken, unknownComicFiles.count > 1 {
                updateStatus("Aggiungo \(index + 1) di \(unknownComicFiles.count)…", token: statusToken)
            }
            guard let format = ComicFormat(fileExtension: url.pathExtension) else { continue }
            registerComic(relativePath: url.lastPathComponent, format: format, into: context)
        }

        if removedCount > 0 || !unknownComicFiles.isEmpty {
            let elapsed = Self.formatted(duration: Date().timeIntervalSince(startedAt))
            DiagnosticLog.log("Rebuild library: rimossi \(removedCount), ritrovati \(unknownComicFiles.count) in \(elapsed)")
        }

        deduplicateComics(in: context)
        backfillSeriesNames(in: context)
    }

    // MARK: - Completing iCloud placeholders

    /// Fills in the cover, page count, and metadata of comics registered as iCloud placeholders
    /// (see `registerComic`), now that their bytes have arrived locally.
    func backfillPlaceholderMetadata(context: NSManagedObjectContext) {
        let backgroundContext = sharedScanContext(for: context)
        enqueue(.placeholderMetadata) { [weak self] in
            self?.performBackfillPlaceholderMetadata(in: backgroundContext)
        }
    }

    func performBackfillPlaceholderMetadata(in context: NSManagedObjectContext) {
        var candidates: [(objectID: NSManagedObjectID, relativePath: String, format: ComicFormat)] = []
        context.performAndWait {
            let request = ComicEntity.fetchRequest()
            // Only the cover, not also "pageCount == 0": opening a just-downloaded comic
            // already has the reader write the page count (see `ReaderView.openProvider`), and
            // with that second condition the record would stop being a candidate while staying
            // without a cover until a reinstall. A comic in the library with no cover is by
            // definition one that needs completing, whatever path brought it there.
            //
            // No need for a dedicated attribute in the model: that would be local device state
            // that CloudKit would sync to other devices, where the file might already be
            // downloaded.
            request.predicate = NSPredicate(format: "coverImageData == nil")
            guard let comics = try? context.fetch(request) else { return }
            for comic in comics {
                guard let relativePath = comic.relativePath, !relativePath.isEmpty else { continue }
                guard !pathsWithUnreadableArchive.contains(relativePath) else { continue }
                let url = LibraryStorage.fileURL(forRelativePath: relativePath)
                guard FileManager.default.fileExists(atPath: url.path),
                      !LibraryStorage.isPendingDownload(url) else { continue }
                candidates.append((comic.objectID, relativePath, comic.format))
            }
        }
        guard !candidates.isEmpty else { return }

        let statusToken = beginStatus(candidates.count == 1
            ? "Preparo 1 fumetto…"
            : "Preparo \(candidates.count) fumetti…")
        defer { endStatus(token: statusToken) }

        let startedAt = Date()
        var completed = 0
        for (index, candidate) in candidates.enumerated() {
            if candidates.count > 1 {
                updateStatus("Preparo \(index + 1) di \(candidates.count)…", token: statusToken)
            }
            let url = LibraryStorage.fileURL(forRelativePath: candidate.relativePath)
            // An archive that opens but doesn't yield a cover would leave the record a
            // candidate again on the next pass too: for this list it counts as unreadable,
            // otherwise every scan would reopen it for nothing.
            let analysis = Self.analyzeComic(at: url, format: candidate.format)
            guard let analysis = analysis, analysis.coverData != nil else {
                pathsWithUnreadableArchive.insert(candidate.relativePath)
                DiagnosticLog.log("Nessuna copertina ricavabile da \"\(candidate.relativePath)\"")
                continue
            }
            apply(analysis, toComicWith: candidate.objectID, relativePath: candidate.relativePath, in: context)
            completed += 1
        }

        if completed > 0 {
            let elapsed = Self.formatted(duration: Date().timeIntervalSince(startedAt))
            DiagnosticLog.log("Completati \(completed) fumetti scaricati da iCloud in \(elapsed)")
        }
    }

    /// The title is only rewritten if the ComicInfo proposes one different from the file name:
    /// otherwise a comic the user has already seen in the grid would change its name on its own.
    private func apply(
        _ analysis: ComicAnalysis,
        toComicWith objectID: NSManagedObjectID,
        relativePath: String,
        in context: NSManagedObjectContext
    ) {
        context.performAndWait {
            guard let comic = try? context.existingObject(with: objectID) as? ComicEntity else { return }
            comic.pageCount = Int32(analysis.pageCount)
            comic.coverImageData = analysis.coverData

            let fallbackTitle = (relativePath as NSString).deletingPathExtension
            let title = Self.displayTitle(from: analysis.metadata, fallbackTitle: fallbackTitle)
            if title != fallbackTitle {
                comic.title = title
            }
            if let series = analysis.metadata?.series {
                comic.seriesName = series
            }
            try? context.save()
        }
    }

    /// Human-readable duration for the Diagnostics log: distinguishing "12s" from "4m 30s"
    /// immediately tells whether a slow pass is archive analysis or waiting on the network.
    static func formatted(duration: TimeInterval) -> String {
        let seconds = Int(duration.rounded())
        guard seconds >= 60 else { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }
}
