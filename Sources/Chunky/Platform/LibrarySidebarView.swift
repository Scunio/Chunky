#if os(macOS)
import SwiftUI
import CoreData

/// Sidebar del Mac: "Tutti i fumetti" più le serie già esistenti in libreria.
///
/// Contiene solo ciò che c'è: le stesse etichette e gli stessi conteggi delle sezioni
/// collassabili della griglia (`LibraryGrouping`). Novità, Ora in lettura, Account e
/// Strumenti restano dove sono sempre stati, cioè in toolbar — non diventano voci di
/// navigazione.
struct LibrarySidebarView: View {
    @Binding var selection: LibrarySelection
    @ObservedObject private var theme = AppTheme.shared

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \ComicEntity.title, ascending: true)]
    ) private var comics: FetchedResults<ComicEntity>

    private var sections: [LibraryGrouping.Section] {
        LibraryGrouping.sections(for: Array(comics))
    }

    var body: some View {
        List(selection: $selection) {
            Label("Tutti i fumetti", systemImage: "books.vertical")
                .badge(comics.count)
                .tag(LibrarySelection.all)
                .accessibilityIdentifier("sidebar.all")

            // Le stesse sezioni della griglia (comprese "Altri fumetti" quando c'è):
            // nasconderla qui la lascerebbe comunque visibile come intestazione nella
            // griglia, disallineando sidebar e contenuto invece di semplificare qualcosa.
            if !sections.isEmpty {
                Section("Serie") {
                    ForEach(sections) { section in
                        Label(section.title, systemImage: section.title == LibraryGrouping.ungroupedTitle
                              ? "tray" : "book.closed")
                            .badge(section.comics.count)
                            .tag(LibrarySelection.group(section.title))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("library.sidebar")
        .accentColor(theme.accent)
        // Se il gruppo selezionato smette di esistere (ultimo fumetto spostato altrove o
        // cancellato), la sidebar lo toglie da sé dall'elenco ma la selezione ci restava
        // comunque puntata: la griglia mostrava "nessun risultato" per una ricerca vuota,
        // senza modo di capire perché. Si torna a "Tutti i fumetti".
        .onChange(of: sections.map(\.title)) { _, titles in
            if case .group(let title) = selection, !titles.contains(title) {
                selection = .all
            }
        }
    }
}
#endif
