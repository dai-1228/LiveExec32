#import <Foundation/Foundation.h>
#import <LC32/LC32.h>
#import <objc/runtime.h>

#include <pthread.h>

/*
 * SAVES-02: +[NSUserDefaults standardUserDefaults] used to forward straight
 * to the HOST process's standard defaults, so every emulated 32-bit title
 * shared one preference domain (the container app's). mfm stores maximally
 * generic keys ("firstRun", "firstRunCoins", "IAProductPurchased-<id>") and a
 * second installed title silently consumes those one-time gates.
 *
 * Route the standard defaults through a suite named after the guest bundle
 * identifier instead. NSBundle's manual main-bundle adapter already resolves
 * the identity-mounted guest application, so the suite domain matches the
 * per-app defaults domain the same binary would own on a real device.
 *
 * The generated shims keep their pure-forward bodies; this category exchanges
 * the three class methods that control the shared instance. Instance methods
 * are untouched: they forward through host_self to whichever host
 * NSUserDefaults peer the guest object already wraps, so the suite instance
 * they see is fully functional.
 *
 * Compatibility notes:
 * - A custom instance installed via +setStandardUserDefaults: is recorded
 *   guest-side and wins over the suite, matching reference semantics.
 * - +resetStandardUserDefaults drops both the custom record and the cached
 *   suite instance (the next call re-creates it from the same persistent
 *   domain, so synchronized values survive exactly like on-device).
 * - If the guest bundle identifier cannot be resolved yet, the original
 *   host-forward behavior is used, so very early callers keep working.
 * - The exchange pattern and the explicit original-selector forward follow
 *   UIApplication+LC32LegacyOrientation.m: the generated forwarders resolve
 *   their host selector from _cmd, so an exchanged implementation must never
 *   re-invoke the swapped IMP directly.
 */

static pthread_mutex_t LC32UserDefaultsDomainLock = PTHREAD_MUTEX_INITIALIZER;
static NSUserDefaults *LC32UserDefaultsSuiteInstance;
static NSUserDefaults *LC32UserDefaultsCustomInstance;

static NSUserDefaults *LC32SwapInUserDefaultsSuiteInstance(
        NSUserDefaults *created) {
    pthread_mutex_lock(&LC32UserDefaultsDomainLock);
    NSUserDefaults *winner = LC32UserDefaultsSuiteInstance;
    if(!winner) {
        LC32UserDefaultsSuiteInstance = created;
        winner = created;
        created = nil;
    }
    pthread_mutex_unlock(&LC32UserDefaultsDomainLock);
    [created release];
    return winner;
}

static void LC32RecordUserDefaultsCustomInstance(
        NSUserDefaults *instance) {
    [instance retain];
    pthread_mutex_lock(&LC32UserDefaultsDomainLock);
    NSUserDefaults *previous = LC32UserDefaultsCustomInstance;
    LC32UserDefaultsCustomInstance = instance;
    pthread_mutex_unlock(&LC32UserDefaultsDomainLock);
    [previous release];
}

static void LC32ClearUserDefaultsSharedInstances(void) {
    pthread_mutex_lock(&LC32UserDefaultsDomainLock);
    NSUserDefaults *suite = LC32UserDefaultsSuiteInstance;
    LC32UserDefaultsSuiteInstance = nil;
    NSUserDefaults *custom = LC32UserDefaultsCustomInstance;
    LC32UserDefaultsCustomInstance = nil;
    pthread_mutex_unlock(&LC32UserDefaultsDomainLock);
    [suite release];
    [custom release];
}

static void LC32ExchangeUserDefaultsClassMethod(
        Class cls, SEL original, SEL replacement) {
    Method originalMethod = class_getClassMethod(cls, original);
    Method replacementMethod = class_getClassMethod(cls, replacement);
    if(originalMethod && replacementMethod) {
        method_exchangeImplementations(originalMethod, replacementMethod);
    }
}

@implementation NSUserDefaults (LC32SuiteDefaults)

+ (void)load {
    LC32ExchangeUserDefaultsClassMethod(self,
        @selector(standardUserDefaults),
        @selector(lc32_standardUserDefaults));
    LC32ExchangeUserDefaultsClassMethod(self,
        @selector(setStandardUserDefaults:),
        @selector(lc32_setStandardUserDefaults:));
    LC32ExchangeUserDefaultsClassMethod(self,
        @selector(resetStandardUserDefaults),
        @selector(lc32_resetStandardUserDefaults));
}

+ (NSUserDefaults *)lc32_standardUserDefaults {
    pthread_mutex_lock(&LC32UserDefaultsDomainLock);
    NSUserDefaults *custom = LC32UserDefaultsCustomInstance;
    NSUserDefaults *cached = LC32UserDefaultsSuiteInstance;
    pthread_mutex_unlock(&LC32UserDefaultsDomainLock);
    if(custom) return custom;
    if(cached) return cached;

    NSString *domain = [[NSBundle mainBundle] bundleIdentifier];
    NSUserDefaults *suite = [domain length]
        ? [[NSUserDefaults alloc] initWithSuiteName:domain] : nil;
    if(suite) {
        return LC32SwapInUserDefaultsSuiteInstance(suite);
    }

    /* The guest bundle identity is not available yet (or the suite could
     * not be created): keep the previous host-standard-defaults behavior.
     * Forward the ORIGINAL selector explicitly; the generated forwarder
     * resolves its host selector from _cmd and must not be re-entered. */
    static uint64_t hostSelector __attribute__((aligned(8)));
    const uint64_t selector = LC32CachedHostSelector(
        &hostSelector, @selector(standardUserDefaults), NO);
    return LC32ReturnBorrowedGuestObject(LC32InvokeHostObjectSelector(
        self.host_self, selector, (uint64_t)0));
}

+ (void)lc32_setStandardUserDefaults:(NSUserDefaults *)instance {
    LC32RecordUserDefaultsCustomInstance(instance);

    static uint64_t hostSelector __attribute__((aligned(8)));
    const uint64_t selector = LC32CachedHostSelector(
        &hostSelector, @selector(setStandardUserDefaults:), NO);
    (void)LC32InvokeHostSelector(self.host_self, selector,
        [instance host_self], (uint64_t)0);
}

+ (void)lc32_resetStandardUserDefaults {
    LC32ClearUserDefaultsSharedInstances();

    static uint64_t hostSelector __attribute__((aligned(8)));
    const uint64_t selector = LC32CachedHostSelector(
        &hostSelector, @selector(resetStandardUserDefaults), NO);
    (void)LC32InvokeHostSelector(self.host_self, selector, (uint64_t)0);
}

@end
