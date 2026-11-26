import SwiftUI

@main
struct ChunkyApp: App {
    @AppStorage("appLanguage") private var appLanguageRawValue = AppLanguage.system.rawValue
    // `@State` (non `let`) per il ripristino dalla schermata d'errore: "Riprova" riassegna
    // l'istanza ricreata e la schermata rivaluta `loadError` (errore di nuovo vs libreria aperta).
    @State private var persistenceController = PersistenceController.shared
    #if os(iOS)
    @UIApplicationDelegateAdaptor(ChunkyAppDelegate.self) private var appDelegate
    #elseif os(macOS)
    @NSApplicationDelegateAdaptor(ChunkyAppDelegate.self) private var appDelegate
    #endif
    @StateObject private var libraryViewModel = LibraryViewModel()
    @ObservedObject private var lock = ParentalLock.shared
    @ObservedObject private var theme = AppTheme.shared
    @Environment(\.scenePhase) private var scenePhase

    private var appLocale: Locale {
        (AppLanguage(rawValue: appLanguageRawValue) ?? .system).locale
    }

    init() {
        UITestReset.performIfRequested()
        UITestSeed.seedIfRequested()
        RetiredSettings.clean()
        // Default: off on iOS (the library is already in iCloud Drive, and device backups
        // count against the iCloud quota), on on macOS — a Mac user expects Time Machine to
        // cover the app's data, and excluding it there is opt-out, not a silent default.
        #if os(macOS)
        let defaultIncludeInBackup = true
        #else
        let defaultIncludeInBackup = false
        #endif
        let includeInBackup = UserDefaults.standard.object(forKey: "includeInBackup") as? Bool ?? defaultIncludeInBackup
        // rootFolderURL() may ask the ubiquity daemon for an iCloud container. Keep that
        // synchronous filesystem/IPC work off the main thread so a slow iCloud response
        // can't leave the first window blank.
        DispatchQueue.global(qos: .utility).async {
            LibraryStorage.setExcludedFromBackup(!includeInBackup)
        }
        CrashReportManager.configure()
        // Off-main: the first ubiquity-daemon round-trip must not land inside a view
        // body (see `LibraryStorage.isICloudAvailable`).
        LibraryStorage.warmICloudAvailability()
    }

    var body: some Scene {
        WindowGroup {
            if let loadError = persistenceController.loadError {
                StorageErrorView(error: loadError) {
                    persistenceController = PersistenceController.shared
                }
            } else {
                ZStack {
                    ContentView()
                        .environment(\.locale, appLocale)
                        .environment(\.managedObjectContext, persistenceController.container.viewContext)
                        .environmentObject(libraryViewModel)
                        #if os(macOS)
                        // Import, then open the reader on it: double-clicking a .cbz in the
                        // Finder is a request to read it, not just to file it away.
                        .modifier(OpenComicFilesFromFinder(
                            viewModel: libraryViewModel,
                            context: persistenceController.container.viewContext
                        ))
                        #else
                        .onOpenURL { url in
                            // A file handed over as a copy lands in Documents/Inbox: once imported
                            // into the library that copy is pure waste (and would otherwise pile up
                            // there forever). Only Inbox — with "open in place" the URL can be the
                            // user's own file in Files, which must never be deleted.
                            let inbox = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                                .appendingPathComponent("Inbox", isDirectory: true)
                                .standardizedFileURL.resolvingSymlinksInPath().path
                            let parent = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
                            libraryViewModel.importFiles(
                                [url],
                                into: persistenceController.container.viewContext,
                                cleaningTemporaryDirectories: url.isFileURL && parent == inbox ? [url] : []
                            )
                        }
                        #endif
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
            #if os(iOS)
            // Progress changed outside the reader (bulk "mark as read", a reader closed
            // seconds ago) may still sit in the push debounce: send it before suspension.
            RemoteProgressSync.flushPushInBackgroundTask()
            #endif
            let triggerRawValue = UserDefaults.standard.string(forKey: "parentalLockAutoLockTrigger") ?? ""
            let trigger = ParentalAutoLockTrigger(rawValue: triggerRawValue) ?? .platformDefault
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
                    .environment(\.locale, appLocale)
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
            .environment(\.locale, appLocale)
        }
        .defaultSize(width: 760, height: 640)
        .windowResizability(.contentMinSize)
        #endif
    }
}
