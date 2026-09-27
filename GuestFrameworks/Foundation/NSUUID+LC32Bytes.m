#import <Foundation/Foundation.h>

#include <string.h>
#include <uuid/uuid.h>

/* The array parameters omitted by the selector generator are guest buffers,
 * not native pointers. UUID's canonical string preserves all 128 bits and
 * lets the byte conversion stay entirely inside the ARM32 address space. */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
#pragma clang diagnostic ignored "-Wobjc-designated-initializers"

@implementation NSUUID (LC32Bytes)

- (instancetype)initWithUUIDBytes:(const unsigned char *)bytes {
    if(!bytes) {
        [self release];
        return nil;
    }
    uuid_string_t text;
    uuid_unparse_upper(bytes, text);
    return [self initWithUUIDString:[NSString stringWithUTF8String:text]];
}

- (void)getUUIDBytes:(unsigned char *)bytes {
    if(!bytes) return;
    uuid_t value = {0};
    const char *text = [[self UUIDString] UTF8String];
    if(text) (void)uuid_parse(text, value);
    memcpy(bytes, value, sizeof(value));
}

@end

#pragma clang diagnostic pop
