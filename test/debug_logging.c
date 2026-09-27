#include "LC32DebugLog.h"

#include <stdio.h>
#include <string.h>

#ifndef LC32_TEST_EXPECT_ENABLED
#error Define LC32_TEST_EXPECT_ENABLED for this test.
#endif

#if LC32_DEBUG_LOGS != LC32_TEST_EXPECT_ENABLED
#error Unexpected debug logging default or override.
#endif

int main(void) {
    FILE *stream = tmpfile();
    if (stream == NULL) {
        perror("tmpfile");
        return 1;
    }

    int streamCalls = 0;
    int formatCalls = 0;
    int valueCalls = 0;
    int printfCalls = 0;
    int branches = 0;

    if (stream != NULL)
        LC32_DEBUG_FPRINTF((++streamCalls, stream),
            (++formatCalls, "fprintf=%d\n"), ++valueCalls);
    else
        branches = -100;

    if (stream != NULL)
        LC32_DEBUG_PRINTF("debug logging printf argument=%d\n", ++printfCalls);
    else
        branches = -100;

    if (stream == NULL)
        LC32_DEBUG_FPRINTF(stream, "unreachable\n");
    else
        ++branches;

    if (stream == NULL)
        LC32_DEBUG_PRINTF("unreachable\n");
    else
        ++branches;

    const int expected = LC32_TEST_EXPECT_ENABLED;
    if (streamCalls != expected || formatCalls != expected ||
            valueCalls != expected || printfCalls != expected || branches != 2) {
        fprintf(stderr, "FAIL: debug logging argument evaluation or if/else\n");
        fclose(stream);
        return 1;
    }

    rewind(stream);
    char output[32] = {0};
    const size_t length = fread(output, 1, sizeof(output) - 1, stream);
    const char *expectedOutput = expected ? "fprintf=1\n" : "";
    const int failed = ferror(stream) || length != strlen(expectedOutput) ||
        strcmp(output, expectedOutput) != 0;
    fclose(stream);
    if (failed) {
        fprintf(stderr, "FAIL: unexpected debug logging output\n");
        return 1;
    }

    printf("PASS: debug logging %s\n", expected ? "enabled" : "disabled");
    return 0;
}
