#include <mach/mach.h>
#include <mach/mig_errors.h>
#include <mach/ndr.h>

#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

enum {
    POLL_LIMIT = 5000,
    THREAD_SUSPEND_MESSAGE = 3605,
    THREAD_RESUME_MESSAGE = 3606,
};

static unsigned checks;
static unsigned failures;
static int test_finished;

struct worker_state {
    uint32_t counter;
    int stop;
    int done;
    int ready;
    int released;
    int error;
    pthread_mutex_t lock;
    pthread_cond_t condition;
};

static int report(const char *name, int passed) {
    ++checks;
    failures += !passed;
    printf("thread-suspend-%s: %s\n", name, passed ? "PASS" : "FAIL");
    return passed;
}

/* A failed suspend handshake or pthread_join must not leave an unbounded
 * regression process behind. The runner should additionally use its usual
 * process-level timeout in case the guest scheduler itself stops advancing. */
static void *watchdog(void *unused) {
    (void)unused;
    for (unsigned index = 0; index < 200; ++index) {
        if (__atomic_load_n(&test_finished, __ATOMIC_ACQUIRE)) return NULL;
        usleep(100000);
    }
    static const char message[] = "thread-suspend-regression: TIMEOUT\n";
    (void)write(STDERR_FILENO, message, sizeof(message) - 1);
    _exit(2);
}

static int wait_flag(const int *flag) {
    for (unsigned index = 0; index < POLL_LIMIT; ++index) {
        if (__atomic_load_n(flag, __ATOMIC_ACQUIRE)) return 1;
        usleep(1000);
    }
    return 0;
}

static int wait_progress(const struct worker_state *state, uint32_t previous) {
    for (unsigned index = 0; index < POLL_LIMIT; ++index) {
        if (__atomic_load_n(&state->counter, __ATOMIC_RELAXED) != previous)
            return 1;
        usleep(1000);
    }
    return 0;
}

static int counter_stays_still(const struct worker_state *state) {
    const uint32_t before = __atomic_load_n(
        &state->counter, __ATOMIC_RELAXED);
    for (unsigned index = 0; index < 5; ++index) {
        usleep(10000);
        if (__atomic_load_n(&state->counter, __ATOMIC_RELAXED) != before)
            return 0;
    }
    return 1;
}

__attribute__((noinline))
static int spin_step(struct worker_state *state, uint32_t value) {
    /* Load/store atomics need no ARM32 exclusive-instruction loop. Keep the
     * indirect call below, as in native_pthread_smoke: a self-linked JIT block
     * otherwise need not observe HaltExecution until it leaves that block. */
    __atomic_store_n(&state->counter, value, __ATOMIC_RELAXED);
    return __atomic_load_n(&state->stop, __ATOMIC_ACQUIRE);
}

static int (*volatile run_spin_step)(struct worker_state *, uint32_t) =
    spin_step;

static void *spin_worker(void *opaque) {
    struct worker_state *state = opaque;
    uint32_t value = 0;
    while (!run_spin_step(state, ++value)) {}
    __atomic_store_n(&state->done, 1, __ATOMIC_RELEASE);
    return NULL;
}

static int suspend_count(mach_port_t thread, int expected) {
    thread_basic_info_data_t basic = {0};
    mach_msg_type_number_t count = THREAD_BASIC_INFO_COUNT;
    const kern_return_t result = thread_info(thread, THREAD_BASIC_INFO,
        (thread_info_t)&basic, &count);
    if (result != KERN_SUCCESS || count != THREAD_BASIC_INFO_COUNT ||
            basic.suspend_count != expected) {
        printf("  thread_info: result=%d count=%u suspend_count=%d expected=%d\n",
            result, count, basic.suspend_count, expected);
        return 0;
    }
    return 1;
}

static int arm32_state(mach_port_t thread) {
    struct {
        arm_thread_state_t state;
        uint32_t canary;
    } output = {.canary = UINT32_C(0xabcdef12)};
    mach_msg_type_number_t count = ARM_THREAD_STATE_COUNT;
    const kern_return_t result = thread_get_state(thread, ARM_THREAD_STATE,
        (thread_state_t)&output.state, &count);
    return result == KERN_SUCCESS && count == ARM_THREAD_STATE_COUNT &&
        output.state.__pc != 0 && output.state.__sp != 0 &&
        output.canary == UINT32_C(0xabcdef12);
}

enum raw_variant {
    RAW_NORMAL,
    RAW_OVERSIZED,
    RAW_COMPLEX,
    RAW_SHORT_RECEIVE,
};

