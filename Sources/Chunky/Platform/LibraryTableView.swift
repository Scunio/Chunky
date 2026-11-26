#if os(macOS)
import SwiftUI

/// Alternative to the grid for large libraries: sortable columns instead of covers.
/// macOS only — `Table` has no full equivalent on iOS/iPadOS in this SDK, and the grid
/// remains the natural idiom there anyway.
struct LibraryTableView: View {
    let comics: [ComicEntity]
    /// Passato da `LibraryView` (unica osservatrice di `ICloudDownloadTracker` per la
    /// libreria): la tabella legge il Set senza sottoscriversi al singleton per riga.
    let pendingRelativePaths: Set<String>
    let onSelect: (ComicEntity) -> Void
    let onDelete: (ComicEntity) -> Void
    let onShowInfo: (ComicEntity) -> Void
    /// Delete key with more than one row selected: the library's bulk confirmation.
    let onDeleteMany: ([ComicEntity]) -> Void
    /// Mirrors the row selection up to `LibraryView`, so the toolbar's bulk actions (status,
    /// group, trash) act on the list's selection exactly as they do on the grid's.
    let onSelectionChange: ([ComicEntity]) -> Void

    init(
        comics: [ComicEntity],
        pendingRelativePaths: Set<String> = [],
        onSelect: @escaping (ComicEntity) -> Void,
        onDelete: @escaping (ComicEntity) -> Void,
        onShowInfo: @escaping (ComicEntity) -> Void = { _ in },
        onDeleteMany: @escaping ([ComicEntity]) -> Void = { _ in },
        onSelectionChange: @escaping ([ComicEntity]) -> Void = { _ in }
    ) {
        self.comics = comics
        self.pendingRelativePaths = pendingRelativePaths
        self.onSelect = onSelect
        self.onDelete = onDelete
        self.onShowInfo = onShowInfo
        self.onDeleteMany = onDeleteMany
        self.onSelectionChange = onSelectionChange
    }

    @State private var sortOrder: [KeyPathComparator<ComicEntity>] = [
        .init(\.wrappedTitle, order: .forward)
    ]
    /// Without a selection binding the rows couldn't be selected at all, so there was nothing
    /// for Return (open) or Delete (remove) to act on from the keyboard.
    @State private var selection: Set<ComicEntity.ID> = []

    private var sortedComics: [ComicEntity] {
        comics.sorted(using: sortOrder)
    }

    var body: some View {
        Table(sortedComics, selection: $selection, sortOrder: $sortOrder) {
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
        .onChange(of: selection) { _, ids in
            onSelectionChange(sortedComics.filter { ids.contains($0.id) })
        }
        .onKeyPress(.return) {
            let selected = sortedComics.filter { selection.contains($0.id) }
            guard !selected.isEmpty else { return .ignored }
            selected.prefix(5).forEach(onSelect)  // same cap as the grid: one window per comic
            return .handled
        }
        // Delete key / Edit ▸ Delete: same confirmation as the context menu's "Rimuovi" for
        // one row, the bulk one for several (before, only the first selected row went).
        .onDeleteCommand {
            let selected = sortedComics.filter { selection.contains($0.id) }
            if selected.count == 1 {
                onDelete(selected[0])
            } else if selected.count > 1 {
                onDeleteMany(selected)
            }
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
        Button(action: { onShowInfo(comic) }) {
            Label("Informazioni", systemImage: "info.circle")
        }
                Button(action: { revealInFinder(comic) }) {
            Label("Mostra nel Finder", systemImage: "folder")
        }
        Divider()
        Button(role: .destructive, action: { onDelete(comic) }) {
            Label("Rimuovi", systemImage: "trash")
        }
    }

    private func isPendingDownload(_ comic: ComicEntity) -> Bool {
        guard let relativePath = comic.relativePath else { return false }
        return pendingRelativePaths.contains(relativePath)
    }

    private func toggleFavorite(_ comic: ComicEntity) {
        comic.isFavorite.toggle()
        try? comic.managedObjectContext?.save()
    }

    private func markStatus(_ status: ReadStatus, for comic: ComicEntity) {
        status.apply(to: comic)
        try? comic.managedObjectContext?.save()
        Task { @MainActor in RemoteProgressSync.requestPush(comic) }
    }

    private func downloadFromICloud(_ comic: ComicEntity) {
        ComicDownloadService.downloadIfNeeded(comic: comic)
    }

    private func revealInFinder(_ comic: ComicEntity) {
        RevealInFinder.reveal(comic.fileURL)
    }

    /// Same logic as `LibraryView.status(for:)` (private to that file): it doesn't reimplement
    /// the `isFinished` formula, it reuses it from `ComicEntity` so it can't diverge.
    private func statusLabel(for comic: ComicEntity) -> String {
        if comic.lastReadPage <= 0 {
            return AppLocalization.localizedString("Non letto", comment: "Comic reading status")
        }
        if comic.isFinished {
            return AppLocalization.localizedString("Terminato", comment: "Comic reading status")
        }
        return AppLocalization.localizedString("In lettura", comment: "Comic reading status")
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
