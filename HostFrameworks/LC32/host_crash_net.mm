/*
 * Final-net diagnostics for host-side failures.
 *
 * The bridge's dispatch shields convert exceptions raised inside
 * guest-initiated host calls into the guest crash-report channel, and the
 * outer container displays a guest crash exception which unwinds that far.
 * Two host failure classes still terminated without leaving evidence:
 *
 *  - An Objective-C exception no frame catches: raised on a native framework
 *    thread, on a dispatch worker, or anywhere the container's top-level
 *    catch does not apply. A rethrow from an uncaught-exception handler
 *    cannot reach that catch either: the handler runs only after the
 *    unwinder has already finished without finding any handler, so a fresh
 *    throw from the handler would only unwind the terminate machinery
 *    above it. The handler therefore records the report instead.
 *  - A hard host fault (SIGSEGV/SIGBUS) or an abort() in host code. Guest
 *    faults never raise host signals because every guest memory access is
 *    mediated by the JIT's page-table callbacks, so a host signal is by
 *    definition a host failure.
 *
 * This unit nets both: the uncaught-exception handler writes the full
 * report to stderr and preserves a compact version as the process abort
 * reason so the device crash report carries it; the fatal-signal handlers
 * record the native backtrace on stderr and install a compact fault
 * description the same way. Guest crashes keep riding their own flow: the
 * exception handler recognizes them first and forwards their own report
 * rather than wrapping a host diagnosis around a guest crash.
 */

#import "host_crash_net.h"
#include "crash_exception.h"

#include "dynarmic_internal.h"

#include <atomic>
#include <execinfo.h>
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <dispatch/dispatch.h>

#include <mach/mach_init.h>

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

