#import <Foundation/Foundation.h>

#include <stdint.h>
#include <stdio.h>
#include <string.h>

static unsigned checks;
static unsigned failures;

static void check(const char *name, BOOL passed) {
    ++checks;
    failures += !passed;
    printf("nsuuid-bytes-%s: %s\n", name, passed ? "PASS" : "FAIL");
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    @autoreleasepool {
        const unsigned char expected[16] = {
            0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
            0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
        };
        NSUUID *uuid = [[NSUUID alloc] initWithUUIDBytes:expected];
        check("initializer", uuid != nil);
        check("canonical-string", [[uuid UUIDString] isEqualToString:
            @"00112233-4455-6677-8899-AABBCCDDEEFF"]);
        /* Deliberately unaligned, with canaries on both sides: native code
         * must never receive this ARM32 destination as a host address. */
        unsigned char output[18];
        memset(output, 0x5a, sizeof(output));
        [uuid getUUIDBytes:output + 1];
        check("roundtrip", memcmp(output + 1, expected, 16) == 0);
        check("canaries", output[0] == 0x5a && output[17] == 0x5a);
        [uuid release];

        uuid = [[NSUUID alloc] initWithUUIDString:
            @"ffffffff-ffff-ffff-ffff-ffffffffffff"];
        [uuid getUUIDBytes:output + 1];
        BOOL allOnes = YES;
        for(unsigned index = 1; index <= 16; ++index)
            allOnes &= output[index] == 0xff;
        check("string-initialized", allOnes);
        [uuid release];

        const unsigned char zero[16] = {0};
        uuid = [[NSUUID alloc] initWithUUIDBytes:zero];
        [uuid getUUIDBytes:output + 1];
        check("zero-roundtrip", memcmp(output + 1, zero, 16) == 0);
        [uuid release];
    }
    printf("nsuuid-bytes-regression: %s (%u/%u)\n",
        failures ? "FAIL" : "PASS", checks - failures, checks);
    return failures != 0;
}
