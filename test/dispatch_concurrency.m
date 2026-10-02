#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>

#include <dispatch/dispatch.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <unistd.h>

/* Native-mode GCD topology fixture (gap G08-06, agent 16):
 *  (1) 13 dispatch_once sites raced from 3 native guest threads,
 *      each once-block containing an inner __block + dispatch_sync so
 *      copy/dispose and byref forwarding run under contention;
 *  (2) the CCTextureCache shape: a serial dictQueue dispatch_sync'd
 *      from a native worker while the main thread also syncs it;
 *  (3) the Chartboost shape: 5 dispatch_group_async blocks on global
 *      HIGH against the 4-worker cap, plus a FOREVER group_wait on
 *      another global worker;
 *  (4) a 100ms main-queue dispatch_after whose stack block outlives
 *      both its originating frame and its originating worker thread —
 *      libdispatch must have copied it on enqueue.
 * All callback state is static or heap-shared under stateLock, so a
 * timeout cannot leave a callback pointing into an expired frame. */
#define ONCE_SITES 13
#define GROUP_ITEMS 5

static dispatch_once_t oncePredicates[ONCE_SITES];
static int onceCounts[ONCE_SITES];
static pthread_mutex_t stateLock = PTHREAD_MUTEX_INITIALIZER;
static pthread_t mainThread;
static unsigned oncePerThread[3];
static int onceInnerBlocks;
static unsigned innerB, mainSyncDone, workerSyncDone, loaderB;
static unsigned groupDone, sharedCounter, groupWaitReturned;
static unsigned mainAfter, workerAfter;
static double mainAfterTime, workerAfterTime;
static BOOL mainAfterNotEarly, workerAfterNotEarly;
static BOOL mainAfterOnMain, workerAfterOnMain;
static double mainAfterDeadline, workerAfterDeadline;
static int checks, failures;

static void check(const char *name, BOOL passed) {
    printf("%s: %s\n", name, passed ? "PASS" : "FAIL");
    ++checks;
    failures += !passed;
}

static void watchdog(int sig) {
    (void)sig;
    const char message[] = "dispatch-concurrency-watchdog: FAIL\n";
    (void)write(STDERR_FILENO, message, sizeof(message) - 1);
    _exit(2);
}

static void keepalive(void *context) {
    (void)context;
}

static void pumpOnce(void) {
    @autoreleasepool {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.005, false);
    }
}

typedef BOOL (^DonePredicate)(void);

static BOOL pumpUntil(DonePredicate done, double seconds) {
    double deadline = CFAbsoluteTimeGetCurrent() + seconds;
    while(!done() && CFAbsoluteTimeGetCurrent() < deadline) pumpOnce();
    return done();
}

static BOOL onMain(void) {
    return pthread_equal(pthread_self(), mainThread) && [NSThread isMainThread];
}

/* --- Leg 1: 13 once sites, 3 native threads ------------- */

static void *onceRacer(void *arg) {
    unsigned slot = (unsigned)(uintptr_t)arg;
    @autoreleasepool {
        for(int site = 0; site < ONCE_SITES; ++site) {
            dispatch_once(&oncePredicates[site], ^{
                /* __block + inner sync: exercises byref forwarding and
                 * block copy/dispose inside the once machinery itself. */
                __block int inner = 0;
                dispatch_sync(dispatch_get_global_queue(
                    DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    ++inner;
                });
                pthread_mutex_lock(&stateLock);
                ++onceCounts[site];
                onceInnerBlocks += inner == 1;
                pthread_mutex_unlock(&stateLock);
            });
        }
        pthread_mutex_lock(&stateLock);
        ++oncePerThread[slot];
        pthread_mutex_unlock(&stateLock);
    }
    return NULL;
}

/* --- Leg 2: texture-cache serial sync shape -------------- */

static void *queueRacer(void *queue) {
    @autoreleasepool {
        /* Worker side: dispatch_sync onto dictQueue from a native guest
         * pthread (the loadingQueue-worker-to-dictQueue direction). */
        dispatch_sync((dispatch_queue_t)queue, ^{
            pthread_mutex_lock(&stateLock);
            ++innerB;
            pthread_mutex_unlock(&stateLock);
        });
        pthread_mutex_lock(&stateLock);
        ++workerSyncDone;
        pthread_mutex_unlock(&stateLock);
    }
    return NULL;
}

static void *loaderWorker(void *queue) {
    @autoreleasepool {
        dispatch_async((dispatch_queue_t)queue, ^{
            pthread_mutex_lock(&stateLock);
            ++loaderB;
            pthread_mutex_unlock(&stateLock);
        });
    }
    return NULL;
}

/* --- Leg 3: group waiter -------------------------------- */

