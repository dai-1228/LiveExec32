#import <Foundation/Foundation.h>
#import <LC32/LC32.h>
#import <objc/runtime.h>

#include <pthread.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

@interface NSObject (LC32NativeProxyReleaseTest)
/* Original guest-only retainCount after LC32's method exchange. */
- (NSUInteger)LC32_retainCount;
@end

/* Build this fixture at -O2 (see its Makefile instance): unoptimized ARM32
 * atomic compare/exchange lowering currently hits an unrelated guest-emulator
 * instruction issue, before this ownership regression can be measured. */
static unsigned deallocCount;
static char deallocProbeKey;
static int failures;

/* Guest-only associated storage observes proxy destruction without changing
 * the native NSObject into a synthesized guest-subclass mirror. */
@interface LC32NativeProxyDeallocProbe : LC32GuestBuffer
@end
@implementation LC32NativeProxyDeallocProbe
- (void)dealloc {
    __atomic_fetch_add(&deallocCount, 1, __ATOMIC_RELAXED);
    [super dealloc];
}
@end

static void report(const char *name, BOOL passed) {
    printf("native-proxy-release-%s: %s\n", name, passed ? "PASS" : "FAIL");
    failures += !passed;
}

static uint64_t rawSend(uint64_t object, SEL selector) {
    /* The initial raw object has not been published to the guest registry.
     * These calls always hold explicit native ownership of that receiver. */
    return LC32InvokeHostSelector(object,
        LC32HostSelectorAllowingUnmappedReceiver(LC32GetHostSelector(selector)),
        (uint64_t)0);
}

typedef struct {
    uint64_t host;
    id guest;
    uint32_t guestAddress;
    unsigned baseline;
} Proxy;

