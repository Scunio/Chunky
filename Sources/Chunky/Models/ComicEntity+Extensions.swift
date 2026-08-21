import Foundation
import CoreData

enum ReadingDirection: String, CaseIterable, Identifiable {
    case leftToRight
    case rightToLeft

    var id: String { rawValue }

    var label: String {
        switch self {
        case .leftToRight: "Occidentale (sinistra → destra)"
        case .rightToLeft: "Manga (destra → sinistra)"
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
        let comic = ComicEntity(context: context)
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
