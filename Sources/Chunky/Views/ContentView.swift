import SwiftUI

/// Radice dell'app. È l'unico punto in cui la navigazione diverge tra le piattaforme:
/// il resto delle viste non sa su quale sistema sta girando.
struct ContentView: View {
    #if os(macOS)
    @State private var selection: LibrarySelection = .all
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    #endif

    var body: some View {
        rootNavigation
            // Avviata una sola volta per tutta la durata dell'app (la query è inerte se iCloud non
            // è attivo): fermarla e riavviarla entrando/uscendo dal lettore costringerebbe a una
            // nuova fase di raccolta ogni volta.
            .onAppear { ICloudDownloadTracker.shared.start() }
    }

    @ViewBuilder
    private var rootNavigation: some View {
        #if os(macOS)
        // Su Mac la libreria sta nella finestra principale e la sidebar elenca le serie.
        // Il vecchio `NavigationView` senza stile degenerava nel comportamento a due colonne
        // e ci finiva dentro l'intera griglia, larga quanto una sidebar.
        NavigationSplitView(columnVisibility: $columnVisibility) {
            LibrarySidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
        } detail: {
            LibraryView(selection: selection)
                .navigationSplitViewColumnWidth(min: 520, ideal: 900)
        }
        .navigationSplitViewStyle(.balanced)
        #else
        NavigationView {
            LibraryView()
        }
        .navigationViewStyle(StackNavigationViewStyle())
        #endif
    }
}
