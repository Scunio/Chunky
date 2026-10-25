import Foundation
import CoreData

enum ReadingDirection: String, CaseIterable, Identifiable {
    case leftToRight
    case rightToLeft

    var id: String { rawValue }

    var label: String {
        switch self {
        case .leftToRight: AppLocalization.localizedString("Occidentale (sinistra → destra)", comment: "Reading direction")
        case .rightToLeft: AppLocalization.localizedString("Manga (destra → sinistra)", comment: "Reading direction")
        }
    }
}

enum ComicFormat: String {
    case cbz
    case cbr
    case pdf

    init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "cbz": self = .cbz
        case "cbr": self = .cbr
        case "pdf": self = .pdf
        default: return nil
        }
    }
}

extension ComicEntity {
    var format: ComicFormat {
        ComicFormat(rawValue: formatRawValue ?? "") ?? .cbz
    }

    var readingDirection: ReadingDirection {
        get { ReadingDirection(rawValue: readingDirectionRawValue ?? "") ?? .leftToRight }
        set { readingDirectionRawValue = newValue.rawValue }
    }

    var progress: Double {
        guard pageCount > 0 else { return 0 }
        return Double(lastReadPage) / Double(pageCount)
    }

    var isFinished: Bool {
        pageCount > 0 && lastReadPage >= pageCount - 1
    }

    /// Deterministic survivor ordering, shared by deduplication, progress sync and the
    /// pre-migration cleanup: `dateAdded` and `id` are synced attributes, so every device
    /// (and the offline cleanup below) picks the same survivor. If devices picked different
    /// records, each would delete the one the other keeps and the comic would vanish from both.
    static func precedesAsSurvivor(_ lhs: ComicEntity, _ rhs: ComicEntity) -> Bool {
        let leftDate = lhs.dateAdded ?? .distantFuture
        let rightDate = rhs.dateAdded ?? .distantFuture
        if leftDate != rightDate { return leftDate < rightDate }
        return (lhs.id?.uuidString ?? "") < (rhs.id?.uuidString ?? "")
    }

    /// The survivor of a same-file group, or nil when empty.
    static func survivor(of comics: [ComicEntity]) -> ComicEntity? {
        comics.sorted(by: precedesAsSurvivor).first
    }

    /// Absorbs a same-file duplicate with last-writer-wins on `dateLastOpened`: the freshest read
    /// wins even on an earlier page (going back must not resurrect old pages). On equal clocks the
    /// most advanced page wins, so skewed clocks still converge. Count, cover, favorite, series
    /// and title keep union semantics. Callers delete the loser afterwards.
    ///
    /// Single implementation for the live dedup pass and the progress sync's survivor pick:
    /// both must resolve the same way, or two devices collapse the same group differently.
    func absorbLoser(_ loser: ComicEntity) {
        let loserDate = loser.dateLastOpened ?? .distantPast
        let ownDate = dateLastOpened ?? .distantPast
        if loserDate > ownDate {
            lastReadPage = loser.lastReadPage
            dateLastOpened = loser.dateLastOpened
        } else if loserDate == ownDate {
            lastReadPage = max(lastReadPage, loser.lastReadPage)
        }
        if pageCount <= 0 { pageCount = loser.pageCount }
        // Safe accessors: a direct `coverImageData` read on a row whose external
        // sidecar file is missing raises an uncatchable NSException (see
        // `ComicEntity.safeCoverImageData`) instead of returning nil.
        if safeCoverImageData == nil {
            CoverThumbnailCache.invalidate(for: self)
            coverImageDataInline = loser.safeCoverImageData
        }
        if loser.isFavorite { isFavorite = true }
        if (seriesName ?? "").isEmpty { seriesName = loser.seriesName }
        if (title ?? "").isEmpty { title = loser.title }
    }

