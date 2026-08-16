import SwiftUI

/// Radice dell'app. È l'unico punto in cui la navigazione diverge tra le piattaforme:
/// il resto delle viste non sa su quale sistema sta girando.
struct ContentView: View {
    #if os(macOS)
    @State private var selection: LibrarySelection = .all
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    #endif

    @EnvironmentObject private var viewModel: LibraryViewModel
    @Environment(\.managedObjectContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var tracker = ICloudDownloadTracker.shared
    @AppStorage("icloudSyncFolderEnabled") private var isSyncFolderEnabled = false

    /// Coalesce gli aggiornamenti di `tracker.allRelativePaths`: durante la raccolta iniziale di
    /// una libreria iCloud non banale, `NSMetadataQuery` pubblica molti aggiornamenti
    /// incrementali in rapida sequenza — senza attendere che si stabilizzino, ognuno
    /// rilancerebbe una scansione completa della libreria.
    @State private var debounceTask: Task<Void, Never>?
    /// Rete di sicurezza oltre agli aggiornamenti live di `NSMetadataQuery`: nella pratica la
    /// query non sempre notifica un cambiamento avvenuto mentre l'app era in background, quindi
    /// un rescan periodico a bassa frequenza copre quel caso senza dipendere dal solo evento.
    @State private var periodicRescanTask: Task<Void, Never>?

    var body: some View {
        rootNavigation
            // Avviata una sola volta per tutta la durata dell'app (la query è inerte se iCloud non
            // è attivo): fermarla e riavviarla entrando/uscendo dal lettore costringerebbe a una
            // nuova fase di raccolta ogni volta.
            .onAppear {
                ICloudDownloadTracker.shared.start()
                syncSyncFolderIfNeeded()
                adoptFilesDroppedInDocuments()
                startPeriodicRescan()
            }
            .onDisappear {
                debounceTask?.cancel()
                periodicRescanTask?.cancel()
            }
            // ContentView è radice sempre viva per tutta la sessione: l'aggiornamento di
            // `allRelativePaths` innesca qui il rescan indipendentemente da cosa sta guardando
            // l'utente, invece di dipendere dall'apertura di una schermata specifica.
            .onChange(of: tracker.allRelativePaths) { _, _ in scheduleDebouncedSync() }
            .onChange(of: isSyncFolderEnabled) { _, newValue in if newValue { syncSyncFolderIfNeeded() } }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                syncSyncFolderIfNeeded()
                // Il momento in cui i file trascinati dal Finder possono essere comparsi è
                // esattamente questo: l'utente li copia con l'app in background e poi la riapre.
                adoptFilesDroppedInDocuments()
            }
    }

    private func scheduleDebouncedSync() {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            syncSyncFolderIfNeeded()
        }
    }

    /// Solo iOS: su macOS non esiste il File Sharing e la cartella Documents dell'app non è
    /// una destinazione in cui l'utente possa trascinare qualcosa.
    private func adoptFilesDroppedInDocuments() {
        #if os(iOS)
        viewModel.adoptFilesDroppedInDocuments(context: context)
        #endif
    }

    private func syncSyncFolderIfNeeded() {
        guard isSyncFolderEnabled, LibraryStorage.isICloudAvailable else { return }
        viewModel.rebuildLibrary(context: context)
    }

    private func startPeriodicRescan() {
        periodicRescanTask?.cancel()
        periodicRescanTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 180_000_000_000) // 3 minuti
                guard !Task.isCancelled else { return }
                syncSyncFolderIfNeeded()
                // Ripesca i file che l'adozione aveva saltato perché il Finder li stava ancora
                // copiando: senza questo, restare in foreground durante un trasferimento lungo
                // li lascerebbe fuori dalla libreria fino al riavvio dell'app.
                adoptFilesDroppedInDocuments()
            }
        }
    }

    @ViewBuilder
    private var rootNavigation: some View {
        #if os(macOS)
        // Su Mac la libreria sta nella finestra principale e la sidebar elenca le serie.
        NavigationSplitView(columnVisibility: $columnVisibility) {
            LibrarySidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
        } detail: {
            LibraryView(selection: selection)
                .navigationSplitViewColumnWidth(min: 520, ideal: 900)
        }
        .navigationSplitViewStyle(.balanced)
        #else
        NavigationStack {
            LibraryView()
        }
        #endif
    }
}
