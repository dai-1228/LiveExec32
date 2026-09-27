#include <mach/mach.h>
#include <mach/mig_errors.h>
#include <mach/ndr.h>
#include <mach/thread_policy.h>
#include <mach/task_policy.h>
#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static int failures;
static void report(const char *name, int passed) {
    printf("thread-policy-%s: %s\n", name, passed ? "PASS" : "FAIL");
    failures += !passed;
}

static kern_return_t get_precedence(mach_port_t thread, integer_t *importance,
        boolean_t *getDefault) {
    mach_msg_type_number_t count = THREAD_PRECEDENCE_POLICY_COUNT;
    return thread_policy_get(thread, THREAD_PRECEDENCE_POLICY,
        importance, &count, getDefault);
}

static void *worker(void *unused) {
    (void)unused;
    mach_port_t thread = mach_thread_self();
    integer_t importance = -7;
    kern_return_t kr = thread_policy_set(thread, THREAD_PRECEDENCE_POLICY,
        &importance, THREAD_PRECEDENCE_POLICY_COUNT);
    importance = 0;
    boolean_t getDefault = FALSE;
    int passed = kr == KERN_SUCCESS &&
        get_precedence(thread, &importance, &getDefault) == KERN_SUCCESS &&
        importance == -7 && !getDefault;
    mach_port_deallocate(mach_task_self(), thread);
    return (void *)(uintptr_t)passed;
}

struct __attribute__((packed, aligned(4))) policy_request32 {
    mach_msg_header_t header;
    NDR_record_t ndr;
    uint32_t flavor;
    uint32_t count;
    integer_t policy[16];
};
_Static_assert(offsetof(struct policy_request32, policy) == 40,
    "unexpected ARM32 policy payload offset");

/* Raw messages exercise validation and the variable reply's boolean tail,
 * which the public MIG stub would otherwise hide. */