static int raw_request(mach_port_t target, mach_msg_id_t message_id,
        enum raw_variant variant, kern_return_t expected) {
    union {
        mach_msg_header_t request;
        mig_reply_error_t reply;
        uint8_t bytes[128];
    } message = {0};
    mach_port_t reply_port = MACH_PORT_NULL;
    if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE,
            &reply_port) != KERN_SUCCESS) return 0;
    message.request.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND,
        MACH_MSG_TYPE_MAKE_SEND_ONCE);
    message.request.msgh_remote_port = target;
    message.request.msgh_local_port = reply_port;
    message.request.msgh_id = message_id;
    mach_msg_size_t send_size = sizeof(mach_msg_header_t);
    mach_msg_size_t receive_size = sizeof(message);
    if (variant == RAW_OVERSIZED) send_size += sizeof(uint32_t);
    if (variant == RAW_COMPLEX)
        message.request.msgh_bits |= MACH_MSGH_BITS_COMPLEX;
    if (variant == RAW_SHORT_RECEIVE)
        receive_size = sizeof(mach_msg_header_t);
    message.request.msgh_size = send_size;
    const mach_msg_return_t result = mach_msg(&message.request,
        MACH_SEND_MSG | MACH_RCV_MSG | MACH_RCV_TIMEOUT,
        send_size, receive_size, reply_port, 1000, MACH_PORT_NULL);
    const int passed = variant == RAW_SHORT_RECEIVE
        ? result == MACH_RCV_TOO_LARGE &&
            message.reply.Head.msgh_size == sizeof(mig_reply_error_t)
        : result == MACH_MSG_SUCCESS &&
            message.reply.Head.msgh_id == message_id + 100 &&
            message.reply.Head.msgh_size == sizeof(mig_reply_error_t) &&
            !(message.reply.Head.msgh_bits & MACH_MSGH_BITS_COMPLEX) &&
            memcmp(&message.reply.NDR, &NDR_record, sizeof(NDR_record)) == 0 &&
            message.reply.RetCode == expected;
    if (!passed) {
        printf("  raw %d variant %d: transport=%d id=%d size=%u return=%d\n",
            message_id, variant, result, message.reply.Head.msgh_id,
            message.reply.Head.msgh_size, message.reply.RetCode);
    }
    return mach_port_destroy(mach_task_self(), reply_port) == KERN_SUCCESS &&
        passed;
}

static void test_spin_worker(void) {
    struct worker_state state = {0};
    pthread_t worker;
    if (!report("spin-create", pthread_create(
            &worker, NULL, spin_worker, &state) == 0)) return;
    if (!report("spin-running", wait_progress(&state, 0))) goto cleanup;
    const mach_port_t thread = pthread_mach_thread_np(worker);
    if (!report("spin-thread-port", MACH_PORT_VALID(thread))) goto cleanup;
    report("initial-suspend-count", suspend_count(thread, 0));

    /* Use a real non-thread port: an arbitrary nonexistent port can instead
     * fail the Mach transport with MACH_SEND_INVALID_DEST before MIG runs. */
    report("suspend-nonthread-target",
        thread_suspend(mach_task_self()) == KERN_INVALID_ARGUMENT);
    report("resume-nonthread-target",
        thread_resume(mach_task_self()) == KERN_INVALID_ARGUMENT);
    for (mach_msg_id_t operation = THREAD_SUSPEND_MESSAGE;
            operation <= THREAD_RESUME_MESSAGE; ++operation) {
        report("raw-nonthread-target", raw_request(mach_task_self(),
            operation, RAW_NORMAL, KERN_INVALID_ARGUMENT));
        report("raw-oversized-request", raw_request(thread,
            operation, RAW_OVERSIZED, MIG_BAD_ARGUMENTS));
        report("raw-complex-request", raw_request(thread,
            operation, RAW_COMPLEX, MIG_BAD_ARGUMENTS));
        report("raw-short-receive", raw_request(thread,
            operation, RAW_SHORT_RECEIVE, MACH_RCV_TOO_LARGE));
        report("rejected-request-no-side-effects", suspend_count(thread, 0));
    }

    report("raw-suspend-reply", raw_request(thread,
        THREAD_SUSPEND_MESSAGE, RAW_NORMAL, KERN_SUCCESS));
    report("raw-suspended-count", suspend_count(thread, 1));
    report("raw-resume-reply", raw_request(thread,
        THREAD_RESUME_MESSAGE, RAW_NORMAL, KERN_SUCCESS));
    report("raw-resumed-count", suspend_count(thread, 0));

    report("suspend", thread_suspend(thread) == KERN_SUCCESS);
    report("suspended-count", suspend_count(thread, 1));
    report("suspended-counter", counter_stays_still(&state));
    report("suspended-arm32-state", arm32_state(thread));
    report("nested-suspend", thread_suspend(thread) == KERN_SUCCESS);
    report("nested-suspend-count", suspend_count(thread, 2));
    report("first-resume", thread_resume(thread) == KERN_SUCCESS);
    report("one-suspend-remains", suspend_count(thread, 1));
    report("nested-counter-still-stopped", counter_stays_still(&state));
    report("second-resume", thread_resume(thread) == KERN_SUCCESS);
    report("resumed-count", suspend_count(thread, 0));
    const uint32_t previous = __atomic_load_n(
        &state.counter, __ATOMIC_RELAXED);
    report("resumed-counter-progress", wait_progress(&state, previous));
    report("extra-resume", thread_resume(thread) == KERN_FAILURE);
    report("extra-resume-count", suspend_count(thread, 0));

cleanup:
    __atomic_store_n(&state.stop, 1, __ATOMIC_RELEASE);
    /* Drain at most the suspends issued by this test, even after a failed
     * assertion. Never depend on pthread_cancel reaching a suspended JIT. */
    for (unsigned index = 0; index < 8; ++index) {
        if (thread_resume(pthread_mach_thread_np(worker)) != KERN_SUCCESS)
            break;
    }
    if (!report("spin-cleanup-progress", wait_flag(&state.done))) _exit(1);
    report("spin-join", pthread_join(worker, NULL) == 0);
}

