import Foundation
import CoreData
import Testing

/// In-memory Core Data stack, independent of `PersistenceController` (which uses
/// `NSPersistentCloudKitContainer` and would therefore want the iCloud entitlements). The
/// model is taken from the test bundle, where the target also builds the app's resources.
///
/// Shared across suites precisely because of the cache below: two private copies would load
/// the model twice.
enum TestStore {
    /// A single instance of the model for the whole process: loading it once per context
    /// registers multiple `NSEntityDescription`s for the same class, and Core Data flags it
    /// with "Failed to find a unique match for an NSEntityDescription to a managed object subclass".
    ///
    /// Swift Testing runs suites concurrently by default, and `makeContext()` is called from
    /// every test — without a lock, two tests racing on the very first call could both find
    /// `cachedModel` nil and load/assign it independently, one context ending up with a
    /// different `NSManagedObjectModel` instance than another and Core Data quietly losing
    /// writes across them. Confirmed as the cause of an intermittent CI-only failure (never
    /// reproduced locally, where the full suite finishes fast enough not to race) in
    /// `LibraryDeduplicationTests`: two comics saved to two separately-modeled contexts,
    /// visible as "should have 2 records, has fewer" rather than a crash.
    nonisolated(unsafe) private static var cachedModel: NSManagedObjectModel?
    /// Un'istanza per versione ("Chunky 2", …): come sopra, ricaricare la stessa versione due volte
    /// duplicherebbe le `NSEntityDescription` per `ComicEntity` ("Failed to find a unique match").
    nonisolated(unsafe) private static var cachedVersionedModels: [String: NSManagedObjectModel] = [:]
    private static let modelLock = NSLock()

    private static func model(versionName: String? = nil) throws -> NSManagedObjectModel {
        // Versioned models bypass the current-model cache (they exist precisely to test one
        // shape), but each version is still loaded once — see `cachedVersionedModels`.
        if let versionName {
            modelLock.lock()
            defer { modelLock.unlock() }
            if let cached = cachedVersionedModels[versionName] { return cached }
            let bundle = Bundle(for: ComicEntity.self)
            let versionURL = try #require(bundle.url(forResource: versionName, withExtension: "mom", subdirectory: "Chunky.momd"))
            let versioned = try #require(NSManagedObjectModel(contentsOf: versionURL))
            cachedVersionedModels[versionName] = versioned
            return versioned
        }
        modelLock.lock()
        defer { modelLock.unlock() }
        if let cachedModel { return cachedModel }
        let bundle = Bundle(for: ComicEntity.self)
        let modelURL = try #require(bundle.url(forResource: "Chunky", withExtension: "momd"))
        let model = try #require(NSManagedObjectModel(contentsOf: modelURL))
        cachedModel = model
        return model
    }

    static func makeContext(modelVersion: String? = nil) throws -> NSManagedObjectContext {
        let container = NSPersistentContainer(name: "Chunky", managedObjectModel: try model(versionName: modelVersion))
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]

        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }
        return container.viewContext
    }

    /// File-backed SQLite stack sharing the cached model (same instance, so no duplicate
    /// `NSEntityDescription` risk — see `cachedModel`). Needed where the in-memory store
    /// isn't enough: persistent history is unsupported by `NSInMemoryStoreType`.
    /// Returns a cleanup closing over the store files; callers remove them with `defer`.
    static func makeSQLiteContext(historyTracking: Bool = false, modelVersion: String? = nil) throws -> (NSManagedObjectContext, () -> Void) {
        let (context, _, cleanup) = try makeSQLiteStore(historyTracking: historyTracking, modelVersion: modelVersion)
        return (context, cleanup)
    }

    /// Come `makeSQLiteContext`, ma espone anche l'URL dello store: serve per riaprirlo con un
    /// altro modello (test di migrazione v2→v3). Il container va buttato prima di riaprire —
    /// SQLite permette più connessioni, ma il test deve simulare un riavvio pulito.
    static func makeSQLiteStore(historyTracking: Bool = false, modelVersion: String? = nil) throws -> (NSManagedObjectContext, URL, () -> Void) {
        let container = NSPersistentContainer(name: "Chunky", managedObjectModel: try model(versionName: modelVersion))
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TestStore-\(UUID().uuidString).sqlite")
        let description = NSPersistentStoreDescription(url: storeURL)
        if historyTracking {
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        }
        container.persistentStoreDescriptions = [description]

        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }
        let cleanup = {
            for url in [storeURL,
                        storeURL.appendingPathExtension("shm"),
                        storeURL.appendingPathExtension("wal")] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        return (container.viewContext, storeURL, cleanup)
    }
}