static void raw_tests(mach_port_t thread) {
    for(unsigned variant = 0; variant < 10; ++variant) {
        union {
            struct policy_request32 request;
            mig_reply_error_t reply;
            unsigned char bytes[160];
        } message = {0};
        mach_port_t replyPort = mig_get_reply_port();
        message.request.header.msgh_bits = MACH_MSGH_BITS(
            MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE);
        message.request.header.msgh_remote_port = thread;
        message.request.header.msgh_local_port = replyPort;
        message.request.header.msgh_id = 3617;
        message.request.ndr = NDR_record;
        message.request.flavor = THREAD_PRECEDENCE_POLICY;
        message.request.count = 1;
        message.request.policy[0] = 9;
        mach_msg_size_t sendSize = 44, receiveSize = sizeof(message);
        kern_return_t expected = KERN_SUCCESS;
        switch(variant) {
            case 1: sendSize = 39; expected = MIG_BAD_ARGUMENTS; break;
            case 2: sendSize = 40; expected = MIG_BAD_ARGUMENTS; break;
            case 3:
                message.request.header.msgh_bits |= MACH_MSGH_BITS_COMPLEX;
                expected = MIG_BAD_ARGUMENTS; break;
            case 4:
                message.request.count = 17;
                expected = MIG_ARRAY_TOO_LARGE; break;
            case 5:
                message.request.ndr.int_rep ^= 1;
                expected = MIG_BAD_ARGUMENTS; break;
            case 6: receiveSize = sizeof(mach_msg_header_t); break;
            case 9: break; /* The trap's send_size overrides the user header. */
            case 7:
            case 8:
                message.request.header.msgh_id = 3618;
                message.request.policy[0] = FALSE; /* get_default */
                if(variant == 8) receiveSize = sizeof(mig_reply_error_t);
                break;
        }
        message.request.header.msgh_size = sendSize;
        if(variant == 9) message.request.header.msgh_size = sendSize - 4;
        if((variant >= 1 && variant <= 6) || variant == 9)
            message.request.policy[0] = 123;
        mach_msg_return_t result = mach_msg(&message.request.header,
            MACH_SEND_MSG | MACH_RCV_MSG, sendSize, receiveSize, replyPort,
            MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
        int passed;
        if(variant == 6 || variant == 8) {
            passed = result == MACH_RCV_TOO_LARGE &&
                message.reply.Head.msgh_size == (variant == 6 ? 36 : 48);
        } else {
            passed = result == MACH_MSG_SUCCESS &&
                message.reply.Head.msgh_id == (variant == 7 ? 3718 : 3717) &&
                !(message.reply.Head.msgh_bits & MACH_MSGH_BITS_COMPLEX) &&
                message.reply.RetCode == expected &&
                memcmp(&message.reply.NDR, &NDR_record, sizeof(NDR_record)) == 0;
            if(variant == 7) {
                uint32_t count, value, getDefault;
                memcpy(&count, message.bytes + 36, 4);
                memcpy(&value, message.bytes + 40, 4);
                memcpy(&getDefault, message.bytes + 44, 4);
                passed &= message.reply.Head.msgh_size == 48 &&
                    count == 1 && value == 9 && !getDefault;
            } else {
                passed &= message.reply.Head.msgh_size == 36;
            }
        }
        static const char *names[] = {"raw-set", "short-prefix",
            "truncated-array", "complex-request", "oversized-count",
            "unsupported-ndr", "short-set-receive", "raw-get-tail",
            "short-get-receive", "trap-size-overrides-header"};
        if((variant >= 1 && variant <= 6) || variant == 9) {
            integer_t importance = 0;
            boolean_t getDefault = FALSE;
            passed &= get_precedence(thread, &importance, &getDefault) ==
                KERN_SUCCESS && importance == (variant == 9 ? 123 : 9);
        }
        report(names[variant], passed);
    }
}

static void other_policies(mach_port_t thread) {
    static const struct {
        const char *name;
        thread_policy_flavor_t flavor;
        integer_t value;
    } cases[] = {
        {"affinity-roundtrip-default", THREAD_AFFINITY_POLICY, -31337},
        {"latency-roundtrip-default", THREAD_LATENCY_QOS_POLICY, LATENCY_QOS_TIER_2},
        {"throughput-roundtrip-default", THREAD_THROUGHPUT_QOS_POLICY,
            THROUGHPUT_QOS_TIER_4},
    };
    for(unsigned index = 0; index < sizeof(cases) / sizeof(cases[0]); ++index) {
        integer_t value = cases[index].value;
        int passed = thread_policy_set(thread, cases[index].flavor, &value, 1) ==
            KERN_SUCCESS;
        mach_msg_type_number_t count = 1;
        boolean_t getDefault = FALSE;
        value = 0;
        passed &= thread_policy_get(thread, cases[index].flavor, &value,
            &count, &getDefault) == KERN_SUCCESS && value == cases[index].value &&
            count == 1 && !getDefault;
        getDefault = TRUE;
        passed &= thread_policy_get(thread, cases[index].flavor, &value,
            &count, &getDefault) == KERN_SUCCESS && value == 0 && getDefault;
        getDefault = FALSE;
        passed &= thread_policy_get(thread, cases[index].flavor, &value,
            &count, &getDefault) == KERN_SUCCESS && value == cases[index].value;
        report(cases[index].name, passed);
    }
    integer_t value = 1; /* Not the SDK's encoded QoS tier. */
    report("invalid-qos-tier", thread_policy_set(thread, THREAD_LATENCY_QOS_POLICY,
        &value, 1) == KERN_INVALID_ARGUMENT);
    mach_msg_type_number_t count = 1;
    boolean_t getDefault = FALSE;
    report("invalid-qos-preserves-current", thread_policy_get(thread,
        THREAD_LATENCY_QOS_POLICY, &value, &count, &getDefault) == KERN_SUCCESS &&
        value == LATENCY_QOS_TIER_2);
    value = THREAD_BACKGROUND_POLICY_DARWIN_BG;
    report("background-set", thread_policy_set(thread, THREAD_BACKGROUND_POLICY,
        &value, 1) == KERN_SUCCESS);
    value = 42;
    report("background-get-unsupported", thread_policy_get(thread,
        THREAD_BACKGROUND_POLICY, &value, &count, &getDefault) == KERN_INVALID_ARGUMENT &&
        value == 42);
    value = 0;
    report("background-clear", thread_policy_set(thread, THREAD_BACKGROUND_POLICY,
        &value, 1) == KERN_SUCCESS);
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    mach_port_t thread = mach_thread_self();
    thread_extended_policy_data_t extended = {FALSE};
    boolean_t getDefault = TRUE;
    mach_msg_type_number_t count = THREAD_EXTENDED_POLICY_COUNT;
    report("default-extended", thread_policy_get(thread,
        THREAD_EXTENDED_POLICY, (thread_policy_t)&extended, &count,
        &getDefault) == KERN_SUCCESS && count == 1 &&
        extended.timeshare && getDefault);
    extended.timeshare = FALSE;
    report("set-extended", thread_policy_set(thread, THREAD_EXTENDED_POLICY,
        (thread_policy_t)&extended, 1) == KERN_SUCCESS);
    extended.timeshare = TRUE;
    getDefault = FALSE;
    count = 1;
    report("get-extended", thread_policy_get(thread, THREAD_EXTENDED_POLICY,
        (thread_policy_t)&extended, &count, &getDefault) == KERN_SUCCESS &&
        !extended.timeshare && !getDefault);
    report("standard-reset", thread_policy_set(thread, THREAD_STANDARD_POLICY,
        NULL, THREAD_STANDARD_POLICY_COUNT) == KERN_SUCCESS);
    getDefault = FALSE;
    count = 1;
    report("standard-is-timeshare", thread_policy_get(thread,
        THREAD_EXTENDED_POLICY, (thread_policy_t)&extended, &count,
        &getDefault) == KERN_SUCCESS && extended.timeshare);

    integer_t importance = 17;
    report("set-precedence", thread_policy_set(thread, THREAD_PRECEDENCE_POLICY,
        &importance, 1) == KERN_SUCCESS);
    importance = 0;
    getDefault = FALSE;
    report("get-precedence", get_precedence(thread, &importance, &getDefault) ==
        KERN_SUCCESS && importance == 17 && !getDefault);
    getDefault = TRUE;
    report("default-does-not-mutate", get_precedence(thread, &importance,
        &getDefault) == KERN_SUCCESS && importance == 0 && getDefault);
    getDefault = FALSE;
    report("current-after-default", get_precedence(thread, &importance,
        &getDefault) == KERN_SUCCESS && importance == 17 && !getDefault);

    pthread_t other;
    void *workerResult = NULL;
    int created = pthread_create(&other, NULL, worker, NULL);
    report("worker-policy", created == 0 && pthread_join(other, &workerResult) == 0 &&
        workerResult == (void *)1);
    getDefault = FALSE;
    report("thread-policy-isolation", get_precedence(thread, &importance,
        &getDefault) == KERN_SUCCESS && importance == 17);

    thread_time_constraint_policy_data_t realtime = {
        .period = 1000000, .computation = 100000, .constraint = 500000,
        .preemptible = TRUE,
    };
    report("set-time-constraint", thread_policy_set(thread,
        THREAD_TIME_CONSTRAINT_POLICY, (thread_policy_t)&realtime,
        THREAD_TIME_CONSTRAINT_POLICY_COUNT) == KERN_SUCCESS);
    thread_time_constraint_policy_data_t actual = {0};
    count = THREAD_TIME_CONSTRAINT_POLICY_COUNT;
    getDefault = FALSE;
    report("get-time-constraint", thread_policy_get(thread,
        THREAD_TIME_CONSTRAINT_POLICY, (thread_policy_t)&actual, &count,
        &getDefault) == KERN_SUCCESS && !getDefault &&
        memcmp(&actual, &realtime, sizeof(actual)) == 0);
    realtime.constraint = realtime.computation - 1;
    report("invalid-time-constraint", thread_policy_set(thread,
        THREAD_TIME_CONSTRAINT_POLICY, (thread_policy_t)&realtime,
        THREAD_TIME_CONSTRAINT_POLICY_COUNT) == KERN_INVALID_ARGUMENT);
    extended.timeshare = FALSE;
    count = 1;
    getDefault = FALSE;
    report("realtime-supersedes-extended", thread_policy_get(thread,
        THREAD_EXTENDED_POLICY, (thread_policy_t)&extended, &count,
        &getDefault) == KERN_SUCCESS && getDefault && extended.timeshare);
    report("reset-realtime", thread_policy_set(thread, THREAD_STANDARD_POLICY,
        NULL, 0) == KERN_SUCCESS);
    count = THREAD_TIME_CONSTRAINT_POLICY_COUNT;
    getDefault = FALSE;
    report("inactive-realtime-default", thread_policy_get(thread,
        THREAD_TIME_CONSTRAINT_POLICY, (thread_policy_t)&actual, &count,
        &getDefault) == KERN_SUCCESS && getDefault &&
        count == THREAD_TIME_CONSTRAINT_POLICY_COUNT);
    count = 0;
    getDefault = FALSE;
    report("standard-zero-word-query", thread_policy_get(thread,
        THREAD_STANDARD_POLICY, NULL, &count, &getDefault) == KERN_SUCCESS && count == 0);
    other_policies(thread);
    importance = 42;
    report("unknown-flavor", thread_policy_set(thread, 0xffffffff,
        &importance, 1) == KERN_INVALID_ARGUMENT);
    count = 0;
    getDefault = FALSE;
    report("insufficient-output", thread_policy_get(thread, THREAD_PRECEDENCE_POLICY,
        &importance, &count, &getDefault) == KERN_INVALID_ARGUMENT &&
        importance == 42 && count == 0);
    mach_port_t ordinaryPort = MACH_PORT_NULL;
    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &ordinaryPort);
    mach_port_insert_right(mach_task_self(), ordinaryPort, ordinaryPort,
        MACH_MSG_TYPE_MAKE_SEND);
    report("nonthread-destination", thread_policy_set(ordinaryPort,
        THREAD_PRECEDENCE_POLICY, &importance, 1) == KERN_INVALID_ARGUMENT);
    mach_port_destroy(mach_task_self(), ordinaryPort);
    raw_tests(thread);
    mach_port_deallocate(mach_task_self(), thread);
    printf("thread-policy-regression: %s\n", failures ? "FAIL" : "PASS");
    return failures != 0;
}
