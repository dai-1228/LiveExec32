#import <Foundation/Foundation.h>

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#if __has_feature(objc_arc)
#error This regression checks the legacy retained error-string contract.
#endif

static unsigned failures;

static void check(const char *name, BOOL passed) {
    printf("property-list-%s: %s\n", name, passed ? "PASS" : "FAIL");
    failures += !passed;
}

typedef struct {
    uint32_t before;
    NSPropertyListFormat value;
    uint32_t after;
} FormatSlot;

static BOOL intact(FormatSlot slot) {
    return slot.before == 0x12345678 && slot.after == 0x87654321;
}

static FormatSlot formatSlot(void) {
    const FormatSlot slot = {0x12345678, 0x76543210, 0x87654321};
    return slot;
}

int main(void) {
    NSAutoreleasePool *pool = [NSAutoreleasePool new];
    NSDictionary *source = @{
        @"text": @"legacy property list",
        @"number": @42,
        @"array": @[@"one", @"two"],
    };

    NSString *legacyError = nil;
    NSData *xml = [NSPropertyListSerialization dataFromPropertyList:source
        format:NSPropertyListXMLFormat_v1_0 errorDescription:&legacyError];
    check("legacy-xml-write", [xml length] > 5 && legacyError == nil);
    FormatSlot xmlFormat = formatSlot();
    id xmlResult = [NSPropertyListSerialization propertyListFromData:xml
        mutabilityOption:NSPropertyListImmutable format:&xmlFormat.value
        errorDescription:&legacyError];
    check("legacy-xml-roundtrip", [xmlResult isEqual:source]);
    check("legacy-format-width", intact(xmlFormat) &&
        xmlFormat.value == NSPropertyListXMLFormat_v1_0);

    NSError *modernError = nil;
    NSData *binary = [NSPropertyListSerialization dataWithPropertyList:source
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:&modernError];
    check("modern-binary-write", [binary length] >= 8 &&
        memcmp([binary bytes], "bplist00", 8) == 0 && modernError == nil);
    FormatSlot binaryFormat = formatSlot();
    id binaryResult = [NSPropertyListSerialization propertyListWithData:binary
        options:NSPropertyListImmutable format:&binaryFormat.value
        error:&modernError];
    check("modern-binary-roundtrip", [binaryResult isEqual:source]);
    check("modern-format-width", intact(binaryFormat) &&
        binaryFormat.value == NSPropertyListBinaryFormat_v1_0);

    check("legacy-read-binary-no-outputs",
        [[NSPropertyListSerialization propertyListFromData:binary
            mutabilityOption:NSPropertyListImmutable format:NULL
            errorDescription:NULL] isEqual:source]);
    check("modern-read-xml-no-outputs",
        [[NSPropertyListSerialization propertyListWithData:xml
            options:NSPropertyListImmutable format:NULL error:NULL]
            isEqual:source]);
    check("legacy-write-binary-no-error",
        [[NSPropertyListSerialization dataFromPropertyList:source
            format:NSPropertyListBinaryFormat_v1_0 errorDescription:NULL]
            length] > 0);
    check("modern-write-xml-no-error",
        [[NSPropertyListSerialization dataWithPropertyList:source
            format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL]
            length] > 0);

    NSMutableDictionary *containers =
        [NSPropertyListSerialization propertyListWithData:binary
            options:NSPropertyListMutableContainers format:NULL error:NULL];
    [[containers objectForKey:@"array"] addObject:@"three"];
    check("mutable-containers",
        [[containers objectForKey:@"array"] count] == 3 &&
        [[source objectForKey:@"array"] count] == 2);
    NSMutableDictionary *leaves =
        [NSPropertyListSerialization propertyListFromData:xml
            mutabilityOption:NSPropertyListMutableContainersAndLeaves
            format:NULL errorDescription:NULL];
    [[leaves objectForKey:@"text"] appendString:@"!"];
    check("mutable-leaves", [[leaves objectForKey:@"text"]
        isEqualToString:@"legacy property list!"]);

    /* Unterminated XML is not a valid OpenStep string plist either. */
    NSData *invalid = [@"<?xml version=\"1.0\"?><plist><dict>"
        dataUsingEncoding:NSUTF8StringEncoding];
    FormatSlot invalidFormat = formatSlot();
    modernError = nil;
    id invalidResult = [NSPropertyListSerialization propertyListWithData:invalid
        options:NSPropertyListImmutable format:&invalidFormat.value
        error:&modernError];
    check("modern-read-error", invalidResult == nil &&
        [modernError isKindOfClass:[NSError class]] &&
        [[modernError localizedDescription] length] > 0);
    check("failed-format-unchanged", intact(invalidFormat) &&
        invalidFormat.value == 0x76543210);
    check("modern-read-error-null", ![NSPropertyListSerialization
        propertyListWithData:invalid options:NSPropertyListImmutable
        format:NULL error:NULL]);
    check("legacy-read-error-null", ![NSPropertyListSerialization
        propertyListFromData:invalid mutabilityOption:NSPropertyListImmutable
        format:NULL errorDescription:NULL]);

    /* No extra retain: errorDescription: must keep this string alive after
     * the pool containing the API call has drained. */
    NSAutoreleasePool *errorPool = [NSAutoreleasePool new];
    legacyError = nil;
    invalidResult = [NSPropertyListSerialization propertyListFromData:invalid
        mutabilityOption:NSPropertyListImmutable format:NULL
        errorDescription:&legacyError];
    BOOL legacyFailed = invalidResult == nil && legacyError != nil;
    [errorPool drain];
    check("legacy-read-owned-error", legacyFailed && [legacyError length] > 0);
    [legacyError release];

    NSArray *invalidSource = @[[NSNull null]];
    modernError = nil;
    NSData *invalidData = [NSPropertyListSerialization
        dataWithPropertyList:invalidSource format:NSPropertyListXMLFormat_v1_0
        options:0 error:&modernError];
    check("modern-write-error", invalidData == nil &&
        [modernError isKindOfClass:[NSError class]]);
    check("modern-write-error-null", ![NSPropertyListSerialization
        dataWithPropertyList:invalidSource format:NSPropertyListXMLFormat_v1_0
        options:0 error:NULL]);
    errorPool = [NSAutoreleasePool new];
    legacyError = nil;
    invalidData = [NSPropertyListSerialization dataFromPropertyList:invalidSource
        format:NSPropertyListXMLFormat_v1_0 errorDescription:&legacyError];
    legacyFailed = invalidData == nil && legacyError != nil;
    [errorPool drain];
    check("legacy-write-owned-error", legacyFailed && [legacyError length] > 0);
    [legacyError release];
    check("legacy-write-error-null", ![NSPropertyListSerialization
        dataFromPropertyList:invalidSource format:NSPropertyListXMLFormat_v1_0
        errorDescription:NULL]);

    [pool drain];
    printf("property-list-serialization: %s (%u failures)\n",
        failures ? "FAIL" : "PASS", failures);
    return failures != 0;
}
