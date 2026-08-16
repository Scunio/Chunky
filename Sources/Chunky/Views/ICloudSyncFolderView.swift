import SwiftUI
import CoreData

/// "Sync Folder" screen reached from the "iCloud Drive" row of the Accounts panel.
///
/// Unlike the rest of the sync (which copies imported comics into the app's iCloud
/// container, see `LibraryStorage`), here the user explicitly enables automatic
/// matching of the "Chunky" folder visible in Files/Finder: files dragged into it
/// from another device get registered in the library without needing to reimport them by hand.
///
/// The actual rescan (observing `ICloudDownloadTracker`, started once by
/// `ContentView`, and calling `rebuildLibrary`) is centralized in `ContentView`, the root that's
/// always alive for the whole session: doing it here too would duplicate the scan every time this
/// screen is visible. This view just reads the tracker's state to display it.
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
            // If iCloud wasn't ready yet when the app launched, `start()` in
            // `ContentView.onAppear` returned immediately without doing anything (it's idempotent:
            // no harm in calling it again here). Enabling the toggle thus gives a second chance to
            // hook in, instead of staying inert for the rest of the session.
            if newValue { ICloudDownloadTracker.shared.start() }
        }
    }
}
