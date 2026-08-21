import CoreData

enum ReadStatus: CaseIterable, Identifiable {
    case unread
    case reading
    case finished

    var id: Self { self }

    var label: String {
        switch self {
        case .unread: "Non letto"
        case .reading: "In lettura"
        case .finished: "Terminato"
        }
    }

    /// Sets this status by acting directly on `lastReadPage`, the only state the model
    /// already tracks (no need for a dedicated field). Shared by the bulk-selection status
    /// menu and the per-comic context menu.
    func apply(to comic: ComicEntity) {
        switch self {
        case .unread:
            comic.lastReadPage = 0
            comic.dateLastOpened = nil
        case .reading:
            let count = comic.pageCount
            comic.lastReadPage = count > 1 ? min(max(comic.lastReadPage, 1), count - 2) : 0
            if comic.dateLastOpened == nil { comic.dateLastOpened = Date() }
        case .finished:
            comic.lastReadPage = max(comic.pageCount - 1, 0)
            if comic.dateLastOpened == nil { comic.dateLastOpened = Date() }
        }
    }
}

func readStatus(for comic: ComicEntity) -> ReadStatus {
    if comic.lastReadPage <= 0 { return .unread }
    if comic.isFinished { return .finished }
    return .reading
}
