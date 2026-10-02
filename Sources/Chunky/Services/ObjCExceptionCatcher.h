#import <CoreData/CoreData.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Catches the `NSException` Core Data throws when an external binary blob
/// (`allowsExternalBinaryDataStorage`) can no longer be materialized.
///
/// Concretely: `-[_PFExternalReferenceData _retrieveExternalData]` raises when the
/// sidecar file backing `coverImageData` is missing or unreadable (backup/restore
/// mismatch, user-deleted support files, CloudKit sync of the store, …). Swift
/// cannot catch `NSException`, so any direct `comic.coverImageData` access on such
/// a row aborts the process (SIGABRT) — which is exactly the TestFlight 1.0.2 crash
/// in `CoverThumbnailCache.image(for:)`.
///
/// Every entry point here wraps the faulting access in `@try/@catch` and degrades to
/// `nil` so callers can show the placeholder cover instead of crashing.
@interface ObjCExceptionCatcher : NSObject

/// Returns the binary value for `key` on `object`, or `nil` when the value is
/// genuinely missing or its external file cannot be materialized (exception caught).
/// The `length` call forces the external-data fault to fire inside the `@try`.
+ (nullable NSData *)safeBinaryValueForObject:(NSManagedObject *)object key:(NSString *)key;

/// Clears the binary value (drops a dangling external reference so the backfill pass
/// can regenerate the cover). Never throws; a no-op when the value is already nil.
+ (void)clearBinaryValueForObject:(NSManagedObject *)object key:(NSString *)key;

@end

NS_ASSUME_NONNULL_END
