import Foundation
import CoreData

extension LibraryViewModel {
    /// Collapses records that point to the same file. There are two sources for these: overlapping
    /// scans (now serialized, but duplicates already created remain) and the two devices —
    /// iPad and Mac each create their own `ComicEntity` for the same file in the iCloud
    /// container, and CloudKit syncs both records.
    ///
    /// NEVER touches the files: there's only one file, and it's the one the duplicate records share.
    @discardableResult
    func deduplicateComics(in context: NSManagedObjectContext) -> Int {
        var collapsed = 0
        context.performAndWait {
            guard let duplicatePaths = duplicateRelativePaths(in: context), !duplicatePaths.isEmpty else { return }

            let request = ComicEntity.fetchRequest()
            request.predicate = NSPredicate(format: "relativePath IN %@", duplicatePaths)
            // The scanning context lives as long as the app and may already have these objects in
            // memory from a previous pass: without forcing a refresh, the merge would read the
            // old values and throw away reading progress that arrived from CloudKit in the meantime.
            request.shouldRefreshRefetchedObjects = true
            guard let comics = try? context.fetch(request) else { return }

            for (path, group) in Dictionary(grouping: comics, by: { $0.relativePath ?? "" }) where group.count > 1 {
                let ordered = group.sorted(by: Self.precedesAsSurvivor)
                guard let survivor = ordered.first else { continue }
                for loser in ordered.dropFirst() {
                    Self.merge(loser, into: survivor)
                    let identifier = loser.objectID.uriRepresentation().absoluteString
                    context.delete(loser)
                    collapsed += 1
                    ComicTextIndex.deleteIndex(forComicIdentifier: identifier)
                }
                DiagnosticLog.log("Deduplica: \(group.count) record per \"\(path)\", ne resta 1")
            }

            if collapsed > 0 { try? context.save() }
        }
        if collapsed > 0 {
            DiagnosticLog.log("Deduplica libreria: rimossi \(collapsed) record duplicati")
        }
        return collapsed
    }

    /// Recomputes the series for comics that still lack one. `seriesName` is written only once,
    /// at import time: without this pass, improving series-name inference wouldn't change
    /// anything for comics already in the library, which would remain in "Other comics".
    ///
    /// Only touches records with an empty series: anyone who picked a group by hand (see
    /// `applyGroup` in `LibraryView`) has a populated `seriesName` and must not be overwritten —
    /// whereas anyone who left it "automatic" has exactly `nil`, and that's what gets recomputed here.
    @discardableResult
    func backfillSeriesNames(in context: NSManagedObjectContext) -> Int {
        var filled = 0
        context.performAndWait {
            let request = ComicEntity.fetchRequest()
            request.predicate = NSPredicate(format: "seriesName == nil OR seriesName == %@", "")
            guard let comics = try? context.fetch(request), !comics.isEmpty else { return }

            for comic in comics {
                let fallback = comic.title ?? ((comic.relativePath ?? "") as NSString).deletingPathExtension
                guard let series = Self.deriveSeriesName(fromFallbackTitle: fallback) else { continue }
                comic.seriesName = series
                filled += 1
            }

            if filled > 0 { try? context.save() }
        }
        if filled > 0 {
            DiagnosticLog.log("Serie dedotta per \(filled) fumetti che ne erano privi")
        }
        return filled
    }

    /// Only the paths with more than one record, read as dictionaries: loading all the
    /// `ComicEntity` objects would mean pulling the covers of the entire library into memory on every pass.
    private func duplicateRelativePaths(in context: NSManagedObjectContext) -> [String]? {
        let request = NSFetchRequest<NSDictionary>(entityName: "ComicEntity")
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = ["relativePath"]
        guard let rows = try? context.fetch(request) else { return nil }

        var counts: [String: Int] = [:]
        for row in rows {
            guard let path = row["relativePath"] as? String, !path.isEmpty else { continue }
            counts[path, default: 0] += 1
        }
        return counts.filter { $0.value > 1 }.map(\.key)
    }

    /// Deterministic ordering: `dateAdded` and `id` are synced attributes, so iPad and Mac see
    /// the same values and pick the same survivor. If they picked different records, each would
    /// delete the one the other keeps, and the comic would disappear from both.
    private static func precedesAsSurvivor(_ lhs: ComicEntity, _ rhs: ComicEntity) -> Bool {
        let leftDate = lhs.dateAdded ?? .distantFuture
        let rightDate = rhs.dateAdded ?? .distantFuture
        if leftDate != rightDate { return leftDate < rightDate }
        return (lhs.id?.uuidString ?? "") < (rhs.id?.uuidString ?? "")
    }

    /// Merges into the survivor whatever is worth keeping from the discarded record: without this
    /// step, deduplication would eat the reading progress made on the other device.
    private static func merge(_ source: ComicEntity, into target: ComicEntity) {
        target.lastReadPage = max(target.lastReadPage, source.lastReadPage)
        if target.pageCount <= 0 { target.pageCount = source.pageCount }
        if let opened = source.dateLastOpened, (target.dateLastOpened ?? .distantPast) < opened {
            target.dateLastOpened = opened
        }
        if target.coverImageData == nil { target.coverImageData = source.coverImageData }
        if source.isFavorite { target.isFavorite = true }
        if (target.seriesName ?? "").isEmpty { target.seriesName = source.seriesName }
        if (target.title ?? "").isEmpty { target.title = source.title }
    }
}