    @discardableResult
    static func create(
        title: String,
        seriesName: String? = nil,
        relativePath: String,
        format: ComicFormat,
        readingDirection: ReadingDirection = .leftToRight,
        isRemotePlaceholder: Bool = false,
        sourceAccountID: UUID? = nil,
        sourceRelativePath: String? = nil,
        in context: NSManagedObjectContext
    ) -> ComicEntity {
        // `insertNewObject(forEntityName:into:)` invece di `ComicEntity(context:)`: risolve l'entity
        // nel modello del context, non nel registro globale delle classi — con due versioni del
        // modello caricate (migrazione v2→v3, test) la risoluzione globale è ambigua
        // ("Failed to find a unique match") e può legare l'oggetto all'entity sbagliata.
        guard let comic = NSEntityDescription.insertNewObject(forEntityName: "ComicEntity", into: context) as? ComicEntity else {
            fatalError("ComicEntity non trovata nel modello del context")
        }
        comic.id = UUID()
        comic.title = title
        comic.seriesName = seriesName
        comic.relativePath = relativePath
        comic.formatRawValue = format.rawValue
        comic.pageCount = 0
        comic.lastReadPage = 0
        comic.readingDirectionRawValue = readingDirection.rawValue
        comic.dateAdded = Date()
        comic.isRemotePlaceholder = isRemotePlaceholder
        comic.sourceAccountID = sourceAccountID
        comic.sourceRelativePath = sourceRelativePath

        // `ComicEntity` is reachable from two stores once a second one is attached (see
        // `PersistenceController`): the default one (CloudKit-mirrored) and "Local" (never
        // synced). With more than one store able to hold this entity, every instance must be
        // explicitly assigned or Core Data can't tell which store to save it to. A comic that
        // came from a remote-account scan — placeholder or already downloaded, the flag flips
        // but the object never moves stores afterwards — goes to "Local"; everything else keeps
        // going to the default store, exactly as before this second store existed.
        let isRemoteSourced = isRemotePlaceholder || sourceAccountID != nil
        if let store = Self.targetStore(isLocalOnly: isRemoteSourced, in: context) {
            context.assign(comic, to: store)
        }
        return comic
    }

    /// Rimuove i segnaposto mai scaricati di un account eliminato: senza più
    /// l'account non potrebbero mai scaricarsi. I fumetti già scaricati restano
    /// in libreria. Ritorna quanti ne ha rimossi, per il log.
    @discardableResult
    static func deleteOrphanPlaceholders(ofAccountID accountID: UUID, in context: NSManagedObjectContext) -> Int {
        let request = ComicEntity.fetchRequest()
        request.predicate = NSPredicate(format: "sourceAccountID == %@ AND isRemotePlaceholder == YES", accountID as CVarArg)
        guard let orphans = try? context.fetch(request), !orphans.isEmpty else { return 0 }
        for orphan in orphans { context.delete(orphan) }
        AppLog.log("Pulizia orfani: rimossi \(orphans.count) segnaposto mai scaricati")
        return orphans.count
    }

    /// Come sopra ma senza sapere quale account è sparito (usato da Ricostruisci
    /// libreria): elimina i segnaposto il cui account non esiste più, tiene quelli
    /// degli account esistenti e tutti i fumetti scaricati.
    @discardableResult
    static func deletePlaceholdersWithMissingAccount(in context: NSManagedObjectContext) -> Int {
        let request = ComicEntity.fetchRequest()
        request.predicate = NSPredicate(format: "isRemotePlaceholder == YES AND sourceAccountID != nil")
        guard let placeholders = try? context.fetch(request), !placeholders.isEmpty else { return 0 }
        let accountRequest = RemoteAccountEntity.fetchRequest()
        let existingIDs = Set((try? context.fetch(accountRequest))?.compactMap(\RemoteAccountEntity.id) ?? [])
        let orphans = placeholders.filter { ph in
            guard let id = ph.sourceAccountID else { return false }
            return !existingIDs.contains(id)
        }
        for orphan in orphans { context.delete(orphan) }
        if !orphans.isEmpty {
            AppLog.log("Ricostruisci: rimossi \(orphans.count) segnaposto di account eliminati")
        }
        return orphans.count
    }

    private static func targetStore(isLocalOnly: Bool, in context: NSManagedObjectContext) -> NSPersistentStore? {
        guard let stores = context.persistentStoreCoordinator?.persistentStores, stores.count > 1 else {
            // A single store is unambiguous (the tests' in-memory stack, by design) — but it can
            // also mean the "Local" store failed to load in production (see
            // `PersistenceController.loadStores`) and every remote-account comic is about to
            // silently fall back to the CloudKit-mirrored store instead, which is exactly the
            // cross-device placeholder leak that store exists to prevent. Only the second case is
            // worth surfacing.
            if isLocalOnly {
                DiagnosticLog.log("ComicEntity.create: no second persistent store attached, remote-account comic may sync via CloudKit")
            }
            return nil
        }
        return stores.first { ($0.configurationName == PersistenceController.localOnlyConfigurationName) == isLocalOnly }
    }
}
