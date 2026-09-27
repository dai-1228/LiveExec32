#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>

#include <stdio.h>
#include <stdlib.h>

static int deallocations;

@interface LC32ArrayProbe : NSObject
@end

@implementation LC32ArrayProbe
- (void)dealloc {
    ++deallocations;
    [super dealloc];
}
@end

static int report(const char *name, int passed) {
    printf("cfarray-callbacks-%s: %s\n", name, passed ? "PASS" : "FAIL");
    return passed;
}

static Boolean hasValues(CFArrayRef array, const void **values, CFIndex count) {
    if(!array || CFArrayGetCount(array) != count) return false;
    for(CFIndex index = 0; index < count; ++index) {
        if(CFArrayGetValueAtIndex(array, index) != values[index]) return false;
    }
    return true;
}

typedef struct {
    const void *values[8];
    CFIndex count;
    unsigned comparisons;
} CallbackContext;

static CFComparisonResult comparePointers(const void *first, const void *second,
                                           void *rawContext) {
    CallbackContext *context = rawContext;
    ++context->comparisons;
    /* The zeroed first words deliberately cannot be an Objective-C isa.
     * Keep the sort key away from those words to test raw, non-object data. */
    unsigned firstRank = first ? ((const unsigned char *)first)[16] : 0;
    unsigned secondRank = second ? ((const unsigned char *)second)[16] : 0;
    if(firstRank < secondRank) return kCFCompareLessThan;
    if(firstRank > secondRank) return kCFCompareGreaterThan;
    return kCFCompareEqualTo;
}