namespace {

constexpr size_t LC32HostCrashBacktraceMax = 64;

/* Host faults share libSystem's OS-reason namespace with guest crashes.
 * Guest crashes ride LC32_GUEST_CRASH_REASON_CODE; reserve the next code
 * for diagnostics originating in host code. */
constexpr uint64_t LC32HostCrashReasonCode = 3;

/* Reentrancy latches shared by the reporting paths. */
volatile sig_atomic_t lc32HostCrashSignalDepth = 0;
/* Set once the uncaught-exception report owns the process abort reason, so
 * the fatal-signal handler never overwrites the richer text. */
volatile sig_atomic_t lc32HostCrashReasonInstalled = 0;
volatile sig_atomic_t lc32UncaughtExceptionHandlerDepth = 0;

NSUncaughtExceptionHandler *lc32PreviousUncaughtExceptionHandler = nullptr;
bool lc32HostCrashNetInstalled = false;

const char *LC32HostFatalSignalName(int signalNumber) {
    switch(signalNumber) {
        case SIGABRT: return "SIGABRT";
        case SIGBUS: return "SIGBUS";
        case SIGSEGV: return "SIGSEGV";
        default: return "unknown";
    }
}

void LC32RestoreDefaultSignalDisposition(int signalNumber) {
    struct sigaction defaultAction;
    memset(&defaultAction, 0, sizeof(defaultAction));
    defaultAction.sa_handler = SIG_DFL;
    sigemptyset(&defaultAction.sa_mask);
    sigaction(signalNumber, &defaultAction, nullptr);
}

/*
 * Async-signal-safe: no Objective-C, no heap allocation, no stdio. A stack
 * buffer plus write() carries the fault description, backtrace_symbols_fd
 * writes the native frames straight to stderr, and abort_with_reason
 * installs the description as the process abort reason before
 * terminating. Guest fault machinery never sees host signals, so this
 * handler only ever observes genuine host failures.
 */
void LC32HostCrashSignalHandler(
        int signalNumber, siginfo_t *info, void *) {
    if(lc32HostCrashSignalDepth != 0) {
        /* A second fault arrived while reporting the first one; the first
         * fault's evidence is already on its way out. Take the default
         * action rather than recurse into damaged state. */
        LC32RestoreDefaultSignalDisposition(signalNumber);
        raise(signalNumber);
        for(;;) pause();
    }
    lc32HostCrashSignalDepth = 1;

    const unsigned long long faultAddress = (unsigned long long)
        (info ? (uintptr_t)info->si_addr : 0);
    const unsigned long long thread = (unsigned long long)
        pthread_mach_thread_np(pthread_self());

    char header[256];
    const int headerLength =
        lc32HostCrashReasonInstalled != 0
        ? snprintf(header, sizeof(header),
              "LiveExec32: terminating after an uncaught exception; "
              "native backtrace on thread %llu follows:\n",
              thread)
        : signalNumber == SIGABRT
        ? snprintf(header, sizeof(header),
              "LiveExec32: abort (SIGABRT) on thread %llu; native "
              "backtrace follows, a deliberate abort reason is "
              "preserved:\n",
              thread)
        : snprintf(header, sizeof(header),
              "LiveExec32: host fault %s (%d) at address 0x%llx "
              "on thread %llu; native backtrace follows:\n",
              LC32HostFatalSignalName(signalNumber), signalNumber,
              faultAddress, thread);
    if(headerLength > 0) {
        write(2, header,
            (size_t)headerLength < sizeof(header) ?
                (size_t)headerLength : sizeof(header) - 1);
    }
    void *frames[LC32HostCrashBacktraceMax];
    const int frameCount = backtrace(frames, LC32HostCrashBacktraceMax);
    if(frameCount > 0) {
        backtrace_symbols_fd(frames, frameCount, STDERR_FILENO);
    }
    if(signalNumber != SIGABRT && lc32HostCrashReasonInstalled == 0) {
        char reason[LC32_OS_REASON_STRING_MAX + 1];
        snprintf(reason, sizeof(reason),
            "LiveExec32 host fault: %s (%d) at address 0x%llx "
            "on thread %llu; native backtrace follows on stderr",
            LC32HostFatalSignalName(signalNumber), signalNumber,
            faultAddress, thread);
        /* abort_with_reason never returns; its abort re-enters this
         * handler once and takes the default disposition above, so the
         * device crash report keeps this reason. */
        abort_with_reason(LC32_OS_REASON_LIBSYSTEM,
            LC32HostCrashReasonCode, reason, 0);
    }
    /* For SIGABRT, never install a reason of our own: a deliberate
     * abort_with_reason already recorded its richer text (the guest crash
     * machinery's fallbacks do this), and an uncaught-exception abort
     * installed its report above. Preserve whichever reason is already
     * pending, take the default action, and let the stderr backtrace carry
     * the rest. */
    LC32RestoreDefaultSignalDisposition(signalNumber);
    raise(signalNumber);
    for(;;) pause();
}

/* Collapse an exception reason onto one line, bounded to the abort-reason
 * payload size, so the device crash report stays compact but identifies
 * the failure. */
void LC32AppendCompactExceptionReason(
        NSMutableString *compact, NSString *reason) {
    NSString *singleLine = [reason
        stringByReplacingOccurrencesOfString:@"\n"
                                  withString:@" | "];
    const NSUInteger remaining = LC32_OS_REASON_STRING_MAX - compact.length;
    if(singleLine.length > remaining) {
        if(remaining >= 3) {
            singleLine = [[singleLine substringToIndex:remaining - 3]
                stringByAppendingString:@"..."];
        } else {
            singleLine = @"";
        }
    }
    [compact appendString:singleLine];
}

/*
 * Runs only for exceptions the unwinder could not deliver anywhere,
 * including the container's top-level catch. Writes the full report to
 * stderr, chains any previously installed handler, then terminates with
 * the compact report installed as the abort reason.
 */
void LC32HostUncaughtExceptionHandler(NSException *exception) {
    if(lc32UncaughtExceptionHandlerDepth != 0) {
        /* Reporting the previous exception raised another one; keep the
         * termination deterministic instead of recursing into the
         * handler. The first report already reached stderr. */
        abort_with_reason(LC32_OS_REASON_LIBSYSTEM,
            LC32HostCrashReasonCode,
            "LiveExec32: exception while reporting an uncaught exception",
            0);
    }
    lc32UncaughtExceptionHandlerDepth = 1;

    /* Never convert a guest crash into a host one: its reason already is
     * the finished guest crash report, so forward that report itself and
     * keep the guest crash reason identity. */
    const bool isGuestCrash = LC32IsGuestCrashException(exception) != 0;
    @autoreleasepool {
        NSMutableString *report = [NSMutableString
            stringWithFormat:
                @"LiveExec32 %@ on thread %llu\n"
                 "Exception: %@\nReason: %@\nCall stack:\n",
                isGuestCrash
                    ? @"guest crash exception reached an uncaught thread"
                    : @"uncaught host exception",
                (unsigned long long)pthread_mach_thread_np(pthread_self()),
                exception.name, exception.reason];
        for(NSString *frame in [exception callStackSymbols]) {
            [report appendFormat:@"  %@\n", frame];
        }
        fputs(report.UTF8String ?: "", stderr);
        fflush(stderr);

        NSMutableString *compact = [NSMutableString
            stringWithFormat:@"LiveExec32 %@: %@: ",
                isGuestCrash
                    ? @"guest crash exception reached an uncaught thread"
                    : @"uncaught host NSException",
                exception.name];
        LC32AppendCompactExceptionReason(compact, exception.reason);

        /* Chain last: a pre-existing handler (the outer container's own
         * reporter, a host crash SDK) may display or collect the exception;
         * if it returns, the abort below still terminates with our reason
         * installed. */
        if(lc32PreviousUncaughtExceptionHandler != nullptr) {
            lc32PreviousUncaughtExceptionHandler(exception);
        }

        lc32HostCrashReasonInstalled = 1;
        abort_with_reason(
            LC32_OS_REASON_LIBSYSTEM,
            isGuestCrash ? LC32_GUEST_CRASH_REASON_CODE :
                LC32HostCrashReasonCode,
            compact.UTF8String ?: "LiveExec32 uncaught exception", 0);
    }
}

void LC32InstallHostCrashNetOnce(void) {
    if(lc32HostCrashNetInstalled) return;
    lc32HostCrashNetInstalled = true;
    LC32InstallHangWatchdog();

    /* Never fight an existing handler chain: keep the previous uncaught
     * handler and forward to it after recording ours, and leave any host
     * fatal signal another component already owns completely alone. */
    lc32PreviousUncaughtExceptionHandler =
        NSGetUncaughtExceptionHandler();
    NSSetUncaughtExceptionHandler(&LC32HostUncaughtExceptionHandler);

    const int fatalSignals[] = {SIGSEGV, SIGBUS, SIGABRT};
    for(size_t index = 0;
            index < sizeof(fatalSignals) / sizeof(fatalSignals[0]);
            index++) {
        struct sigaction existing;
        memset(&existing, 0, sizeof(existing));
        if(sigaction(fatalSignals[index], nullptr, &existing) != 0) {
            continue;
        }
        if(existing.sa_handler != SIG_DFL &&
                existing.sa_handler != SIG_IGN) {
            fprintf(stderr,
                "LC32: preserving existing host %s handler\n",
                LC32HostFatalSignalName(fatalSignals[index]));
            continue;
        }
        struct sigaction action;
        memset(&action, 0, sizeof(action));
        action.sa_sigaction = &LC32HostCrashSignalHandler;
        action.sa_flags = SA_SIGINFO;
        sigemptyset(&action.sa_mask);
        if(sigaction(fatalSignals[index], &action, nullptr) != 0) {
            fprintf(stderr,
                "LC32: could not install host %s handler: %s\n",
                LC32HostFatalSignalName(fatalSignals[index]),
                strerror(errno));
        }
    }
}

/*
 * ------------------------------------------------------------------
 * Host main-queue hang watchdog.
 *
 * The guest main thread runs on the host main thread, so a blocked guest
 * stalls the host main queue: a one-second heartbeat timer scheduled on
 * the main queue only fires while the queue drains.  When the heartbeat
 * goes stale the watchdog takes a cross-thread snapshot of the emulated
 * machine (see LC32GuestHangSnapshot) - which halts the JITs, dumps every
 * guest thread's registers, wait state, and frame chain, and prints the
 * symbolicated report to stderr - and then terminates with the compact
 * description installed as the process abort reason, so a frozen guest
 * leaves the same kind of evidence a crash does.  Backgrounding the app
 * legitimately suspends the main queue, so the watchdog stands down
 * between the background and foreground notifications.
 */

std::atomic<uint64_t> lc32MainQueueHeartbeatNanos{0};
std::atomic<bool> lc32MainQueueEverServiced{false};
std::atomic<bool> lc32AppBackgrounded{false};
dispatch_source_t lc32MainQueueHeartbeatTimer = nil;

uint64_t LC32MonotonicNanos() {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC_RAW, &now);
    return static_cast<uint64_t>(now.tv_sec) * 1000000000ull +
           static_cast<uint64_t>(now.tv_nsec);
}

