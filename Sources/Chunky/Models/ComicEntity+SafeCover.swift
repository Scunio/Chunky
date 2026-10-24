import CoreData
import Foundation

extension ComicEntity {
    /// Per-device cover cache. The deprecated `coverImageData` attribute remains in the model
    /// to preserve the deployed CloudKit schema and may still contain a synced cover on existing
    /// records. Prefer the local cache, then safely copy that legacy value into the cache.
    ///
    /// Older versions stored `coverImageData` in external sidecars. If one goes missing,
    /// reading that deprecated property can raise an `NSException`, which Swift can't catch.
    /// Reading either field is guarded because the legacy value may reference a missing sidecar.
    ///
    /// Both reads route through `ObjCExceptionCatcher` (`@try/@catch`) because the legacy field
    /// may be backed by a missing external sidecar. An unreadable legacy value degrades to `nil`;
    /// the cover backfill can then regenerate it from the comic archive.
    var safeCoverImageData: Data? {
        if let data = ObjCExceptionCatcher.safeBinaryValue(for: self, key: "coverImageDataInline") {
            return data as Data
        }
        ObjCExceptionCatcher.clearBinaryValue(for: self, key: "coverImageDataInline")

        // Existing CloudKit records can still have the old synced field populated, especially
        // when their store could not complete the staged migration on an earlier app build.
        // Read it behind the Objective-C exception boundary and preserve it locally. Do not clear
        // the legacy field: it is still part of the deployed CloudKit schema and may be the only
        // surviving copy on another device.
        if let legacyData = ObjCExceptionCatcher.safeBinaryValue(for: self, key: "coverImageData") {
            coverImageDataInline = legacyData
            CoverThumbnailCache.invalidate(for: self)
            return legacyData
        }

        CoverThumbnailCache.invalidate(for: self)
        if changedValues()["coverImageDataInline"] != nil {
            DiagnosticLog.log("CoverThumbnail: riferimento esterno illeggibile rimosso, verrà rigenerata")
        }
        return nil
    }
}
