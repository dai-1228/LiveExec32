#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <LC32/LC32.h>

#include <stdint.h>

/* The runtime metadata used for generation omits the path initializers and
 * pointer-taking read/write primitives declared by the public SDK. */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
/* Initializer chaining occurs on the native peer before its result is adopted. */
#pragma clang diagnostic ignored "-Wobjc-designated-initializers"

@implementation NSInputStream (LC32Buffers)

- (instancetype)initWithFileAtPath:(NSString *)path {
    static uint64_t hostSelector __attribute__((aligned(8)));
    const uint64_t selector = LC32CachedHostSelector(
        &hostSelector, _cmd, NO);
    const uint64_t hostResult = LC32InvokeHostSelector(
        self.host_self, selector, path.host_self, (uint64_t)0);
    return LC32AdoptHostInitializerResult(self, hostResult);
}

- (NSInteger)read:(uint8_t *)buffer maxLength:(NSUInteger)length {
    if(length > INT32_MAX) return -1;
    /* The CF bridge stages the native output buffer and copies only the
     * returned bytes into guest memory, preserving EOF and signed errors. */
    return (NSInteger)CFReadStreamRead(
        (CFReadStreamRef)self, buffer, (CFIndex)length);
}

@end

@implementation NSOutputStream (LC32Buffers)

- (instancetype)initToFileAtPath:(NSString *)path append:(BOOL)append {
    static uint64_t hostSelector __attribute__((aligned(8)));
    const uint64_t selector = LC32CachedHostSelector(
        &hostSelector, _cmd, NO);
    const uint64_t hostResult = LC32InvokeHostSelector(
        self.host_self, selector, path.host_self,
        (uint64_t)(unsigned char)append, (uint64_t)0);
    return LC32AdoptHostInitializerResult(self, hostResult);
}

- (NSInteger)write:(const uint8_t *)buffer maxLength:(NSUInteger)length {
    if(length > INT32_MAX) return -1;
    return (NSInteger)CFWriteStreamWrite(
        (CFWriteStreamRef)self, buffer, (CFIndex)length);
}

@end

#pragma clang diagnostic pop
