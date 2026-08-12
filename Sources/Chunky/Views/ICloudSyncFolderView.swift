import SwiftUI
import CoreData

/// Schermata "Sync Folder" raggiunta dalla riga "iCloud Drive" del pannello Account.
///
/// A differenza del resto della sincronizzazione (che copia i fumetti importati nel container
/// iCloud dell'app, vedi `LibraryStorage`), qui l'utente attiva esplicitamente un riscontro
/// automatico della cartella "Chunky" visibile in Files/Finder: i file che ci trascina dentro
/// da un altro dispositivo vengono registrati in libreria senza bisogno di reimportarli a mano.
///
/// Nota di scope: non usa NSMetadataQuery per un watch continuo in background (richiederebbe
/// entitlement e affidabilità che vanno oltre questa ricostruzione); mentre questa schermata è
/// aperta, un timer periodico rilancia la stessa scansione usata da "Ripristina libreria" nelle
/// Impostazioni avanzate, così i nuovi file depositati nella cartella vengono rilevati in pochi
/// secondi.
struct ICloudSyncFolderView: View {
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var viewModel: LibraryViewModel
    @FetchRequest(sortDescriptors: []) private var comics: FetchedResults<ComicEntity>

    @AppStorage("icloudSyncFolderEnabled") private var isEnabled = false
    @State private var isShowingInfo = false

    private let pollInterval: TimeInterval = 5
    @State private var pollTimer: Timer?

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
        .onAppear { syncIfNeeded() }
        .onDisappear { pollTimer?.invalidate(); pollTimer = nil }
        .onChange(of: isEnabled) { newValue in
            if newValue { syncIfNeeded() } else { pollTimer?.invalidate(); pollTimer = nil }
        }
    }

    private func syncIfNeeded() {
        guard isEnabled, isAvailable else { return }
        viewModel.rebuildLibrary(context: context)
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { _ in
            viewModel.rebuildLibrary(context: context)
        }
    }
}
