import Foundation
import CoreData
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Copertine già decodificate dai PNG salvati in `coverImageData`.
///
/// Senza questa cache, `ComicGridItemView` ridecodificava la copertina a ogni valutazione di
/// `body` — non solo alla comparsa della cella, ma a ogni ridisegno innescato da
/// `ICloudDownloadTracker`. Con un gruppo da un centinaio di fumetti che appare tutto insieme
/// (es. espandendo una sezione), decine di decodifiche sincrone sul thread principale nella
/// stessa animazione bastavano a farla scattare a scatti.
enum CoverThumbnailCache {
    private static let cache: NSCache<NSManagedObjectIDBox, PlatformImage> = {
        let cache = NSCache<NSManagedObjectIDBox, PlatformImage>()
        cache.countLimit = 400
        return cache
    }()

    static func image(for comic: ComicEntity) -> PlatformImage? {
        guard let objectID = comic.objectID as NSManagedObjectID?, !objectID.isTemporaryID else {
            return comic.coverImageData.flatMap(PlatformImage.from(data:))
        }
        let key = NSManagedObjectIDBox(objectID)
        if let cached = cache.object(forKey: key) { return cached }
        guard let data = comic.coverImageData, let decoded = PlatformImage.from(data: data) else { return nil }
        cache.setObject(decoded, forKey: key)
        return decoded
    }
}

/// `NSManagedObjectID` non è una classe: `NSCache` richiede chiavi `AnyObject`, quindi va
/// incapsulato invece di usarlo direttamente.
final class NSManagedObjectIDBox: NSObject {
    let objectID: NSManagedObjectID
    init(_ objectID: NSManagedObjectID) { self.objectID = objectID }
    override var hash: Int { objectID.hash }
    override func isEqual(_ object: Any?) -> Bool {
        (object as? NSManagedObjectIDBox)?.objectID == objectID
    }
}
