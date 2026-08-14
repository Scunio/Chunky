import SwiftUI
import CoreData

/// Schermata "Sync Folder" raggiunta dalla riga "iCloud Drive" del pannello Account.
///
/// A differenza del resto della sincronizzazione (che copia i fumetti importati nel container
/// iCloud dell'app, vedi `LibraryStorage`), qui l'utente attiva esplicitamente un riscontro
/// automatico della cartella "Chunky" visibile in Files/Finder: i file che ci trascina dentro
/// da un altro dispositivo vengono registrati in libreria senza bisogno di reimportarli a mano.
///
/// Il rescan vero e proprio (osservare `ICloudDownloadTracker`, avviato una sola volta da
/// `ContentView`, e richiamare `rebuildLibrary`) è centralizzato in `ContentView`, radice sempre
/// viva per tutta la sessione: farlo anche qui duplicherebbe la scansione ogni volta che questa
/// schermata è visibile. Questa vista si limita a leggere lo stato del tracker per mostrarlo.
struct ICloudSyncFolderView: View {
    @EnvironmentObject private var viewModel: LibraryViewModel
    @FetchRequest(sortDescriptors: []) private var comics: FetchedResults<ComicEntity>
    @ObservedObject private var tracker = ICloudDownloadTracker.shared

    @AppStorage("icloudSyncFolderEnabled") private var isEnabled = false

    private var isAvailable: Bool { LibraryStorage.isICloudAvailable }

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Sync Folder")
                    InfoButton(text: "Crea una cartella Chunky nella tua iCloud Drive.\nI fumetti che ci metti dentro restano sincronizzati con la tua libreria.\n\nSe li cancelli da Chunky, vengono cancellati anche da iCloud Drive.")
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
        .onChange(of: isEnabled) { _, newValue in
            // Se iCloud non era ancora pronto all'avvio dell'app, `start()` in
            // `ContentView.onAppear` è uscito subito senza fare nulla (è idempotente: non
            // fa danni a richiamarlo qui). Attivare il toggle dà così una seconda occasione di
            // agganciarsi, invece di restare inerte per il resto della sessione.
            if newValue { ICloudDownloadTracker.shared.start() }
        }
    }
}
