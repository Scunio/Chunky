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
        // inside the `@try`. Returning the proxy itself is unsafe: Swift's
        // `NSData` -> `Data` bridge can trigger `_retrieveExternalData` only after
        // this method returns, outside the exception handler. An owned copy has
        // no deferred Core Data fault when Swift bridges it.
        return [NSData dataWithData:data];
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
