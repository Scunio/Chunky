import Foundation
import CoreData

extension LibraryViewModel {
    /// Collapses records that point to the same file. There are two sources for these: overlapping
    /// scans (now serialized, but duplicates already created remain) and the two devices —
    /// iPad and Mac each create their own `ComicEntity` for the same file in the iCloud
    /// container, and CloudKit syncs both records.
    ///
    /// NEVER touches the files: there's only one file, and it's the one the duplicate records share.
    ///
    /// Convergenza deterministica, non finestra temporale: il superstite è scelto con
    /// `precedesAsSurvivor` (identico su ogni device) e il progresso con last-writer-wins su
    /// `dateLastOpened` (vedi `merge`) — a parità di orologio vince la pagina più avanzata, così
    /// due device convergono allo stesso valore anche con gli orologi sfasati. Fondere subito è
    /// sicuro proprio perché il merge è LWW: un progresso più fresco che arriva dopo dal mirror
    /// vince comunque al giro successivo, invece di restare schiacciato da un `max()`.
    ///
    /// `awaitRemoteProgress` (solo dal passo dedicato, mai da import/rebuild/test) attende in
    /// modo limitato il sync esplicito prima di fondere, così il merge vede il progresso
    /// fresco in volo invece di fotografare il vecchio. Sempre fuori dal main thread.
    @discardableResult
    func deduplicateComics(in context: NSManagedObjectContext, awaitRemoteProgress: Bool = false) -> Int {
        var paths: [String] = []
        context.performAndWait {
            paths = duplicateRelativePaths(in: context) ?? []
        }
        guard !paths.isEmpty else { return 0 }
        if awaitRemoteProgress, !Thread.isMainThread {
            Self.waitForRemoteProgress(in: context)
        }
        var collapsed = 0
        context.performAndWait {
            guard !paths.isEmpty else { return }

            let request = ComicEntity.fetchRequest()
            request.predicate = NSPredicate(format: "relativePath IN %@", paths)
            // The scanning context lives as long as the app and may already have these objects in
            // memory from a previous pass: without forcing a refresh, the merge would read the
            // old values and throw away reading progress that arrived from CloudKit in the meantime.
            request.shouldRefreshRefetchedObjects = true
            guard let comics = try? context.fetch(request) else { return }

            for (path, group) in Dictionary(grouping: comics, by: { $0.relativePath ?? "" }) where group.count > 1 {
                // Niente grazia temporale sui letti di recente: era un livelock — ogni fetch del
                // sync esplicito scrive un `dateLastOpened` fresco su ogni duplicato, quindi il
                // gruppo risultava "recente" per sempre e non si fondeva mai. La freschezza è già
                // garantita da `waitForRemoteProgress` qui sopra, e il merge LWW sotto rende sicura
                // la fusione immediata (il più fresco vince comunque, anche se arriva dopo).
                let ordered = group.sorted(by: Self.precedesAsSurvivor)
                guard let survivor = ordered.first else { continue }
                for loser in ordered.dropFirst() {
                    let survivorBefore = survivor.lastReadPage
                    let loserPage = loser.lastReadPage
                    Self.merge(loser, into: survivor)
                    if survivor.lastReadPage != survivorBefore {
                        DiagnosticLog.log("Deduplica: \"\(path)\" pagina \(survivorBefore + 1)->\(survivor.lastReadPage + 1) ereditata dal record scartato (aveva \(loserPage + 1))")
                    }
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

    /// Attesa limitata del sync esplicito prima di fondere: il merge deve vedere il
    /// progresso fresco in volo, altrimenti lo fotografa vecchio e il save del dedup —
    /// più recente — lo riesporta via mirror sopra il fresco (last-writer-wins).
    /// Scade sempre: alla scadenza si procede comunque e il fetch in corso guarisce dopo.
    private static let dedupRemoteFetchTimeout: TimeInterval = 12

    private static func waitForRemoteProgress(in context: NSManagedObjectContext) {
        let done = DispatchGroup()
        done.enter()
        RemoteProgressSync.fetchAndApply(in: context, force: true) { _ in done.leave() }
        if done.wait(timeout: .now() + dedupRemoteFetchTimeout) == .timedOut {
            DiagnosticLog.log("Deduplica: fetch progressi oltre i \(Int(dedupRemoteFetchTimeout))s, procedo comunque")
        }
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

    /// Merges into the survivor with last-writer-wins on `dateLastOpened`: the freshest read wins,
    /// even when it's on an earlier page (going back a few pages must not resurrect page 115 over
    /// page 10). `max()` here was the bug that kept old pages alive: the dedup save — newer as a
    /// write — was then re-exported by the mirror over the fresh progress. On equal clocks the most
    /// advanced page wins, so two devices with skewed clocks still converge to the same value.
    /// Page count, cover, favorite, series and title keep union semantics (worth keeping from either).
    private static func merge(_ source: ComicEntity, into target: ComicEntity) {
        let sourceDate = source.dateLastOpened ?? .distantPast
        let targetDate = target.dateLastOpened ?? .distantPast
        if sourceDate > targetDate {
            target.lastReadPage = source.lastReadPage
            target.dateLastOpened = source.dateLastOpened
        } else if sourceDate == targetDate {
            target.lastReadPage = max(target.lastReadPage, source.lastReadPage)
        }
        if target.pageCount <= 0 { target.pageCount = source.pageCount }
        // Safe accessors: a direct `coverImageData` read on a row whose external
        // sidecar file is missing raises an uncatchable NSException (see
        // `ComicEntity.safeCoverImageData`) instead of returning nil.
        if target.safeCoverImageData == nil { target.coverImageData = source.safeCoverImageData }
        if source.isFavorite { target.isFavorite = true }
        if (target.seriesName ?? "").isEmpty { target.seriesName = source.seriesName }
        if (target.title ?? "").isEmpty { target.title = source.title }
    }
}
