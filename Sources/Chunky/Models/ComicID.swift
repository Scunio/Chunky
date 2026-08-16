import CoreData
import Foundation

/// Identifier for a `ComicEntity` that crosses the `Codable`/`Hashable` boundaries
/// required by `WindowGroup(for:)`. `NSManagedObjectID` doesn't conform to `Codable`, so
/// the reader on Mac (one window per comic) passes this instead of the entity itself.
struct ComicID: Codable, Hashable {
    let uriString: String

    init?(_ comic: ComicEntity) {
        guard !comic.objectID.isTemporaryID else { return nil }
        self.uriString = comic.objectID.uriRepresentation().absoluteString
    }

    /// Resolves the identifier to the corresponding entity, if it still exists.
    ///
    /// The "not found" case isn't defensive: `PersistenceController` deletes and recreates the
    /// store when loading fails, so when a window is restored after an app restart, the comic
    /// it pointed to might no longer be there.
    func resolve(in context: NSManagedObjectContext) -> ComicEntity? {
        guard let url = URL(string: uriString),
              let objectID = context.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: url)
        else { return nil }
        return try? context.existingObject(with: objectID) as? ComicEntity
    }
}
