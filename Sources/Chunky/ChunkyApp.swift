import SwiftUI

@main
struct ChunkyApp: App {
    let persistenceController = PersistenceController.shared
    @StateObject private var libraryViewModel = LibraryViewModel()
    @ObservedObject private var lock = ParentalLock.shared
    @ObservedObject private var theme = AppTheme.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let includeInBackup = UserDefaults.standard.object(forKey: "includeInBackup") as? Bool ?? false
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
        // `.contentMinSize` lascia liberi di ridimensionare oltre il minimo, fissando solo
        // dimensione minima e iniziale della finestra.
        .defaultSize(width: 1100, height: 720)
        .windowResizability(.contentMinSize)
        .commands { ChunkyCommands() }
        #endif
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            let triggerRawValue = UserDefaults.standard.string(forKey: "parentalLockAutoLockTrigger") ?? ""
            let trigger = ParentalAutoLockTrigger(rawValue: triggerRawValue) ?? .doNothing
            if trigger == .lockImmediately {
                lock.lockIfNeeded()
            }
        }

        #if os(macOS)
        // Una finestra per fumetto: ogni fumetto aperto vive nella propria finestra,
        // chiudibile e spostabile indipendentemente dalle altre.
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
        // dove restano raggiungibili anche su iOS. Una `Window` invece di `Settings`: quella
        // scena, con un pannello a sidebar come contenuto, si è rivelata dal vivo bloccata a
        // una dimensione fissa nonostante `.windowResizability` (né zoom né trascinamento del
        // bordo avevano effetto) e non offre `.defaultSize` per partire più alta — `Window` fa
        // entrambe le cose. `CommandGroup(replacing: .appSettings)` in ChunkyCommands tiene
        // ⌘, e la voce di menu "Impostazioni…" dove un utente Mac se le aspetta.
        Window("Impostazioni", id: "settings") {
            // Le Preferenze non devono restare accessibili da sotto il blocco genitori: la
            // finestra si apre comunque, ma mostra il lucchetto finché non si sblocca.
            //
            // Serve lo stesso `.environment` del WindowGroup principale: le sezioni Diagnostica
            // e Stato iCloud, raggiungibili da qui, leggono `LibraryViewModel` e il
            // `managedObjectContext` — senza questi la prima crasha e la seconda mostra
            // sempre zero fumetti.
            Group {
                if lock.isLocked {
                    ParentalLockGateView()
                        .lockScreenBackground()
                } else {
                    // Sidebar di categorie + pannello di dettaglio, come System Settings.app,
                    // invece dell'unica Form lunga e navigabile di SettingsView (quel pattern
                    // resta corretto per iOS, dove SettingsView è ancora usata).
                    MacSettingsView()
                }
            }
            .environment(\.managedObjectContext, persistenceController.container.viewContext)
            .environmentObject(libraryViewModel)
        }
        .defaultSize(width: 760, height: 640)
        .windowResizability(.contentMinSize)
        #endif
    }
}
