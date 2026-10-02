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
        // Force `_PFExternalReferenceData` to load its sidecar file now, inside the
        // `@try`: without this, the fault would fire later (during Swift Data
        // bridging) outside any handler and still crash.
        (void)[data length];
        return data;
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
