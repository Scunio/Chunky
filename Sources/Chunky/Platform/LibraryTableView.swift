#if os(macOS)
import SwiftUI

/// Alternativa alla griglia per librerie grandi: colonne ordinabili invece di copertine.
/// Solo macOS — `Table` non ha un analogo pieno su iOS/iPadOS in questo SDK, e la griglia
/// resta comunque l'idioma naturale lì.
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
        // `Table` seleziona per riga; l'apertura resta un doppio clic, perché un singolo clic
        // che aprisse subito impedirebbe di selezionare una riga senza aprirla.
        .contextMenu(forSelectionType: ComicEntity.ID.self) { _ in
        } primaryAction: { ids in
            guard let id = ids.first, let comic = sortedComics.first(where: { $0.id == id }) else { return }
            onSelect(comic)
        }
    }

    /// Stessa logica di `LibraryView.status(for:)` (privata a quel file): non reimplementa la
    /// formula di `isFinished`, la riusa da `ComicEntity` per non farla divergere.
    private func statusLabel(for comic: ComicEntity) -> String {
        if comic.lastReadPage <= 0 { return "Non letto" }
        if comic.isFinished { return "Terminato" }
        return "In lettura"
    }
}

private extension ComicEntity {
    var wrappedTitle: String { title ?? "" }
    var wrappedSeriesName: String { seriesName ?? "" }
    /// `Date?` non conforma a `Comparable` in un modo che `KeyPathComparator` accetti
    /// direttamente: si ordina sul timestamp, con le date mancanti in fondo.
    var dateAddedSortKey: TimeInterval { dateAdded?.timeIntervalSince1970 ?? 0 }
}
#endif
