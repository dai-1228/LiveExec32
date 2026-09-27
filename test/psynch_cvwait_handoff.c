#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>

/* Use the guest libsystem_kernel veneers so this also checks ARM32's split
 * mugen registers and the flags/timeout arguments beyond the saved registers.
 * These are the same private syscalls used by guest libpthread. */
extern uint32_t __psynch_cvwait(void *condition, uint64_t cvlsgen,
    uint32_t cvugen, void *mutex, uint64_t mugen, uint32_t flags,
    int64_t seconds, uint32_t nanoseconds);
extern uint32_t __psynch_mutexwait(void *mutex, uint32_t mgen,
    uint32_t ugen, uint64_t tid, uint32_t flags);

enum {
    CountIncrement = 0x100,
    CountMask = 0xffffff00u,
    MutexOwnedBits = 3,
    FairShare = 0x40,
    FirstFit = 0x80,
    ProcessPrivate = 0x20,
};

static pthread_cond_t conditions[3];
static pthread_mutex_t mutexes[3];

static int check_handoff(unsigned index, const char *name, uint32_t policy,
        uint32_t dropMgen, uint32_t dropUgen, uint32_t waitMgen) {
    const uint32_t flags = policy | ProcessPrivate;
    const uint64_t cvlsgen = ((uint64_t)1 << 32) | CountIncrement;
    const uint64_t mugen = ((uint64_t)dropUgen << 32) | dropMgen;
    errno = 0;
    uint32_t result = __psynch_cvwait(&conditions[index], cvlsgen, 0,
        &mutexes[index], mugen, flags, 0, 1);
    if(result != UINT32_MAX || (errno & 0xff) != ETIMEDOUT) {
        printf("psynch-cvwait-%s: FAIL (timeout result=%08x errno=%d)\n",
            name, result, errno);
        return 0;
    }

    /* The mutex waiter deliberately enters after cvwait has already dropped
     * the mutex. Its wake must survive in a prepost even though the condition
     * wait itself timed out. An address-only wake loses it and hangs here.
     * Run with a bounded external timeout (for example gtimeout -k 2s 15s). */
    printf("psynch-cvwait-%s: waiting for deferred mutex handoff\n", name);
    result = __psynch_mutexwait(&mutexes[index], waitMgen, 0, 0, flags);
    const uint32_t expected = (waitMgen & CountMask) | MutexOwnedBits;
    const int passed = result == expected;
    printf("psynch-cvwait-%s: %s (result=%08x expected=%08x)\n",
        name, passed ? "PASS" : "FAIL", result, expected);
    return passed;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    int passed = check_handoff(0, "fairshare", FairShare,
        0x503, 0x100, 0x203);
    passed &= check_handoff(1, "fairshare-wrap", FairShare,
        0x103, 0xffffff00u, 0x003);
    /* First-fit is address-wide, not constrained to the drop's generation. */
    passed &= check_handoff(2, "firstfit", FirstFit,
        0x903, 0x500, 0x203);
    printf("psynch-cvwait-handoff: %s\n", passed ? "PASS" : "FAIL");
    return passed ? 0 : 1;
}
