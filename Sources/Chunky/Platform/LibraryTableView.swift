#if os(macOS)
import SwiftUI

/// Alternative to the grid for large libraries: sortable columns instead of covers.
/// macOS only — `Table` has no full equivalent on iOS/iPadOS in this SDK, and the grid
/// remains the natural idiom there anyway.
struct LibraryTableView: View {
    let comics: [ComicEntity]
    let allowsDeletion: Bool
    let onSelect: (ComicEntity) -> Void
    let onDelete: (ComicEntity) -> Void

    @State private var sortOrder: [KeyPathComparator<ComicEntity>] = [
        .init(\.wrappedTitle, order: .forward)
    ]
    /// Same source as the grid's cover badge: the download command must appear and disappear
    /// together with the badge, not depending on when the row was last redrawn.
    @ObservedObject private var downloadTracker = ICloudDownloadTracker.shared

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
        .contextMenu(forSelectionType: ComicEntity.ID.self) { ids in
            if let comic = comic(for: ids) {
                contextMenuContent(for: comic)
            }
        } primaryAction: { ids in
            guard let comic = comic(for: ids) else { return }
            onSelect(comic)
        }
    }

    private func comic(for ids: Set<ComicEntity.ID>) -> ComicEntity? {
        guard let id = ids.first else { return nil }
        return sortedComics.first(where: { $0.id == id })
    }

    /// Mirrors `ComicCell`'s context menu (`LibraryView.swift`) so Lista and Griglia offer the
    /// same actions on a comic.
    @ViewBuilder
    private func contextMenuContent(for comic: ComicEntity) -> some View {
        Button(action: { onSelect(comic) }) {
            Label("Apri", systemImage: "book")
        }
        Button(action: { toggleFavorite(comic) }) {
            Label(comic.isFavorite ? "Rimuovi dai preferiti" : "Aggiungi ai preferiti",
                  systemImage: comic.isFavorite ? "star.slash" : "star")
        }
        if readStatus(for: comic) != .finished {
            Button(action: { markStatus(.finished, for: comic) }) {
                Label("Segna come letto", systemImage: "checkmark.circle")
            }
        }
        if readStatus(for: comic) != .unread {
            Button(action: { markStatus(.unread, for: comic) }) {
                Label("Segna come non letto", systemImage: "circle")
            }
        }
        if isPendingDownload(comic) {
            Button(action: { downloadFromICloud(comic) }) {
                Label("Scarica da iCloud", systemImage: "icloud.and.arrow.down")
            }
        }
        Button(action: { revealInFinder(comic) }) {
            Label("Mostra nel Finder", systemImage: "folder")
        }
        if allowsDeletion {
            Divider()
            Button(role: .destructive, action: { onDelete(comic) }) {
                Label("Rimuovi", systemImage: "trash")
            }
        }
    }

    private func isPendingDownload(_ comic: ComicEntity) -> Bool {
        guard let relativePath = comic.relativePath else { return false }
        return downloadTracker.pendingRelativePaths.contains(relativePath)
    }

    private func toggleFavorite(_ comic: ComicEntity) {
        comic.isFavorite.toggle()
        try? comic.managedObjectContext?.save()
    }

    private func markStatus(_ status: ReadStatus, for comic: ComicEntity) {
        status.apply(to: comic)
        try? comic.managedObjectContext?.save()
    }

    private func downloadFromICloud(_ comic: ComicEntity) {
        ComicDownloadService.downloadIfNeeded(comic: comic)
    }

    private func revealInFinder(_ comic: ComicEntity) {
        let url = LibraryStorage.fileURL(forRelativePath: comic.relativePath ?? "")
        RevealInFinder.reveal(url)
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