static void collectPointer(const void *value, void *rawContext) {
    CallbackContext *context = rawContext;
    if(context->count < 8) context->values[context->count] = value;
    ++context->count;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    @autoreleasepool {
        int passed = 1;
        unsigned char *first = calloc(1, 64);
        unsigned char *second = calloc(1, 64);
        unsigned char *third = calloc(1, 64);
        unsigned char *fourth = calloc(1, 64);
        if(!first || !second || !third || !fourth) {
            free(first); free(second); free(third); free(fourth);
            report("allocate-raw-values", false);
            return 1;
        }

        CFMutableArrayRef array = CFArrayCreateMutable(kCFAllocatorDefault, 0, NULL);
        passed &= report("null-create", array != NULL);
        CFArrayAppendValue(array, first);
        CFArrayAppendValue(array, NULL);
        CFArrayAppendValue(array, second);
        CFArrayAppendValue(array, first);
        const void *initial[] = {first, NULL, second, first};
        passed &= report("null-append-raw-values", hasValues(array, initial, 4));
        passed &= report("null-pointer-search",
            CFArrayContainsValue(array, CFRangeMake(0, 4), first) &&
            !CFArrayContainsValue(array, CFRangeMake(0, 4), third) &&
            CFArrayGetCountOfValue(array, CFRangeMake(0, 4), first) == 2 &&
            CFArrayGetFirstIndexOfValue(array, CFRangeMake(1, 3), first) == 3 &&
            CFArrayGetLastIndexOfValue(array, CFRangeMake(0, 4), first) == 3 &&
            CFArrayGetFirstIndexOfValue(array, CFRangeMake(1, 2), first) == kCFNotFound &&
            CFArrayGetFirstIndexOfValue(array, CFRangeMake(0, 4), NULL) == 1);
        const void *rangeValues[] = {fourth, fourth, fourth, fourth};
        CFArrayGetValues(array, CFRangeMake(1, 2), &rangeValues[1]);
        passed &= report("null-get-values-range", rangeValues[0] == fourth &&
            rangeValues[1] == NULL && rangeValues[2] == second && rangeValues[3] == fourth);

        CFArrayInsertValueAtIndex(array, 1, third);
        CFArraySetValueAtIndex(array, 0, second);
        CFArraySetValueAtIndex(array, CFArrayGetCount(array), fourth);
        const void *inserted[] = {second, third, NULL, second, first, fourth};
        passed &= report("null-insert-set-and-set-at-end", hasValues(array, inserted, 6));
        CFArrayExchangeValuesAtIndices(array, 0, 4);
        CFArrayRemoveValueAtIndex(array, 3);
        const void *removed[] = {first, third, NULL, second, fourth};
        passed &= report("null-exchange-remove", hasValues(array, removed, 5));

        const void *replacement[] = {fourth, first, third};
        CFArrayReplaceValues(array, CFRangeMake(1, 2), replacement, 3);
        const void *grown[] = {first, fourth, first, third, second, fourth};
        passed &= report("null-replace-grow", hasValues(array, grown, 6));
        const void *nullValue[] = {NULL};
        CFArrayReplaceValues(array, CFRangeMake(1, 3), nullValue, 1);
        const void *shrunk[] = {first, NULL, second, fourth};
        passed &= report("null-replace-shrink", hasValues(array, shrunk, 4));
        CFArrayReplaceValues(array, CFRangeMake(1, 1), NULL, 0);
        const void *deleted[] = {first, second, fourth};
        passed &= report("null-replace-delete", hasValues(array, deleted, 3));

        const void *immutableValues[] = {third, NULL, first};
        CFArrayRef immutable = CFArrayCreate(kCFAllocatorDefault, immutableValues, 3, NULL);
        passed &= report("null-immutable-create", hasValues(immutable, immutableValues, 3));
        CFArrayAppendArray(array, immutable, CFRangeMake(0, 2));
        const void *appended[] = {first, second, fourth, third, NULL};
        passed &= report("null-append-array", hasValues(array, appended, 5));
        CFArrayRef copy = CFArrayCreateCopy(kCFAllocatorDefault, array);
        CFMutableArrayRef mutableCopy = CFArrayCreateMutableCopy(kCFAllocatorDefault, 0, array);
        CFArrayRemoveAllValues(array);
        CFRelease(array);
        passed &= report("null-copy-callbacks", hasValues(copy, appended, 5) &&
            hasValues(mutableCopy, appended, 5));

        first[16] = 30; second[16] = 10; third[16] = 20; fourth[16] = 40;
        CallbackContext context = {};
        CFArraySortValues(mutableCopy, CFRangeMake(0, 5), comparePointers, &context);
        const void *sorted[] = {NULL, second, third, first, fourth};
        passed &= report("null-sort-guest-comparator", hasValues(mutableCopy, sorted, 5) &&
            context.comparisons > 0);
        unsigned char searchValue[64] = {};
        searchValue[16] = 25;
        passed &= report("null-binary-search", CFArrayBSearchValues(mutableCopy,
            CFRangeMake(0, 5), first, comparePointers, &context) == 3 &&
            CFArrayBSearchValues(mutableCopy, CFRangeMake(1, 4), searchValue,
                comparePointers, &context) == 3);
        CFArrayApplyFunction(mutableCopy, CFRangeMake(0, 5), collectPointer, &context);
        Boolean applied = context.count == 5;
        for(CFIndex index = 0; index < context.count && index < 5; ++index)
            applied &= context.values[index] == sorted[index];
        passed &= report("null-apply-guest-callback", applied);
        CFArrayRemoveAllValues(mutableCopy);
        passed &= report("null-remove-all", CFArrayGetCount(mutableCopy) == 0);
        CFRelease(mutableCopy);
        CFRelease(copy);
        CFRelease(immutable);

        const CFArrayCallBacks zeroCallbacks = {};
        CFMutableArrayRef zeroArray = CFArrayCreateMutable(kCFAllocatorDefault, 0, &zeroCallbacks);
        CFArrayAppendValue(zeroArray, third);
        CFArrayAppendValue(zeroArray, NULL);
        const void *zeroValues[] = {third, NULL};
        CFArrayRef zeroImmutable = CFArrayCreate(kCFAllocatorDefault, zeroValues, 2, &zeroCallbacks);
        passed &= report("zero-callback-struct", hasValues(zeroArray, zeroValues, 2) &&
            hasValues(zeroImmutable, zeroValues, 2));
        free(first); free(second); free(third); free(fourth);
        /* Teardown must not dereference or release the now-freed raw values. */
        CFRelease(zeroArray);
        CFRelease(zeroImmutable);
        passed &= report("raw-values-owned-by-caller", true);

        CFMutableArrayRef nonretaining = CFArrayCreateMutable(kCFAllocatorDefault, 0, NULL);
        LC32ArrayProbe *weakProbe = [LC32ArrayProbe new];
        CFArrayAppendValue(nonretaining, weakProbe);
        [weakProbe release];
        passed &= report("null-does-not-retain", deallocations == 1);
        CFRelease(nonretaining);

        CFMutableArrayRef retaining = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
        LC32ArrayProbe *strongProbe = [LC32ArrayProbe new];
        CFArrayAppendValue(retaining, strongProbe);
        [strongProbe release];
        passed &= report("cftype-retains", deallocations == 1 && CFArrayGetCount(retaining) == 1 &&
            CFArrayGetValueAtIndex(retaining, 0) == strongProbe);
        CFArrayRef retainingCopy = CFArrayCreateCopy(kCFAllocatorDefault, retaining);
        CFRelease(retaining);
        passed &= report("cftype-copy-retains", deallocations == 1 &&
            CFArrayGetValueAtIndex(retainingCopy, 0) == strongProbe);
        CFRelease(retainingCopy);
        passed &= report("cftype-releases", deallocations == 2);

        printf("cfarray-callbacks-regression: %s\n", passed ? "PASS" : "FAIL");
        return !passed;
    }
}
