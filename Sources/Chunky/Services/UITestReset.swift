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
        let storeDirectory = NSPersistentContainer.defaultDirectoryURL()
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
        for key in defaultsKeys { UserDefaults.standard.removeObject(forKey: key) }
    }()

    /// Idempotent; no-op unless `--uitesting --uitesting-reset` were passed.
    static func performIfRequested() {
        guard isRequested else { return }
        _ = performOnce
    }
}
