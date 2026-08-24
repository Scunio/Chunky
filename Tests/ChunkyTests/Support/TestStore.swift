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
    private static let modelLock = NSLock()

    private static func model() throws -> NSManagedObjectModel {
        modelLock.lock()
        defer { modelLock.unlock() }
        if let cachedModel { return cachedModel }
        let bundle = Bundle(for: ComicEntity.self)
        let modelURL = try #require(bundle.url(forResource: "Chunky", withExtension: "momd"))
        let model = try #require(NSManagedObjectModel(contentsOf: modelURL))
        cachedModel = model
        return model
    }

    static func makeContext() throws -> NSManagedObjectContext {
        let container = NSPersistentContainer(name: "Chunky", managedObjectModel: try model())
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]

        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }
        return container.viewContext
    }
}