static void *groupWaiter(void *group) {
    @autoreleasepool {
        dispatch_group_wait((dispatch_group_t)group, DISPATCH_TIME_FOREVER);
        pthread_mutex_lock(&stateLock);
        groupWaitReturned = 1;
        groupDone = sharedCounter + groupWaitReturned;
        pthread_mutex_unlock(&stateLock);
    }
    return NULL;
}

static BOOL groupDonePredicate(void) {
    pthread_mutex_lock(&stateLock);
    BOOL done = groupWaitReturned == 1;
    pthread_mutex_unlock(&stateLock);
    return done;
}

/* --- Leg 4: stack blocks outliving their frames ---------- */

static void scheduleStackAfterFromMain(void) {
    /* This frame is gone before the timer can fire: the stack block
     * handed to dispatch_after must be copied at enqueue time. */
    double deadline = CFAbsoluteTimeGetCurrent() + 0.1;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
        dispatch_get_main_queue(), ^{
        double fired = CFAbsoluteTimeGetCurrent();
        pthread_mutex_lock(&stateLock);
        ++mainAfter;
        mainAfterTime = fired;
        mainAfterNotEarly = fired >= deadline - 0.004;
        mainAfterOnMain = onMain();
        pthread_mutex_unlock(&stateLock);
    });
    mainAfterDeadline = deadline;
}

static void *afterWorker(void *unused) {
    (void)unused;
    @autoreleasepool {
        double deadline = CFAbsoluteTimeGetCurrent() + 0.1;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
            dispatch_get_main_queue(), ^{
            double fired = CFAbsoluteTimeGetCurrent();
            pthread_mutex_lock(&stateLock);
            ++workerAfter;
            workerAfterTime = fired;
            workerAfterNotEarly = fired >= deadline - 0.004;
            workerAfterOnMain = onMain();
            pthread_mutex_unlock(&stateLock);
        });
        workerAfterDeadline = deadline;
    }
    /* Worker pthread exits immediately: both the frame and the thread are
     * gone when the timer fires. */
    return NULL;
}

static BOOL mainAfterPredicate(void) {
    pthread_mutex_lock(&stateLock);
    BOOL done = mainAfter == 1;
    pthread_mutex_unlock(&stateLock);
    return done;
}

