import SwiftUI
import CoreData

/// "iCloud Drive" screen reached from the Accounts panel: explains where the library lives and
/// shows its sync state.
///
/// There used to be a "Cartella di sincronizzazione" toggle here, defaulting to off, that gated
/// the whole reconcile with the iCloud folder — while the library lives in that folder anyway
/// (`LibraryStorage.rootFolderURL`). With it off, files added from Finder never appeared and
/// files deleted there stayed in the library forever. The reconcile now always runs when iCloud
/// is available (`ContentView.syncSyncFolderIfNeeded`), so there's nothing left to switch.
///
/// The actual rescan (observing `ICloudDownloadTracker` and calling `rebuildLibrary`) is
/// centralized in `ContentView`, the root that's alive for the whole session: this view only
/// reads the state to display it.
struct ICloudSyncFolderView: View {
    @EnvironmentObject private var viewModel: LibraryViewModel
    @Environment(\.managedObjectContext) private var context
    @StateObject private var comicResults = SafeComicResults()

    private var isAvailable: Bool { LibraryStorage.isICloudAvailable }

    var body: some View {
        Form {
            if isAvailable {
                Section(footer: Text("La libreria di Chunky si trova nella cartella Chunky di iCloud Drive, visibile in File e nel Finder: i fumetti che ci aggiungi compaiono in Chunky su tutti i tuoi dispositivi. Se elimini un fumetto da Chunky, viene eliminato anche da iCloud Drive; se lo elimini da iCloud Drive, sparisce da Chunky poco dopo.")) {
                    HStack {
                        Text("Scaricati")
                        Spacer()
                        Text(AppLocalization.plural(
                            comicResults.comics.count,
                            singularKey: "%d fumetto",
                            pluralKey: "%d fumetti",
                            comment: "Number of comics in the iCloud sync folder"
                        ))
                            .foregroundColor(.secondary)
                    }
                    Text(viewModel.isImporting ? "Sincronizzazione…" : "Tutti i fumetti sincronizzati")
                        .foregroundColor(.secondary)
                }
            } else {
                Section(footer: Text("Attiva iCloud Drive nelle Impostazioni di sistema per usare questa funzione.")) {
                    EmptyView()
                }
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .tvOSListFocusFix()
        .navigationTitle("iCloud Drive")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            // If iCloud wasn't ready when the app launched, `start()` in `ContentView.onAppear`
            // returned without doing anything; it's idempotent, so this is a second chance.
            ICloudDownloadTracker.shared.start()
            comicResults.start(in: context)
        }
        .onDisappear { comicResults.stop() }
    }
}

#Preview {
    let controller = PersistenceController(inMemory: true)
    return ICloudSyncFolderView()
        .environment(\.managedObjectContext, controller.container.viewContext)
        .environmentObject(LibraryViewModel())
}
