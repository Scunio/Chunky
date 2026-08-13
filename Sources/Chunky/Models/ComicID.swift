import CoreData
import Foundation

/// Identificatore di un `ComicEntity` che attraversa i confini di `Codable`/`Hashable`
/// richiesti da `WindowGroup(for:)`. `NSManagedObjectID` non conforma a `Codable`, quindi
/// il reader su Mac (una finestra per fumetto) passa questo invece dell'entity stessa.
struct ComicID: Codable, Hashable {
    let uriString: String

    init?(_ comic: ComicEntity) {
        guard !comic.objectID.isTemporaryID else { return nil }
        self.uriString = comic.objectID.uriRepresentation().absoluteString
    }

    /// Risolve l'identificatore nell'entity corrispondente, se esiste ancora.
    ///
    /// Il caso "non trovato" non è difensivo: `PersistenceController` cancella e ricrea lo
    /// store quando il caricamento fallisce, quindi al ripristino di una finestra dopo un
    /// riavvio dell'app il fumetto a cui puntava potrebbe non esserci più.
    func resolve(in context: NSManagedObjectContext) -> ComicEntity? {
        guard let url = URL(string: uriString),
              let objectID = context.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: url)
        else { return nil }
        return try? context.existingObject(with: objectID) as? ComicEntity
    }
}
