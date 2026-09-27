#include <aio.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define CHECK(condition, message) do { \
    if (!(condition)) { \
        fprintf(stderr, "FAIL: %s (errno=%d)\n", message, errno); \
        return 1; \
    } \
} while (0)

static int ReadAndCheck(int descriptor, struct aiocb *request,
        off_t offset, const char *expected, size_t length) {
    char output[32] = {};
    CHECK(length <= sizeof(output), "test output fits");

    memset(request, 0, sizeof(*request));
    request->aio_fildes = descriptor;
    request->aio_offset = offset;
    request->aio_buf = output;
    request->aio_nbytes = length;
    request->aio_sigevent.sigev_notify = SIGEV_NONE;

    CHECK(aio_read(request) == 0, "aio_read accepts request");
    CHECK(aio_error(request) == 0, "aio_read completes successfully");
    CHECK(aio_return(request) == (ssize_t)length,
          "aio_return reports byte count");
    CHECK(memcmp(output, expected, length) == 0,
          "aio_read honors buffer and offset");
    return 0;
}

int main(void) {
    char path[] = "/private/tmp/lc32-aio-read.XXXXXX";
    const char contents[] = "0123456789abcdefghijklmnopqrstuvwxyz";
    int descriptor = mkstemp(path);
    CHECK(descriptor >= 0, "create temporary file");
    CHECK(unlink(path) == 0, "unlink temporary file");
    CHECK(write(descriptor, contents, sizeof(contents) - 1) ==
              (ssize_t)(sizeof(contents) - 1),
          "write temporary contents");

    struct aiocb request;
    CHECK(ReadAndCheck(descriptor, &request, 10, "abcdefgh", 8) == 0,
          "first asynchronous read");
    CHECK(ReadAndCheck(descriptor, &request, 2, "23456", 5) == 0,
          "reuse control block after aio_return");

    errno = 0;
    CHECK(aio_return(&request) == -1 && errno == EINVAL,
          "aio_return rejects an already consumed request");
    errno = 0;
    CHECK(aio_error(&request) == -1 && errno == EINVAL,
          "aio_error rejects an already consumed request");

    int directoryDescriptor = open("/private/tmp", O_RDONLY);
    CHECK(directoryDescriptor >= 0, "open directory for failed completion");
    char failedOutput = 0;
    memset(&request, 0, sizeof(request));
    request.aio_fildes = directoryDescriptor;
    request.aio_buf = &failedOutput;
    request.aio_nbytes = sizeof(failedOutput);
    request.aio_sigevent.sigev_notify = SIGEV_NONE;
    CHECK(aio_read(&request) == 0,
          "aio_read publishes a failed operation as a completion");
    errno = 0;
    CHECK(aio_error(&request) == EISDIR && errno == 0,
          "aio_error reports the operation error without syscall failure");
    errno = EDOM;
    CHECK(aio_return(&request) == -1 && errno == EDOM,
          "aio_return reports failed result with carry clear");
    CHECK(close(directoryDescriptor) == 0, "close directory descriptor");

    CHECK(close(descriptor) == 0, "close temporary file");
    return 0;
}
