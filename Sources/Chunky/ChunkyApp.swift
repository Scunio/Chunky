import SwiftUI

@main
struct ChunkyApp: App {
    let persistenceController = PersistenceController.shared
    @StateObject private var libraryViewModel = LibraryViewModel()
    @ObservedObject private var lock = ParentalLock.shared
    @ObservedObject private var theme = AppTheme.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let includeInBackup = UserDefaults.standard.object(forKey: "includeInBackup") as? Bool ?? true
        LibraryStorage.setExcludedFromBackup(!includeInBackup)
        CrashReportManager.configure()
    }

    var body: some Scene {
        WindowGroup {
            if let loadError = persistenceController.loadError {
                StorageErrorView(error: loadError)
            } else {
                ZStack {
                    ContentView()
                        .environment(\.managedObjectContext, persistenceController.container.viewContext)
                        .environmentObject(libraryViewModel)
                        .onOpenURL { url in
                            libraryViewModel.importFiles([url], into: persistenceController.container.viewContext)
                        }

                    if lock.isLocked {
                        ParentalLockGateView()
                            .lockScreenBackground()
                    }
                }
                .preferredColorScheme(theme.colorSchemeMode.colorScheme)
            }
        }
        #if os(macOS)
        // La finestra ereditava una geometria salvata per la vecchia griglia piatta
        // (900×450): troppo bassa e larga per una sidebar, che ci finiva schiacciata dentro.
        // `windowResizability(.contentSize)` lascia comunque liberi di ridimensionare;
        // fissa solo il minimo utilizzabile e la dimensione iniziale.
        .defaultSize(width: 1100, height: 720)
        .windowResizability(.contentMinSize)
        .commands { ChunkyCommands() }
        #endif
        .onChange(of: scenePhase) { phase in
            guard phase == .background else { return }
            let triggerRawValue = UserDefaults.standard.string(forKey: "parentalLockAutoLockTrigger") ?? ""
            let trigger = ParentalAutoLockTrigger(rawValue: triggerRawValue) ?? .doNothing
            if trigger == .lockImmediately {
                lock.lockIfNeeded()
            }
        }

        #if os(macOS)
        // Una finestra per fumetto, invece del foglio piccolo e non ridimensionabile di
        // prima: ogni fumetto aperto vive nella propria finestra, chiudibile e spostabile
        // indipendentemente dalle altre.
        WindowGroup("Fumetto", for: ComicID.self) { $comicID in
            if let comicID {
                ReaderWindowContainer(comicID: comicID)
                    .environment(\.managedObjectContext, persistenceController.container.viewContext)
                    // Il reader espone Account/Strumenti dal proprio header: senza questo, la
                    // finestra reader non è più un .sheet di LibraryView e non eredita più
                    // l'environmentObject da lì. AccountsView legge @EnvironmentObject
                    // LibraryViewModel e crasherebbe senza.
                    .environmentObject(libraryViewModel)
            }
        }
        .defaultSize(width: 900, height: 720)
        .windowResizability(.contentMinSize)

        // ⌘, apre le Preferenze come finestra separata invece che dentro il foglio Tools —
        // dove restano raggiungibili anche su iOS.
        Settings {
            // Le Preferenze non devono restare accessibili da sotto il blocco genitori:
            // ⌘, apre comunque la finestra, ma mostra il lucchetto finché non si sblocca.
            //
            // Serve lo stesso `.environment` del WindowGroup principale: `DiagnosticsView` e
            // `ICloudStatusView`, raggiungibili da qui, leggono `LibraryViewModel` e il
            // `managedObjectContext` — senza questi la prima crasha e la seconda mostra
            // sempre zero fumetti.
            Group {
                if lock.isLocked {
                    ParentalLockGateView()
                        .lockScreenBackground()
                } else {
                    NavigationStack {
                        SettingsView()
                    }
                }
            }
            .environment(\.managedObjectContext, persistenceController.container.viewContext)
            .environmentObject(libraryViewModel)
            .sheetSized()
        }
        #endif
    }
}
