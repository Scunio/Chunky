import Foundation
import CoreData
import ImageIO
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Thumbnail delle cover già decodificate dai PNG in `coverImageData`.
///
/// Without this cache, `ComicGridItemView` would re-decode the cover on every evaluation of
/// `body` — not just when the cell appears, but on every redraw triggered by
/// `ICloudDownloadTracker`. With a batch of a hundred or so comics appearing all at once
/// (e.g. expanding a section), dozens of synchronous decodes on the main thread within the
/// same animation were enough to make it stutter.
enum CoverThumbnailCache {
    /// Larghezza/altezza massima della thumbnail: le celle della libreria sono ~130–180pt
    /// (max ~360px a 2x), i popover ~280pt (~560px a 2x). 600px li copre entrambi con
    /// margine senza decodificare cover da 2000px+ e — soprattutto — senza riscalare
    /// l'originale a ogni frame: su macOS `Image(nsImage:).resizable()` riscalava
    /// l'immagine intera a ogni compositing, sul main thread, ed è la causa principale
    /// dello scroll scattoso della libreria rispetto a iPhone.
    private static let thumbnailMaxPixelSize = 600

    private static let cache: NSCache<NSManagedObjectIDBox, PlatformImage> = {
        let cache = NSCache<NSManagedObjectIDBox, PlatformImage>()
        cache.countLimit = 400
        return cache
    }()

    static func image(for comic: ComicEntity) -> PlatformImage? {
        // `safeCoverImageData`, not `coverImageData`: when the sidecar file backing
        // this external-binary attribute goes missing, a direct access raises an
        // NSException (`_PFExternalReferenceData _retrieveExternalData`) that Swift
        // cannot catch and the app aborts — the TestFlight 1.0.2 grid crash.
        guard let objectID = comic.objectID as NSManagedObjectID?, !objectID.isTemporaryID else {
            return comic.safeCoverImageData.flatMap(PlatformImage.from(data:))
        }
        let key = NSManagedObjectIDBox(objectID)
        if let cached = cache.object(forKey: key) { return cached }
        guard let data = comic.safeCoverImageData else { return nil }
        // Downsample ImageIO invece del decode intero: legge solo i pixel della
        // thumbnail (veloce e a risoluzione già dimezzata), con fallback al decode
        // completo se il formato non lo supporta.
        guard let decoded = thumbnail(from: data) ?? PlatformImage.from(data: data) else { return nil }
        cache.setObject(decoded, forKey: key)
        return decoded
    }

    /// Decode ridotto via `CGImageSourceCreateThumbnailAtIndex`: non carica mai il bitmap
    /// intero in memoria e restituisce un'immagine già alle dimensioni di presentazione,
    /// così la cella non deve riscalare nulla durante lo scroll.
    private static func thumbnail(from data: Data) -> PlatformImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixelSize
              ] as CFDictionary) else { return nil }
        #if canImport(UIKit)
        return PlatformImage(cgImage: cg)
        #elseif canImport(AppKit)
        // Size reale, non `.zero`: `Image(nsImage:)` + `.aspectRatio` derivano le
        // proporzioni dalla size, e a zero le celle collasserebbero.
        return PlatformImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        #else
        return nil
        #endif
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