static BOOL workerAfterPredicate(void) {
    pthread_mutex_lock(&stateLock);
    BOOL done = workerAfter == 1;
    pthread_mutex_unlock(&stateLock);
    return done;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    signal(SIGALRM, watchdog);
    alarm(25);
    mainThread = pthread_self();
    @autoreleasepool {
        check("entry-main-thread", [NSThread isMainThread]);

        CFRunLoopSourceContext context = {0};
        context.perform = keepalive;
        CFRunLoopRef runLoop = CFRunLoopGetCurrent();
        CFRunLoopSourceRef source = CFRunLoopSourceCreate(NULL, 0, &context);
        check("run-loop-keepalive", source != NULL);
        if(!source) return 1;
        CFRunLoopAddSource(runLoop, source, kCFRunLoopDefaultMode);

        /* Leg 1: once from 3 native threads. */
        pthread_t racers[3];
        int created = 0;
        for(unsigned slot = 0; slot < 3; ++slot)
            created += pthread_create(&racers[slot], NULL, onceRacer,
                (void *)(uintptr_t)slot) == 0;
        check("once-racers-created", created == 3);
        if(created == 3) {
            for(unsigned slot = 0; slot < 3; ++slot)
                pthread_join(racers[slot], NULL);
            int onceTotal = 0, onceAllRun = 1;
            for(int site = 0; site < ONCE_SITES; ++site) {
                onceTotal += onceCounts[site];
                onceAllRun &= onceCounts[site] == 1;
            }
            check("dispatch-once-single-run", onceTotal == ONCE_SITES);
            check("dispatch-once-every-site-ran", onceAllRun);
            check("dispatch-once-all-threads-finished",
                oncePerThread[0] + oncePerThread[1] + oncePerThread[2] == 3);
            check("dispatch-once-inner-block-ran", onceInnerBlocks == ONCE_SITES);
        }

        /* Leg 2: serial queue-create pair, texture-cache sync shape. */
        dispatch_queue_t dictQueue = dispatch_queue_create(
            "lc32.dispatch-concurrency.dict", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_t loadingQueue = dispatch_queue_create(
            "lc32.dispatch-concurrency.loading", DISPATCH_QUEUE_SERIAL);
        check("queues-created", dictQueue != NULL && loadingQueue != NULL);
        if(dictQueue && loadingQueue) {
            pthread_t worker;
            int spawned = pthread_create(&worker, NULL, queueRacer, dictQueue);
            check("dict-sync-worker-created", spawned == 0);
            /* Main also syncs dictQueue: whichever sync is second must
             * block until the first completes — serial, no reentrancy,
             * no deadlock between a native worker and the main JIT. */
            dispatch_sync(dictQueue, ^{
                pthread_mutex_lock(&stateLock);
                ++mainSyncDone;
                pthread_mutex_unlock(&stateLock);
            });
            if(spawned == 0) pthread_join(worker, NULL);
            pthread_mutex_lock(&stateLock);
            unsigned inner = innerB, mainSync = mainSyncDone, workerSync = workerSyncDone;
            pthread_mutex_unlock(&stateLock);
            check("dispatch-sync-serial-both-ran",
                inner == 1 && mainSync == 1 && workerSync == 1);

            /* Async loadingQueue block from a native worker. */
            pthread_t loader;
            int loaderSpawned = pthread_create(&loader, NULL, loaderWorker,
                loadingQueue);
            check("loading-worker-created", loaderSpawned == 0);
            if(loaderSpawned == 0) pthread_join(loader, NULL);
            BOOL loaderDone = pumpUntil(^BOOL {
                pthread_mutex_lock(&stateLock);
                BOOL done = loaderB == 1;
                pthread_mutex_unlock(&stateLock);
                return done;
            }, 2.0);
            check("dispatch-async-loading-queue", loaderDone);
            dispatch_release(dictQueue);
            dispatch_release(loadingQueue);
        }

        /* Leg 3: 5-async group on global HIGH + FOREVER waiter, the
         * Chartboost prefetch shape against the 4-worker cap. */
        dispatch_group_t group = dispatch_group_create();
        check("group-created", group != NULL);
        if(group) {
            for(unsigned item = 0; item < GROUP_ITEMS; ++item) {
                dispatch_group_async(group,
                    dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
                    /* __block on a worker JIT exercises byref forwarding;
                     * the shared counter exercises exclusive stores. */
                    __block unsigned local = 0;
                    local += 1;
                    pthread_mutex_lock(&stateLock);
                    sharedCounter += local;
                    pthread_mutex_unlock(&stateLock);
                });
            }
            pthread_t waiter;
            int waiterSpawned = pthread_create(&waiter, NULL, groupWaiter,
                group);
            check("group-waiter-created", waiterSpawned == 0);
            if(waiterSpawned == 0) {
                /* The waiter parks on dispatch_group_wait(FOREVER); the
                 * group must drain around the 4-worker cap. */
                check("dispatch-group-wait-forever-drains",
                    pumpUntil(^BOOL { return groupDonePredicate(); }, 8.0));
                pthread_join(waiter, NULL);
            }
            pthread_mutex_lock(&stateLock);
            unsigned counted = sharedCounter, waiterDone = groupWaitReturned;
            pthread_mutex_unlock(&stateLock);
            check("dispatch-group-all-items-ran", counted == GROUP_ITEMS);
            check("dispatch-group-waiter-returned", waiterDone == 1);
            dispatch_release(group);
        }

        /* Leg 4a: stack block scheduled from main, frame expired. */
        scheduleStackAfterFromMain();
        check("dispatch-after-main-stack-copied",
            pumpUntil(^BOOL { return mainAfterPredicate(); }, 4.0));
        pthread_mutex_lock(&stateLock);
        unsigned mainFired = mainAfter;
        double mainFiredAt = mainAfterTime;
        BOOL mainNotEarly = mainAfterNotEarly, mainIsMain = mainAfterOnMain;
        pthread_mutex_unlock(&stateLock);
        check("dispatch-after-main-fired-once", mainFired == 1);
        check("dispatch-after-main-identity", mainIsMain);
        check("dispatch-after-main-not-early",
            mainFired == 1 && mainNotEarly && mainFiredAt >= mainAfterDeadline - 0.004);

        /* Leg 4b: the same 100ms main-queue after, but scheduled from a
         * native worker pthread that exits immediately. */
        pthread_t afterThread;
        int afterCreated = pthread_create(&afterThread, NULL, afterWorker, NULL);
        check("after-worker-created", afterCreated == 0);
        if(afterCreated == 0) {
            pthread_join(afterThread, NULL);
            check("dispatch-after-worker-main-hop",
                pumpUntil(^BOOL { return workerAfterPredicate(); }, 4.0));
            pthread_mutex_lock(&stateLock);
            unsigned workerFired = workerAfter;
            double workerFiredAt = workerAfterTime;
            BOOL workerNotEarly = workerAfterNotEarly;
            BOOL workerIsMain = workerAfterOnMain;
            pthread_mutex_unlock(&stateLock);
            check("dispatch-after-worker-fired-once", workerFired == 1);
            check("dispatch-after-worker-delivered-on-main", workerIsMain);
            check("dispatch-after-worker-not-early",
                workerFired == 1 && workerNotEarly &&
                workerFiredAt >= workerAfterDeadline - 0.004);
        }

        CFRunLoopRemoveSource(runLoop, source, kCFRunLoopDefaultMode);
        CFRunLoopSourceInvalidate(source);
        CFRelease(source);
    }
    alarm(0);
    printf("dispatch-concurrency: %d checks, %d failures\n", checks, failures);
    return failures != 0;
}
