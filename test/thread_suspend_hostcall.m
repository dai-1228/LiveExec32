#import <Foundation/Foundation.h>

#include <mach/mach.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <unistd.h>

static unsigned checks;
static unsigned failures;
static int test_finished;

struct worker_state {
    NSCondition *condition;
    int ready;
    int released;
    int completed;
    int done;
};

static int report(const char *name, int passed) {
    ++checks;
    failures += !passed;
    printf("thread-suspend-hostcall-%s: %s\n",
        name, passed ? "PASS" : "FAIL");
    return passed;
}

static void *watchdog(void *unused) {
    (void)unused;
    for (unsigned index = 0; index < 300; ++index) {
        if (__atomic_load_n(&test_finished, __ATOMIC_ACQUIRE)) return NULL;
        usleep(100000);
    }
    static const char message[] =
        "thread-suspend-hostcall-regression: TIMEOUT\n";
    (void)write(STDERR_FILENO, message, sizeof(message) - 1);
    _exit(2);
}

static int wait_flag(const int *flag) {
    for (unsigned index = 0; index < 5000; ++index) {
        if (__atomic_load_n(flag, __ATOMIC_ACQUIRE)) return 1;
        usleep(1000);
    }
    return 0;
}

static void *condition_worker(void *opaque) {
    struct worker_state *state = opaque;
    @autoreleasepool {
        [state->condition lock];
        __atomic_store_n(&state->ready, 1, __ATOMIC_RELEASE);
        while (!state->released) {
            /* The generated NSCondition shim calls the native selector.
             * Unlike pthread_cond_wait, this parks inside the host bridge,
             * not the emulated psynch condition-wait implementation. */
            [state->condition wait];
        }
        /* Publish before another selector call: this detects guest reentry
         * as soon as the native -wait returns, even if -unlock later blocks. */
        __atomic_store_n(&state->completed, 1, __ATOMIC_RELEASE);
        [state->condition unlock];
    }
    __atomic_store_n(&state->done, 1, __ATOMIC_RELEASE);
    return NULL;
}

static int suspended_info(mach_port_t thread, int expected) {
    thread_basic_info_data_t info = {0};
    mach_msg_type_number_t count = THREAD_BASIC_INFO_COUNT;
    const kern_return_t result = thread_info(thread, THREAD_BASIC_INFO,
        (thread_info_t)&info, &count);
    return result == KERN_SUCCESS && count == THREAD_BASIC_INFO_COUNT &&
        info.suspend_count == expected;
}

static int arm32_state(mach_port_t thread) {
    struct {
        arm_thread_state_t state;
        uint32_t canary;
    } output = {.canary = UINT32_C(0x1234abcd)};
    mach_msg_type_number_t count = ARM_THREAD_STATE_COUNT;
    const kern_return_t result = thread_get_state(thread, ARM_THREAD_STATE,
        (thread_state_t)&output.state, &count);
    return result == KERN_SUCCESS && count == ARM_THREAD_STATE_COUNT &&
        output.state.__pc != 0 && output.state.__sp != 0 &&
        output.canary == UINT32_C(0x1234abcd);
}

static void run_test(void) {
    struct worker_state state = {
        .condition = [[NSCondition alloc] init],
    };
    if (!report("condition-create", state.condition != nil)) return;

    pthread_t worker;
    if (!report("worker-create", pthread_create(
            &worker, NULL, condition_worker, &state) == 0)) {
        [state.condition release];
        return;
    }
    const mach_port_t thread = pthread_mach_thread_np(worker);
    int suspended = 0;
    if (!report("worker-ready", wait_flag(&state.ready))) goto cleanup;
    if (!report("worker-port", MACH_PORT_VALID(thread))) goto cleanup;

    /* ready was stored while holding the condition. Acquiring it here proves
     * the worker has entered native -wait and released that native mutex. */
    [state.condition lock];
    report("native-wait-entered",
        !__atomic_load_n(&state.completed, __ATOMIC_ACQUIRE));
    [state.condition unlock];

    suspended = thread_suspend(thread) == KERN_SUCCESS;
    report("suspend-blocked-native-call", suspended);
    report("suspend-count", suspended_info(thread, 1));
    [state.condition lock];
    state.released = 1;
    [state.condition signal];
    [state.condition unlock];

    int stayed_suspended = 1;
    for (unsigned index = 0; index < 5; ++index) {
        usleep(10000);
        if (__atomic_load_n(&state.completed, __ATOMIC_ACQUIRE))
            stayed_suspended = 0;
    }
    report("native-return-cannot-reenter-guest", stayed_suspended);
    report("signaled-suspend-count", suspended_info(thread, 1));
    report("signaled-arm32-state", arm32_state(thread));

    const kern_return_t resumed = thread_resume(thread);
    report("resume", resumed == KERN_SUCCESS);
    if (resumed == KERN_SUCCESS) suspended = 0;
    report("guest-completion-after-resume", wait_flag(&state.completed));

cleanup:
    /* Resume before locking: native -wait may already have reacquired the
     * condition while its return to guest code is held at the suspend gate. */
    if (suspended) {
        report("cleanup-resume", thread_resume(thread) == KERN_SUCCESS);
    }
    [state.condition lock];
    state.released = 1;
    [state.condition broadcast];
    [state.condition unlock];
    if (!report("worker-cleanup-progress", wait_flag(&state.done))) _exit(1);
    report("worker-join", pthread_join(worker, NULL) == 0);
    [state.condition release];
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    pthread_t timeout_thread;
    if (!report("watchdog-create", pthread_create(
            &timeout_thread, NULL, watchdog, NULL) == 0)) return 1;
    if (!report("watchdog-detach", pthread_detach(timeout_thread) == 0))
        return 1;
    @autoreleasepool {
        run_test();
    }
    __atomic_store_n(&test_finished, 1, __ATOMIC_RELEASE);
    printf("thread-suspend-hostcall-regression: %s (%u/%u checks)\n",
        failures == 0 ? "PASS" : "FAIL", checks - failures, checks);
    return failures != 0;
}
