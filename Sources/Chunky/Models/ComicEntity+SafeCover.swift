import CoreData
import Foundation

extension ComicEntity {
    /// Exception-safe read of `coverImageData`.
    ///
    /// `coverImageData` uses `allowsExternalBinaryDataStorage`, so Core Data keeps large
    /// covers in sidecar files outside the SQLite store. When such a file goes missing
    /// (restore/backup mismatch, deleted support files, CloudKit store sync), merely
    /// evaluating `comic.coverImageData` raises an `NSException` inside
    /// `-[_PFExternalReferenceData _retrieveExternalData]` — uncatchable in Swift — and
    /// the process aborts (SIGABRT). That is the TestFlight 1.0.2 crash in
    /// `CoverThumbnailCache.image(for:)` (`CoverThumbnailCache.swift:29`).
    ///
    /// This accessor routes the faulting read through `ObjCExceptionCatcher` (`@try/@catch`)
    /// and degrades to `nil`, so the grid shows the placeholder cover. As a side effect it
    /// also heals the row: a corrupt external reference is cleared (a no-op when the value
    /// was genuinely nil), so the store can save again and the cover backfill pass
    /// (`coverImageData == nil`) can regenerate it. The heal is silent for genuinely-nil
    /// values — only an actual dangling reference logs and marks the object changed.
    var safeCoverImageData: Data? {
        if let data = ObjCExceptionCatcher.safeBinaryValue(for: self, key: "coverImageData") {
            return data as Data
        }
        ObjCExceptionCatcher.clearBinaryValue(for: self, key: "coverImageData")
        if changedValues()["coverImageData"] != nil {
            DiagnosticLog.log("CoverThumbnail: riferimento esterno illeggibile rimosso, verrà rigenerata")
        }
        return nil
    }
}
