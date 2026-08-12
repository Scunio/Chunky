import SwiftUI

@main
struct ChunkyApp: App {
    let persistenceController = PersistenceController.shared
    @StateObject private var libraryViewModel = LibraryViewModel()
    @ObservedObject private var lock = ParentalLock.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let includeInBackup = UserDefaults.standard.object(forKey: "includeInBackup") as? Bool ?? true
        LibraryStorage.setExcludedFromBackup(!includeInBackup)
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
                            .background(BackgroundMaterialCompat().ignoresSafeArea())
                    }
                }
            }
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .background else { return }
            let triggerRawValue = UserDefaults.standard.string(forKey: "parentalLockAutoLockTrigger") ?? ""
            let trigger = ParentalAutoLockTrigger(rawValue: triggerRawValue) ?? .doNothing
            if trigger == .lockImmediately {
                lock.lockIfNeeded()
            }
        }
    }
}

/// Sfondo opaco per la schermata di blocco, senza dipendere dai materiali (iOS15+/macOS12+).
private struct BackgroundMaterialCompat: View {
    var body: some View {
        #if os(iOS)
        Color(.systemBackground)
        #else
        Color(NSColor.windowBackgroundColor)
        #endif
    }
}