void *LC32HangWatchdogMain(void *) {
    constexpr uint64_t lc32HangThresholdNanos = 45ull * 1000000000ull;
    struct timespec pollInterval = {5, 0};
    struct timespec reverifyGrace = {3, 0};
    for (;;) {
        nanosleep(&pollInterval, nullptr);
        if (!lc32MainQueueEverServiced.load(std::memory_order_acquire)) {
            continue;
        }
        if (lc32AppBackgrounded.load(std::memory_order_acquire)) {
            continue;
        }
        const uint64_t heartbeat =
            lc32MainQueueHeartbeatNanos.load(std::memory_order_acquire);
        const uint64_t now = LC32MonotonicNanos();
        if (now <= heartbeat ||
                now - heartbeat < lc32HangThresholdNanos) {
            continue;
        }
        /* Re-verify after a short grace so a transient scheduling gap
         * cannot terminate a healthy application. */
        nanosleep(&reverifyGrace, nullptr);
        if (lc32AppBackgrounded.load(std::memory_order_acquire)) {
            continue;
        }
        if (lc32MainQueueHeartbeatNanos.load(
                std::memory_order_acquire) != heartbeat) {
            continue;
        }
        const std::string compact = LC32GuestHangSnapshot();
        /* The snapshot halts the JITs; nothing guest-side can make
         * progress anymore, and the fatal-signal handler must keep this
         * richer abort reason rather than its own generic fault text. */
        lc32HostCrashReasonInstalled = 1;
        abort_with_reason(LC32_OS_REASON_LIBSYSTEM,
            LC32HostCrashReasonCode,
            compact.empty() ? "LiveExec32 guest main thread stalled"
                            : compact.c_str(),
            0);
    }
    return nullptr;
}

