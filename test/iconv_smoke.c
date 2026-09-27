#include <errno.h>
#include <iconv.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

static int check(int condition, const char *message) {
    if(!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        return 0;
    }
    return 1;
}

int main(void) {
    static const char inputBytes[] = "A\xe2\x82\xac";
    static const unsigned char expectedBytes[] = {0x41, 0x00, 0xac, 0x20};
    char outputBytes[16] = {0};
    char *input = (char *)inputBytes;
    char *output = outputBytes;
    size_t inputRemaining = sizeof(inputBytes) - 1;
    size_t outputRemaining = sizeof(outputBytes);

    iconv_t converter = iconv_open("UTF-16LE", "UTF-8");
    if(!check(converter != (iconv_t)-1, "iconv_open UTF-8 to UTF-16LE")) {
        return 1;
    }

    size_t result = iconv(converter, &input, &inputRemaining,
                          &output, &outputRemaining);
    int passed = 1;
    passed &= check(result != (size_t)-1, "iconv conversion succeeds");
    passed &= check(inputRemaining == 0, "iconv consumes all input");
    passed &= check((size_t)(output - outputBytes) == sizeof(expectedBytes),
                    "iconv produces the expected byte count");
    passed &= check(memcmp(outputBytes, expectedBytes,
                           sizeof(expectedBytes)) == 0,
                    "iconv produces UTF-16LE output");
    passed &= check(iconv_close(converter) == 0, "iconv_close succeeds");

    errno = 0;
    converter = iconv_open("LC32-NOT-AN-ENCODING", "UTF-8");
    passed &= check(converter == (iconv_t)-1,
                    "iconv_open rejects an unknown encoding");
    passed &= check(errno == EINVAL,
                    "iconv_open reports EINVAL for an unknown encoding");

    converter = iconv_open("UTF-8", "");
    passed &= check(converter != (iconv_t)-1,
                    "iconv_open resolves the guest locale encoding");
    if(converter != (iconv_t)-1) {
        passed &= check(iconv_close(converter) == 0,
                        "locale converter closes successfully");
    }

    if(passed) {
        puts("PASS: guest libiconv UTF-8 conversion");
    }
    return passed ? 0 : 1;
}
