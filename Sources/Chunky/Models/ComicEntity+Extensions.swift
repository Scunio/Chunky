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
        return comic
    }
}