static Proxy createProxy(unsigned nativeOwners) {
    if(!nativeOwners) abort();
    const uint64_t hostClass = [(id)[NSObject class] host_self];
    const uint64_t allocation = rawSend(hostClass, @selector(alloc));
    const uint64_t host = allocation ? rawSend(allocation, @selector(init)) : 0;
    if(!host) {
        fprintf(stderr, "native-proxy-release: native NSObject allocation failed\n");
        exit(1);
    }
    for(unsigned index = 1; index < nativeOwners; ++index) {
        rawSend(host, @selector(retain));
    }
    const unsigned baseline = __atomic_load_n(&deallocCount, __ATOMIC_RELAXED);
    id guest = LC32HostToGuestObject(host);
    if(!guest) {
        for(unsigned index = 0; index < nativeOwners; ++index) {
            rawSend(host, @selector(release));
        }
        fprintf(stderr, "native-proxy-release: borrowed proxy publication failed\n");
        exit(1);
    }
    LC32NativeProxyDeallocProbe *probe = [LC32NativeProxyDeallocProbe new];
    objc_setAssociatedObject(guest, &deallocProbeKey, probe,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [probe release];
    const Proxy result = {host, guest, (uint32_t)(uintptr_t)guest, baseline};
    report("setup-has-only-lifetime-pin",
        [guest LC32_retainCount] == 1 &&
        rawSend(host, @selector(retainCount)) == nativeOwners &&
        LC32LookupHostMapping(result.guestAddress) == host);
    return result;
}

static BOOL liveWithOwners(Proxy proxy, unsigned nativeOwners) {
    return LC32LookupHostMapping(proxy.guestAddress) == proxy.host &&
        __atomic_load_n(&deallocCount, __ATOMIC_RELAXED) == proxy.baseline &&
        [proxy.guest LC32_retainCount] == 1 &&
        rawSend(proxy.host, @selector(retainCount)) == nativeOwners;
}

static void finishProxy(Proxy proxy, const char *name) {
    /* Exactly one explicit native owner remains. Do not message either object
     * after this release: only the address-keyed registry and counter survive. */
    rawSend(proxy.host, @selector(release));
    report(name, LC32LookupHostMapping(proxy.guestAddress) == 0 &&
        __atomic_load_n(&deallocCount, __ATOMIC_RELAXED) == proxy.baseline + 1);
}

static void testBorrowedRelease(void) {
    Proxy proxy = createProxy(3);
    /* A raw native +1 can be consumed through a borrowed guest proxy. That
     * does not transfer ownership of the host's guest lifetime pin. */
    [proxy.guest release];
    report("borrowed-release-preserves-pin", liveWithOwners(proxy, 2));

    [proxy.guest retain];
    report("balanced-retain-adds-both-halves",
        [proxy.guest LC32_retainCount] == 2 &&
        rawSend(proxy.host, @selector(retainCount)) == 3);
    [proxy.guest release];
    report("balanced-release-returns-to-pin", liveWithOwners(proxy, 2));

    rawSend(proxy.host, @selector(release));
    report("native-owner-alone-keeps-proxy-live", liveWithOwners(proxy, 1));
    finishProxy(proxy, "final-native-release-destroys-proxy-once");
}

static void testNativeOnlyOwners(void) {
    Proxy proxy = createProxy(3);
    rawSend(proxy.host, @selector(release));
    rawSend(proxy.host, @selector(release));
    report("native-only-releases-preserve-pin", liveWithOwners(proxy, 1));
    finishProxy(proxy, "native-only-final-release-destroys-proxy-once");
}

static void testBorrowedAutorelease(void) {
    Proxy proxy = createProxy(2);
    NSAutoreleasePool *pool = [NSAutoreleasePool new];
    [proxy.guest autorelease];
    report("autorelease-does-not-consume-pin-early", liveWithOwners(proxy, 2));
    [pool drain];
    /* The native autorelease token consumes one host owner separately from
     * the logical-only guest release; the latter must stop at the pin floor. */
    report("autorelease-drain-preserves-pin", liveWithOwners(proxy, 1));
    finishProxy(proxy, "autorelease-final-native-release-destroys-proxy-once");
}

static void testBalancedAutorelease(void) {
    Proxy proxy = createProxy(1);
    NSAutoreleasePool *pool = [NSAutoreleasePool new];
    [[proxy.guest retain] autorelease];
    report("balanced-autorelease-retains-logical-owner",
        [proxy.guest LC32_retainCount] == 2 &&
        rawSend(proxy.host, @selector(retainCount)) == 2);
    [pool drain];
    report("balanced-autorelease-drain-returns-to-pin", liveWithOwners(proxy, 1));
    finishProxy(proxy, "balanced-autorelease-final-release-destroys-proxy-once");
}

enum { WorkerCount = 4, ReleasesPerWorker = 16 };
typedef struct {
    id guest;
    unsigned start;
} ReleaseWork;

static void *releaseWorker(void *opaque) {
    ReleaseWork *work = opaque;
    NSAutoreleasePool *pool = [NSAutoreleasePool new];
    while(!__atomic_load_n(&work->start, __ATOMIC_ACQUIRE)) sched_yield();
    for(unsigned index = 0; index < ReleasesPerWorker; ++index) {
        [work->guest release];
    }
    [pool drain];
    return NULL;
}

static void testConcurrentNativeOwners(void) {
    /* All worker releases are covered by real native references. The extra
     * owner protects the shared proxy until every worker has joined. */
    Proxy proxy = createProxy(1 + WorkerCount * ReleasesPerWorker);
    ReleaseWork work = {proxy.guest, 0};
    pthread_t workers[WorkerCount];
    unsigned created = 0;
    for(; created < WorkerCount; ++created) {
        const int error = pthread_create(&workers[created], NULL,
            releaseWorker, &work);
        if(error) {
            fprintf(stderr, "native-proxy-release: pthread_create failed: %d\n", error);
            break;
        }
    }
    __atomic_store_n(&work.start, 1, __ATOMIC_RELEASE);
    for(unsigned index = 0; index < created; ++index) {
        if(pthread_join(workers[index], NULL)) {
            /* Unknown worker lifetime: do not free its stack state or consume
             * the final owner while it may still be using the proxy. */
            fprintf(stderr, "native-proxy-release: pthread_join failed\n");
            exit(1);
        }
    }
    /* On partial setup, consume only owners assigned to workers never started. */
    for(unsigned index = created * ReleasesPerWorker;
            index < WorkerCount * ReleasesPerWorker; ++index) {
        rawSend(proxy.host, @selector(release));
    }
    report("concurrent-workers-created", created == WorkerCount);
    report("concurrent-releases-preserve-single-pin", liveWithOwners(proxy, 1));
    finishProxy(proxy, "concurrent-final-native-release-destroys-proxy-once");
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    NSAutoreleasePool *pool = [NSAutoreleasePool new];
    testBorrowedRelease();
    testNativeOnlyOwners();
    testBorrowedAutorelease();
    testBalancedAutorelease();
    testConcurrentNativeOwners();
    [pool drain];
    report("all-proxies-destroyed-once",
        __atomic_load_n(&deallocCount, __ATOMIC_RELAXED) == 5);
    printf("native-proxy-release-regression: %s\n", failures ? "FAIL" : "PASS");
    return failures != 0;
}
