import CoreData
import Foundation

extension ComicEntity {
    /// Turns downloads of a *deleted* remote account into iCloud-library comics when their file
    /// is one an earlier version saved in the library root (the iCloud container).
    ///
    /// Such a file is shared with every device, which registers it as an iCloud comic; on the
    /// device that downloaded it, though, the row stayed bound to the account (local-only store,
    /// never synced). Once the account is gone that row is an orphan forever: its progress can't
    /// sync under the account key, and deleting the account didn't remove it (only never-downloaded
    /// placeholders go, see `deleteOrphanPlaceholders`). Adoption ends that split:
    /// - an iCloud row for the same file already exists → it absorbs the orphan (last reader wins,
    ///   `absorbLoser`) and the orphan is deleted;
    /// - none exists → a new iCloud row is created with the orphan's data, and the orphan deleted.
    ///   If another device creates one in parallel, regular deduplication merges the two.
    ///
    /// Only rows whose account no longer exists: with a live account the next scan would recreate
    /// its placeholder and the comic would show twice. Only files in the iCloud root: a copy in
    /// the private remote cache is not shared, and adopting it would register a file no other
    /// device can see. Nothing happens unless both stores are loaded — with the CloudKit store
    /// missing, every account would look deleted.
    ///
    /// The caller saves. Returns how many rows were adopted.
    @discardableResult
    static func adoptOrphanedRootDownloads(
        in context: NSManagedObjectContext,
        isLegacyRootDownload: (String, UUID) -> Bool = { LibraryStorage.isLegacyRootDownload(relativePath: $0, sourceAccountID: $1) }
    ) -> Int {
        guard (context.persistentStoreCoordinator?.persistentStores.count ?? 0) > 1 else { return 0 }
        let request = ComicEntity.fetchRequest()
        request.predicate = NSPredicate(format: "sourceAccountID != nil AND isRemotePlaceholder == NO")
        guard let downloaded = try? context.fetch(request), !downloaded.isEmpty else { return 0 }
        let existingAccountIDs = Set((try? context.fetch(RemoteAccountEntity.fetchRequest()))?.compactMap(\RemoteAccountEntity.id) ?? [])

        var adopted = 0
        for orphan in downloaded {
            guard let accountID = orphan.sourceAccountID,
                  !existingAccountIDs.contains(accountID),
                  let path = orphan.relativePath, !path.isEmpty,
                  isLegacyRootDownload(path, accountID)
            else { continue }

            let twinRequest = ComicEntity.fetchRequest()
            twinRequest.predicate = NSPredicate(format: "relativePath == %@ AND sourceAccountID == nil", path)
            if let twin = survivor(of: (try? context.fetch(twinRequest)) ?? []) {
                twin.absorbLoser(orphan)
            } else {
                let comic = create(
                    title: orphan.title ?? "",
                    seriesName: orphan.seriesName,
                    relativePath: path,
                    format: orphan.format,
                    readingDirection: orphan.readingDirection,
                    in: context
                )
                comic.dateAdded = orphan.dateAdded ?? comic.dateAdded
                comic.pageCount = orphan.pageCount
                comic.lastReadPage = orphan.lastReadPage
                comic.dateLastOpened = orphan.dateLastOpened
                comic.isFavorite = orphan.isFavorite
                comic.coverImageDataInline = orphan.safeCoverImageData
            }
            let identifier = orphan.objectID.uriRepresentation().absoluteString
            context.delete(orphan)
            ComicTextIndex.deleteIndex(forComicIdentifier: identifier)
            adopted += 1
        }
        if adopted > 0 {
            AppLog.log("Adottati nella libreria iCloud \(adopted) fumetti scaricati da account eliminati")
        }
        return adopted
    }
}
