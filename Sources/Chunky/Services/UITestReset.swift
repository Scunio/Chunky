import CoreData
import Foundation

/// `--uitesting-reset`: wipes everything a previous UI-test run left in the simulator (stores,
/// fixture files, preferences) so each launch starts from a known-clean state. Runs once per
/// process, before the first `PersistenceController`/`ParentalLock` instance reads anything.
enum UITestReset {
    static let launchArgument = "--uitesting-reset"

    static var isRequested: Bool {
        CommandLine.arguments.contains("--uitesting") && CommandLine.arguments.contains(launchArgument)
    }

    private static let defaultsKeys = [
        "appLanguage", "newTrayClearedAt", "parentalLockAutoLockTrigger",
        "parentalLock.enabled", "parentalLock.biometricsEnabled"
    ]

    private static let performOnce: Void = {
        let fileManager = FileManager.default
        #if os(macOS)
        // Safety net: never wipe anything on macOS unless it is the dedicated test sandbox
        // (an unsigned build is not sandboxed, so the default paths are the user's real folders).
        guard let sandbox = LibraryStorage.uiTestingSandboxURL,
              LibraryStorage.rootFolderURL().path.hasPrefix(sandbox.path + "/") else { return }
        let storeDirectory = sandbox.appendingPathComponent("Stores", isDirectory: true)
        #else
        let storeDirectory = NSPersistentContainer.defaultDirectoryURL()
        #endif
        for name in ["Chunky.sqlite", "ChunkyLocal.sqlite"] {
            for suffix in ["", "-wal", "-shm"] {
                try? fileManager.removeItem(at: storeDirectory.appendingPathComponent(name + suffix))
            }
        }
        try? fileManager.removeItem(at: LibraryStorage.rootFolderURL())
        try? fileManager.createDirectory(at: LibraryStorage.rootFolderURL(), withIntermediateDirectories: true)
        if LibraryStorage.localDocumentsURL != LibraryStorage.rootFolderURL() {
            // Seeded fixtures live directly in Documents on iOS/macOS.
            let documents = LibraryStorage.localDocumentsURL
            for url in (try? fileManager.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil)) ?? []
            where url.lastPathComponent.hasPrefix("uitest-") {
                try? fileManager.removeItem(at: url)
            }
        }
        #if !os(macOS)
        // On macOS an unsigned build shares the real app's preferences domain: never wipe the
        // user's own settings (language, parental lock...) from a test launch.
        for key in defaultsKeys { UserDefaults.standard.removeObject(forKey: key) }
        #endif
    }()

    /// Idempotent; no-op unless `--uitesting --uitesting-reset` were passed.
    static func performIfRequested() {
        guard isRequested else { return }
        _ = performOnce
    }
}
