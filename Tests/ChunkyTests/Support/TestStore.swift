import Foundation
import CoreData
import Testing

/// Stack Core Data in memoria, indipendente da `PersistenceController` (che usa
/// `NSPersistentCloudKitContainer` e quindi vorrebbe gli entitlement iCloud). Il modello si
/// prende dal bundle dei test, dove il target compila anche le risorse dell'app.
///
/// Condiviso fra i suite proprio per la cache qui sotto: due copie private caricherebbero il
/// modello due volte.
enum TestStore {
    /// Una sola istanza del modello per tutto il processo: caricarlo una volta per contesto
    /// registra più `NSEntityDescription` per la stessa classe, e Core Data lo segnala con
    /// "Failed to find a unique match for an NSEntityDescription to a managed object subclass".
    nonisolated(unsafe) private static var cachedModel: NSManagedObjectModel?

    private static func model() throws -> NSManagedObjectModel {
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
