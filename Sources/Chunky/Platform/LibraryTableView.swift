#if os(macOS)
import SwiftUI

/// Alternative to the grid for large libraries: sortable columns instead of covers.
/// macOS only — `Table` has no full equivalent on iOS/iPadOS in this SDK, and the grid
/// remains the natural idiom there anyway.
struct LibraryTableView: View {
    let comics: [ComicEntity]
    let onSelect: (ComicEntity) -> Void

    @State private var sortOrder: [KeyPathComparator<ComicEntity>] = [
        .init(\.wrappedTitle, order: .forward)
    ]

    private var sortedComics: [ComicEntity] {
        comics.sorted(using: sortOrder)
    }

    var body: some View {
        Table(sortedComics, sortOrder: $sortOrder) {
            TableColumn("Titolo", value: \.wrappedTitle)
            TableColumn("Serie", value: \.wrappedSeriesName)
            TableColumn("Pagine", value: \.pageCount) { comic in
                Text("\(comic.pageCount)")
            }
            TableColumn("Stato") { comic in
                Text(statusLabel(for: comic))
                    .foregroundColor(.secondary)
            }
            TableColumn("Aggiunto", value: \.dateAddedSortKey) { comic in
                Text(comic.dateAdded ?? .distantPast, style: .date)
                    .foregroundColor(.secondary)
            }
        }
        // `Table` selects by row; opening stays a double click, because a single click
        // that opened right away would make it impossible to select a row without opening it.
        .contextMenu(forSelectionType: ComicEntity.ID.self) { _ in
        } primaryAction: { ids in
            guard let id = ids.first, let comic = sortedComics.first(where: { $0.id == id }) else { return }
            onSelect(comic)
        }
    }

    /// Same logic as `LibraryView.status(for:)` (private to that file): it doesn't reimplement
    /// the `isFinished` formula, it reuses it from `ComicEntity` so it can't diverge.
    private func statusLabel(for comic: ComicEntity) -> String {
        if comic.lastReadPage <= 0 { return "Non letto" }
        if comic.isFinished { return "Terminato" }
        return "In lettura"
    }
}

private extension ComicEntity {
    var wrappedTitle: String { title ?? "" }
    var wrappedSeriesName: String { seriesName ?? "" }
    /// `Date?` doesn't conform to `Comparable` in a way `KeyPathComparator` accepts
    /// directly: sorting is done on the timestamp, with missing dates last.
    var dateAddedSortKey: TimeInterval { dateAdded?.timeIntervalSince1970 ?? 0 }
}
#endif
