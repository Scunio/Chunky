import SwiftUI

@main
struct ChunkyApp: App {
    let persistenceController = PersistenceController.shared
    @StateObject private var libraryViewModel = LibraryViewModel()
    @ObservedObject private var lock = ParentalLock.shared
    @ObservedObject private var theme = AppTheme.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        UITestSeed.seedIfRequested()
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
                        // An opaque overlay on top doesn't stop tvOS's remote focus from
                        // reaching this underneath it — has to be disabled explicitly.
                        .disabled(lock.isLocked)

                    if lock.isLocked {
                        ParentalLockGateView()
                            .lockScreenBackground()
                    }
                }
                .preferredColorScheme(theme.colorSchemeMode.colorScheme)
            }
        }
        #if os(macOS)
        // `.contentMinSize` leaves us free to resize beyond the minimum, fixing only the
        // window's minimum and initial size.
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
        // One window per comic: each open comic lives in its own window,
        // closable and movable independently of the others.
        WindowGroup("Fumetto", for: ComicID.self) { $comicID in
            if let comicID {
                ReaderWindowContainer(comicID: comicID)
                    .environment(\.managedObjectContext, persistenceController.container.viewContext)
                    // The reader exposes Account/Tools from its own header: without this, the
                    // reader window is no longer a .sheet of LibraryView and no longer inherits
                    // the environmentObject from there. AccountsView reads @EnvironmentObject
                    // LibraryViewModel and would crash without it.
                    .environmentObject(libraryViewModel)
            }
        }
        .defaultSize(width: 900, height: 720)
        .windowResizability(.contentMinSize)

        // ⌘, opens Preferences as a separate window instead of inside the Tools sheet —
        // where they remain reachable on iOS too. A `Window` instead of `Settings`: that
        // scene, with a sidebar panel as content, turned out in practice to be locked to
        // a fixed size despite `.windowResizability` (neither zooming nor dragging the
        // edge had any effect) and doesn't offer `.defaultSize` to start out taller — `Window`
        // does both. `CommandGroup(replacing: .appSettings)` in ChunkyCommands keeps
        // ⌘, and the "Settings…" menu item where a Mac user expects them.
        Window("Impostazioni", id: "settings") {
            // Preferences must not remain accessible from under the parental lock: the
            // window still opens, but shows the lock icon until it's unlocked.
            //
            // Needs the same `.environment` as the main WindowGroup: the Diagnostics
            // and iCloud Status sections, reachable from here, read `LibraryViewModel` and
            // `managedObjectContext` — without these the first crashes and the second always
            // shows zero comics.
            Group {
                if lock.isLocked {
                    ParentalLockGateView()
                        .lockScreenBackground()
                } else {
                    // Category sidebar + detail pane, like System Settings.app,
                    // instead of the single long scrollable Form of SettingsView (that pattern
                    // is still correct for iOS, where SettingsView is still used).
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