void LC32InstallHangWatchdog() {
    lc32MainQueueHeartbeatTimer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (lc32MainQueueHeartbeatTimer != nil) {
        dispatch_source_set_timer(lc32MainQueueHeartbeatTimer,
            dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
            NSEC_PER_SEC, 0);
        dispatch_source_set_event_handler(
            lc32MainQueueHeartbeatTimer, ^{
                lc32MainQueueHeartbeatNanos.store(
                    LC32MonotonicNanos(), std::memory_order_release);
                lc32MainQueueEverServiced.store(
                    true, std::memory_order_release);
            });
        dispatch_resume(lc32MainQueueHeartbeatTimer);
    }

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserverForName:
            UIApplicationDidEnterBackgroundNotification
        object:nil queue:[NSOperationQueue mainQueue]
        usingBlock:^(__unused NSNotification *notification) {
            lc32AppBackgrounded.store(true, std::memory_order_release);
        }];
    [center addObserverForName:
            UIApplicationWillEnterForegroundNotification
        object:nil queue:[NSOperationQueue mainQueue]
        usingBlock:^(__unused NSNotification *notification) {
            lc32AppBackgrounded.store(false, std::memory_order_release);
            lc32MainQueueHeartbeatNanos.store(
                LC32MonotonicNanos(), std::memory_order_release);
        }];

    pthread_t watchdogThread;
    if (pthread_create(&watchdogThread, nullptr,
                LC32HangWatchdogMain, nullptr) == 0) {
        pthread_detach(watchdogThread);
    } else {
        fprintf(stderr,
            "LC32: could not start the main-queue hang watchdog\n");
    }
}

} // namespace

/*
 * App/main.c dlopens LiveExec32Shared strictly before LC32RunGuest starts
 * any guest execution, so the framework's constructor runs this beside the
 * emulator's other process-wide machinery (the objc_getClass hook in
 * bridge.mm and the log redirect in log.m) and the net covers every host
 * frame of the session. pthread_once keeps later explicit installs
 * harmless.
 */
void LC32InstallHostCrashNet(void) {
    static pthread_once_t installOnce = PTHREAD_ONCE_INIT;
    pthread_once(&installOnce, LC32InstallHostCrashNetOnce);
}

__attribute__((constructor)) static void
LC32InstallHostCrashNetAtLoad(void) {
    LC32InstallHostCrashNet();
}
