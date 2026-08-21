import Foundation
import CoreData

/// Walks every remote account with `autoScanEnabled` and registers a lightweight placeholder
/// `ComicEntity` for each comic found that isn't in the library yet — no download happens here.
/// The placeholder downloads on first open (see `ComicDownloadService`), the same way an iCloud
/// placeholder does today, just from a different source.
///
/// `@MainActor`: `context` is always the app's main-queue-confined view context (its one caller,
/// `ContentView`, passes `@Environment(\.managedObjectContext)`). Every `RemoteAccountEntity`/
/// `ComicEntity` property read in this file — directly or inside `RemoteBrowsing`'s
/// implementations, which read the account's host/credentials synchronously before their own
/// network `await` — must happen on that same queue. Isolating the whole enum to `MainActor`
/// guarantees that: an `await` inside a `MainActor`-isolated function always resumes back on
/// the main actor, so there's no window where a resumed continuation reads `account.*` from
/// whatever background thread Swift concurrency happened to schedule it on. The actual network
/// I/O still runs concurrently — the actor is only occupied while synchronous code is running,
/// not while suspended on `await`.
@MainActor
enum RemoteAccountScanner {
    /// Recursion is capped mainly as a safety net against a server that reports a folder as its
    /// own child (misconfigured share, symlink loop) — real comic libraries are rarely nested
    /// this deep.
    private static let maxDepth = 12

    static func scanAllEnabledAccounts(context: NSManagedObjectContext) async {
        let request = RemoteAccountEntity.fetchRequest()
        request.predicate = NSPredicate(format: "autoScanEnabled == YES")
        let accounts = (try? context.fetch(request)) ?? []

        for account in accounts {
            await scan(account: account, context: context)
        }
    }

    static func scan(account: RemoteAccountEntity, context: NSManagedObjectContext) async {
        guard let rootURL = account.serverURL, let accountID = account.id else { return }
        let browser = RemoteBrowsingFactory.makeBrowser(for: account.kind)

        let request = ComicEntity.fetchRequest()
        request.predicate = NSPredicate(format: "sourceAccountID == %@", accountID as CVarArg)
        let existingComics = (try? context.fetch(request)) ?? []
        // Every remote file this account already knows about — downloaded or still a
        // placeholder — so a rescan never re-registers (and, per the relativePath check below,
        // never collides with) one already in the library.
        let existingPaths = Set(existingComics.compactMap { $0.sourceRelativePath })

        await walk(browser: browser, account: account, url: rootURL, existingPaths: existingPaths, depth: 0, context: context)

        account.lastScanDate = Date()
        try? context.save()
    }

    private static func walk(
        browser: RemoteBrowsing,
        account: RemoteAccountEntity,
        url: URL,
        existingPaths: Set<String>,
        depth: Int,
        context: NSManagedObjectContext
    ) async {
        guard depth < maxDepth else { return }
        guard let entries = try? await browser.listEntries(at: url, account: account) else { return }

        for entry in entries {
            if entry.isContainer {
                await walk(browser: browser, account: account, url: entry.url, existingPaths: existingPaths, depth: depth + 1, context: context)
            } else {
                let sourcePath = entry.url.absoluteString
                guard !existingPaths.contains(sourcePath) else { continue }
                await registerPlaceholder(entry: entry, account: account, sourcePath: sourcePath, context: context)
            }
        }
    }

    private static func registerPlaceholder(
        entry: RemoteEntry,
        account: RemoteAccountEntity,
        sourcePath: String,
        context: NSManagedObjectContext
    ) async {
        guard let format = ComicFormat(fileExtension: (entry.title as NSString).pathExtension) else { return }
        guard let accountID = account.id else { return }

        let fallbackTitle = (entry.title as NSString).deletingPathExtension
        let seriesName = account.smartFoldersEnabled ? LibraryViewModel.deriveSeriesName(fromFallbackTitle: fallbackTitle) : nil

        // Another pass (or the same account scanned again concurrently) may have just registered
        // this same remote file — re-check right before the write to avoid a duplicate.
        let duplicateRequest = ComicEntity.fetchRequest()
        duplicateRequest.predicate = NSPredicate(format: "sourceAccountID == %@ AND sourceRelativePath == %@", accountID as CVarArg, sourcePath)
        duplicateRequest.fetchLimit = 1
        guard ((try? context.count(for: duplicateRequest)) ?? 0) == 0 else { return }

        let relativePath = reserveUniqueRelativePath(suggestedName: entry.title, in: context)

        let placeholder = ComicEntity.create(
            title: fallbackTitle,
            seriesName: seriesName,
            relativePath: relativePath,
            format: format,
            isRemotePlaceholder: true,
            sourceAccountID: accountID,
            sourceRelativePath: sourcePath,
            in: context
        )
        try? context.save()

        // "Pre-cache": instead of waiting for the user to open it, download and analyze the file
        // right away so title/series (from ComicInfo.xml) and the cover show up in the library
        // immediately. There's no partial-read path for either format here, so this always pulls
        // the whole file — same cost as opening it manually, just paid upfront. `downloadIfNeeded`
        // already does exactly this (see `ComicDownloadService`) and, since the file lands at its
        // permanent `relativePath`, the comic simply stays imported afterwards rather than being
        // re-downloaded later.
        //
        // Awaited (not fire-and-forget): the scan already visits one file at a time, and letting
        // every new file spawn its own concurrent download would open one SMB/WebDAV connection
        // per file with no cap — some NAS servers throttle or refuse connections under that load.
        // Waiting here keeps precache downloads sequential, same as the scan itself.
        guard account.preCacheDetailsEnabled || account.preCacheCoversEnabled else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            ComicDownloadService.downloadIfNeeded(comic: placeholder, completion: { _ in
                continuation.resume()
            })
        }
    }

    /// `LibraryStorage.uniqueRelativePath` only checks the filesystem, which is correct for a
    /// normal import but not here: a placeholder has no file on disk yet, so two different remote
    /// comics that happen to share a filename (different folders, or different accounts) would
    /// both resolve to the identical relativePath, and the second one to download would silently
    /// overwrite the first. This also checks Core Data for the name actually being taken, and
    /// keeps incrementing until it finds one that's free on both.
    private static func reserveUniqueRelativePath(suggestedName: String, in context: NSManagedObjectContext) -> String {
        let ext = (suggestedName as NSString).pathExtension
        let base = (suggestedName as NSString).deletingPathExtension
        var candidate = suggestedName
        var suffix = 1
        while isRelativePathTaken(candidate, in: context) {
            candidate = ext.isEmpty ? "\(base) \(suffix)" : "\(base) \(suffix).\(ext)"
            suffix += 1
        }
        return candidate
    }

    private static func isRelativePathTaken(_ relativePath: String, in context: NSManagedObjectContext) -> Bool {
        if FileManager.default.fileExists(atPath: LibraryStorage.fileURL(forRelativePath: relativePath).path) {
            return true
        }
        let request = ComicEntity.fetchRequest()
        request.predicate = NSPredicate(format: "relativePath == %@", relativePath)
        request.fetchLimit = 1
        return ((try? context.count(for: request)) ?? 0) > 0
    }
}
