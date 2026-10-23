#import "ObjCExceptionCatcher.h"

@implementation ObjCExceptionCatcher

+ (nullable NSData *)safeBinaryValueForObject:(NSManagedObject *)object key:(NSString *)key {
    @try {
        id value = [object valueForKey:key];
        if (value == nil || value == (id)[NSNull null]) {
            return nil;
        }
        if (![value isKindOfClass:[NSData class]]) {
            return nil;
        }
        NSData *data = (NSData *)value;
        // Force `_PFExternalReferenceData` to load and copy its sidecar bytes now,
        // inside the `@try`. `dataWithData:` may return an optimized wrapper that
        // still defers materialization until Swift bridges it. Read the raw bytes
        // here and allocate a plain NSData so no Core Data proxy escapes the catch.
        NSUInteger length = data.length;
        return [[NSData alloc] initWithBytes:data.bytes length:length];
    } @catch (NSException *exception) {
        return nil;
    }
}

+ (void)clearBinaryValueForObject:(NSManagedObject *)object key:(NSString *)key {
    @try {
        [object setValue:nil forKey:key];
    } @catch (NSException *exception) {
        // Clearing must never crash either; worst case the dangling reference stays
        // and the next read degrades to nil again instead of aborting.
    }
}

@end