static void *condition_worker(void *opaque) {
    struct worker_state *state = opaque;
    state->error = pthread_mutex_lock(&state->lock);
    if (state->error == 0) {
        __atomic_store_n(&state->ready, 1, __ATOMIC_RELEASE);
        while (!state->released && state->error == 0)
            state->error = pthread_cond_wait(&state->condition, &state->lock);
        const int unlock_error = pthread_mutex_unlock(&state->lock);
        if (state->error == 0) state->error = unlock_error;
    }
    __atomic_store_n(&state->done, 1, __ATOMIC_RELEASE);
    return NULL;
}

static void test_condition_worker(void) {
    struct worker_state state = {
        .lock = PTHREAD_MUTEX_INITIALIZER,
        .condition = PTHREAD_COND_INITIALIZER,
    };
    pthread_t worker;
    if (!report("condition-create", pthread_create(
            &worker, NULL, condition_worker, &state) == 0)) return;
    if (!report("condition-ready", wait_flag(&state.ready))) goto cleanup;
    /* Taking the mutex after ready proves cond_wait has dropped it. Suspend
     * outside the mutex so the worker is allowed to finish that transition. */
    if (!report("condition-wait-entered",
            pthread_mutex_lock(&state.lock) == 0)) goto cleanup;
    report("condition-unlock", pthread_mutex_unlock(&state.lock) == 0);
    const mach_port_t thread = pthread_mach_thread_np(worker);
    report("condition-suspend", thread_suspend(thread) == KERN_SUCCESS);
    report("condition-suspend-count", suspend_count(thread, 1));
    report("condition-suspended-arm32-state", arm32_state(thread));
    if (report("condition-signal-lock", pthread_mutex_lock(&state.lock) == 0)) {
        state.released = 1;
        report("condition-signal", pthread_cond_signal(&state.condition) == 0);
        report("condition-signal-unlock", pthread_mutex_unlock(&state.lock) == 0);
    }
    usleep(50000);
    report("condition-signal-does-not-resume",
        !__atomic_load_n(&state.done, __ATOMIC_ACQUIRE));
    report("condition-resume", thread_resume(thread) == KERN_SUCCESS);
    report("condition-progress-after-resume", wait_flag(&state.done));

cleanup:
    for (unsigned index = 0; index < 8; ++index) {
        if (thread_resume(pthread_mach_thread_np(worker)) != KERN_SUCCESS)
            break;
    }
    if (pthread_mutex_lock(&state.lock) == 0) {
        state.released = 1;
        (void)pthread_cond_broadcast(&state.condition);
        (void)pthread_mutex_unlock(&state.lock);
    }
    if (!report("condition-cleanup-progress", wait_flag(&state.done))) _exit(1);
    report("condition-join", pthread_join(worker, NULL) == 0);
    report("condition-worker-error", state.error == 0);
    report("condition-destroy", pthread_cond_destroy(&state.condition) == 0);
    report("condition-mutex-destroy", pthread_mutex_destroy(&state.lock) == 0);
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    pthread_t timeout_thread;
    if (!report("watchdog-create", pthread_create(
            &timeout_thread, NULL, watchdog, NULL) == 0)) return 1;
    if (!report("watchdog-detach", pthread_detach(timeout_thread) == 0))
        return 1;
    test_spin_worker();
    test_condition_worker();
    __atomic_store_n(&test_finished, 1, __ATOMIC_RELEASE);
    printf("thread-suspend-regression: %s (%u/%u checks)\n",
        failures == 0 ? "PASS" : "FAIL", checks - failures, checks);
    return failures != 0;
}
