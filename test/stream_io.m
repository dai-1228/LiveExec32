#import <Foundation/Foundation.h>

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static unsigned failures;
static const uint8_t payload[] = {0, 0xff, 0x41, 0, 0x80, 0x42};

static void check(const char *name, BOOL passed) {
    printf("%s: %s\n", name, passed ? "PASS" : "FAIL");
    failures += !passed;
}

static void checkInput(NSInputStream *input, const char *kind) {
    uint8_t bytes[12];
    memset(bytes, 0xa5, sizeof(bytes));
    [input open];
    const NSInteger first = [input read:bytes maxLength:2];
    const NSInteger rest = [input read:bytes + 2 maxLength:sizeof(bytes) - 2];
    check(kind, first == 2 && rest == (NSInteger)sizeof(payload) - 2 &&
        memcmp(bytes, payload, sizeof(payload)) == 0 &&
        bytes[sizeof(payload)] == 0xa5 && bytes[sizeof(bytes) - 1] == 0xa5);
    check("read-eof", [input read:bytes + sizeof(payload) maxLength:1] == 0 &&
        bytes[sizeof(payload)] == 0xa5);
    [input close];
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    NSAutoreleasePool *pool = [NSAutoreleasePool new];
    NSData *data = [NSData dataWithBytes:payload length:sizeof(payload)];
    checkInput([NSInputStream inputStreamWithData:data], "read-data-binary-partial");

    /* Use the native temporary directory shared by guest file syscalls and
     * Foundation; the guest ramdisk's /tmp symlink is not resolved yet. */
    NSString *pathTemplate = [NSTemporaryDirectory()
        stringByAppendingPathComponent:@"lc32-stream-io-XXXXXX"];
    const char *templateBytes = [pathTemplate UTF8String];
    char *path = templateBytes ? strdup(templateBytes) : NULL;
    int descriptor = -1;
    if(path) {
        descriptor = mkstemp(path);
    } else {
        errno = templateBytes ? ENOMEM : EINVAL;
    }
    if(descriptor < 0) perror("stream-io mkstemp");
    check("create-fixture", descriptor >= 0);
    if(descriptor >= 0) {
        check("write-fixture", write(descriptor, payload, sizeof(payload)) == sizeof(payload));
        close(descriptor);
        NSString *filePath = [NSString stringWithUTF8String:path];
        NSInputStream *input = [[NSInputStream alloc]
            initWithFileAtPath:filePath];
        checkInput(input, "read-file-binary-partial");
        [input release];

        NSOutputStream *file = [[NSOutputStream alloc]
            initToFileAtPath:filePath append:NO];
        [file open];
        check("write-file-binary", [file write:payload maxLength:sizeof(payload)] == sizeof(payload));
        [file close];
        [file release];
        check("write-file-exact-data", [[NSData dataWithContentsOfFile:filePath] isEqualToData:data]);
        file = [[NSOutputStream alloc] initToFileAtPath:filePath append:YES];
        [file open];
        check("write-file-append", [file write:payload maxLength:sizeof(payload)] == sizeof(payload));
        [file close];
        [file release];
        NSMutableData *twice = [NSMutableData dataWithData:data];
        [twice appendData:data];
        check("write-file-append-exact-data",
            [[NSData dataWithContentsOfFile:filePath] isEqualToData:twice]);
        unlink(path);

        NSInputStream *missing = [NSInputStream inputStreamWithFileAtPath:filePath];
        uint8_t untouched = 0xa5;
        [missing open];
        check("read-file-error-signed", [missing read:&untouched maxLength:1] == -1 && untouched == 0xa5);
        check("read-file-error-object", [missing streamStatus] == NSStreamStatusError && [missing streamError] != nil);
        [missing close];
    }
    free(path);

    NSOutputStream *output = [NSOutputStream outputStreamToMemory];
    [output open];
    check("write-memory-first-part", [output write:payload maxLength:2] == 2);
    check("write-memory-second-part", [output write:payload + 2 maxLength:sizeof(payload) - 2] == sizeof(payload) - 2);
    check("write-memory-exact-data", [[output propertyForKey:NSStreamDataWrittenToMemoryStreamKey] isEqualToData:data]);
    [output close];
    check("write-closed-error-signed", [output write:payload maxLength:1] == -1);

#ifdef LC32_TEST_STREAM_BOUNDS
    NSInputStream *boundedInput = [NSInputStream inputStreamWithData:data];
    NSOutputStream *boundedOutput = [NSOutputStream outputStreamToMemory];
    uint8_t byte = 0xa5;
    [boundedInput open];
    [boundedOutput open];
    check("read-null-buffer-rejected", [boundedInput read:NULL maxLength:1] == -1);
    check("write-null-buffer-rejected", [boundedOutput write:NULL maxLength:1] == -1);
    check("read-unsigned-length-rejected", [boundedInput read:&byte maxLength:(NSUInteger)UINT32_MAX] == -1 && byte == 0xa5);
    check("write-unsigned-length-rejected", [boundedOutput write:payload maxLength:(NSUInteger)UINT32_MAX] == -1);
    check("read-transfer-limit-rejected", [boundedInput read:&byte maxLength:64u * 1024u * 1024u + 1u] == -1 && byte == 0xa5);
    check("write-transfer-limit-rejected", [boundedOutput write:payload maxLength:64u * 1024u * 1024u + 1u] == -1);
    check("rejected-read-does-not-consume", [boundedInput read:&byte maxLength:1] == 1 && byte == payload[0]);
    check("rejected-write-does-not-append", [[boundedOutput propertyForKey:NSStreamDataWrittenToMemoryStreamKey] length] == 0);
    [boundedInput close];
    [boundedOutput close];
#endif

    [pool drain];
    return failures ? 1 : 0;
}
