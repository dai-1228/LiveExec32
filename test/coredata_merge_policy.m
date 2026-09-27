#import <CoreData/CoreData.h>
#import <Foundation/Foundation.h>

#include <stdio.h>

static int failures;

static void check(const char *name, BOOL condition) {
    printf("%s: %s\n", name, condition ? "PASS" : "FAIL");
    failures += !condition;
}

int main(void) {
    NSAutoreleasePool *pool = [NSAutoreleasePool new];

    check("error-policy-export", NSErrorMergePolicy != nil);
    check("store-trump-policy-export",
        NSMergeByPropertyStoreTrumpMergePolicy != nil);
    check("object-trump-policy-export",
        NSMergeByPropertyObjectTrumpMergePolicy != nil);
    check("overwrite-policy-export", NSOverwriteMergePolicy != nil);
    check("rollback-policy-export", NSRollbackMergePolicy != nil);

    check("error-policy-singleton",
        NSErrorMergePolicy == [NSMergePolicy errorMergePolicy]);
    check("store-trump-policy-singleton",
        NSMergeByPropertyStoreTrumpMergePolicy ==
            [NSMergePolicy mergeByPropertyStoreTrumpMergePolicy]);
    check("object-trump-policy-singleton",
        NSMergeByPropertyObjectTrumpMergePolicy ==
            [NSMergePolicy mergeByPropertyObjectTrumpMergePolicy]);
    check("overwrite-policy-singleton",
        NSOverwriteMergePolicy == [NSMergePolicy overwriteMergePolicy]);
    check("rollback-policy-singleton",
        NSRollbackMergePolicy == [NSMergePolicy rollbackMergePolicy]);
    check("error-policy-type",
        [NSErrorMergePolicy mergeType] == NSErrorMergePolicyType);

    [pool drain];
    return failures ? 1 : 0;
}
