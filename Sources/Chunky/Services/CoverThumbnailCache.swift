import Foundation
import CoreData
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Covers already decoded from the PNGs stored in `coverImageData`.
///
/// Without this cache, `ComicGridItemView` would re-decode the cover on every evaluation of
/// `body` — not just when the cell appears, but on every redraw triggered by
/// `ICloudDownloadTracker`. With a batch of a hundred or so comics appearing all at once
/// (e.g. expanding a section), dozens of synchronous decodes on the main thread within the
/// same animation were enough to make it stutter.
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

/// `NSManagedObjectID` isn't a class: `NSCache` requires `AnyObject` keys, so it needs
/// to be boxed instead of being used directly.
final class NSManagedObjectIDBox: NSObject {
    let objectID: NSManagedObjectID
    init(_ objectID: NSManagedObjectID) { self.objectID = objectID }
    override var hash: Int { objectID.hash }
    override func isEqual(_ object: Any?) -> Bool {
        (object as? NSManagedObjectIDBox)?.objectID == objectID
    }
}
