import CoreData
import Foundation

extension ComicEntity {
    /// Per-device cover cache. The deprecated `coverImageData` attribute remains in the model
    /// solely to preserve the deployed CloudKit schema; application code must never use it.
    /// Exception-safe read of the local `coverImageDataInline` cache.
    ///
    /// Older versions stored `coverImageData` in external sidecars. If one goes missing,
    /// reading that deprecated property can raise an `NSException`, which Swift can't catch.
    /// This accessor touches only the new inline attribute.
    ///
    /// This accessor routes the faulting read through `ObjCExceptionCatcher` (`@try/@catch`)
    /// and degrades to `nil`, so the grid shows the placeholder cover. As a side effect it
    /// also heals the row: a corrupt inline value is cleared so the cover backfill pass can
    /// regenerate it. The heal is silent for genuinely-nil
    /// values — only an actual dangling reference logs and marks the object changed.
    var safeCoverImageData: Data? {
        if let data = ObjCExceptionCatcher.safeBinaryValue(for: self, key: "coverImageDataInline") {
            return data as Data
        }
        ObjCExceptionCatcher.clearBinaryValue(for: self, key: "coverImageDataInline")
        CoverThumbnailCache.invalidate(for: self)
        if changedValues()["coverImageDataInline"] != nil {
            DiagnosticLog.log("CoverThumbnail: riferimento esterno illeggibile rimosso, verrà rigenerata")
        }
        return nil
    }
}
