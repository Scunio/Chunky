import SwiftUI
import CoreData

/// Schermata "Sync Folder" raggiunta dalla riga "iCloud Drive" del pannello Account.
///
/// A differenza del resto della sincronizzazione (che copia i fumetti importati nel container
/// iCloud dell'app, vedi `LibraryStorage`), qui l'utente attiva esplicitamente un riscontro
/// automatico della cartella "Chunky" visibile in Files/Finder: i file che ci trascina dentro
/// da un altro dispositivo vengono registrati in libreria senza bisogno di reimportarli a mano.
///
/// Si appoggia a `ICloudDownloadTracker` (avviato una sola volta da `ContentView`) invece di
/// avere una `NSMetadataQuery` propria: la stessa query che alimenta il badge "da scaricare"
/// enumera già ogni file del container ubiquity, quindi i nuovi arrivi da un altro dispositivo
/// si notano da un cambiamento di `allRelativePaths` — niente più `Timer` che riscansiona alla
/// cieca ogni 5 secondi anche quando non è successo nulla.
struct ICloudSyncFolderView: View {
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var viewModel: LibraryViewModel
    @FetchRequest(sortDescriptors: []) private var comics: FetchedResults<ComicEntity>
    @ObservedObject private var tracker = ICloudDownloadTracker.shared

    @AppStorage("icloudSyncFolderEnabled") private var isEnabled = false
    @State private var isShowingInfo = false
    /// Coalesce gli aggiornamenti di `allRelativePaths`: durante la raccolta iniziale di una
    /// libreria iCloud non banale, `NSMetadataQuery` pubblica molti aggiornamenti incrementali
    /// in rapida sequenza — senza attendere che si stabilizzino, ognuno rilancerebbe una
    /// scansione completa della libreria.
    @State private var debounceTask: Task<Void, Never>?

    private var isAvailable: Bool { LibraryStorage.isICloudAvailable }

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Sync Folder")
                    Button(action: { isShowingInfo = true }) {
                        Image(systemName: "info.circle")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                    Spacer()
                    Toggle("", isOn: $isEnabled)
                        .labelsHidden()
                        .disabled(!isAvailable)
                }
            }

            if isEnabled && isAvailable {
                Section {
                    HStack {
                        Text("Downloaded")
                        Spacer()
                        Text("\(comics.count) comics")
                            .foregroundColor(.secondary)
                    }
                    Text(viewModel.isImporting ? "Sincronizzazione…" : "All comics synced")
                        .foregroundColor(.secondary)
                }
            }

            if !isAvailable {
                Section(footer: Text("Attiva iCloud Drive nelle Impostazioni di sistema per usare questa funzione.")) {
                    EmptyView()
                }
            }
        }
        .navigationTitle("iCloud Drive")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .alert(isPresented: $isShowingInfo) {
            Alert(
                title: Text("Sync Folder"),
                message: Text("Crea una cartella Chunky nella tua iCloud Drive.\nI fumetti che ci metti dentro restano sincronizzati con la tua libreria.\n\nSe li cancelli da Chunky, vengono cancellati anche da iCloud Drive."),
                dismissButton: .default(Text("OK"))
            )
        }
        .onAppear {
            // Se iCloud non era ancora pronto all'avvio dell'app, `start()` in
            // `ContentView.onAppear` è uscito subito senza fare nulla (è idempotente: non
            // fa danni a richiamarlo qui). Aprire questa schermata dà così una seconda
            // occasione di agganciarsi, invece di restare inerte per il resto della sessione.
            ICloudDownloadTracker.shared.start()
            syncIfNeeded()
        }
        .onChange(of: isEnabled) { _, newValue in
            if newValue { syncIfNeeded() }
        }
        .onChange(of: tracker.allRelativePaths) { scheduleDebouncedSync() }
        .onDisappear { debounceTask?.cancel() }
    }

    private func scheduleDebouncedSync() {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            syncIfNeeded()
        }
    }

    private func syncIfNeeded() {
        guard isEnabled, isAvailable else { return }
        viewModel.rebuildLibrary(context: context)
    }
}
