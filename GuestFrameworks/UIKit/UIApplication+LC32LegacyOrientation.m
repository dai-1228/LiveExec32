#import <LC32/LC32.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#include <pthread.h>
#include <stdint.h>
#include "LC32UIKitCompatibility.h"

static pthread_once_t LC32LegacyOrientationOnce = PTHREAD_ONCE_INIT;
static uint64_t LC32HostLegacyOrientation;
static uint64_t LC32HostLegacyStatusBarOrientation;
static uint64_t LC32HostLegacyStatusBarHidden;
static pthread_once_t LC32LegacyStatusBarGetterOnce = PTHREAD_ONCE_INIT;

static void LC32ResolveLegacyOrientation(void) {
    /* Resolve both entries unconditionally: the canvas adapters and the
     * native legacy rotation unit gate their own behavior on the host, and
     * an older host without either entry keeps the no-op forwarder. */
    LC32HostLegacyOrientation = LC32Dlsym(
        "LC32UIKitHandleLegacyStatusBarOrientation", YES);
    LC32HostLegacyStatusBarOrientation = LC32Dlsym(
        "LC32UIKitGetLegacyStatusBarOrientation", YES);
    LC32HostLegacyStatusBarHidden = LC32Dlsym(
        "LC32UIKitHandleLegacyStatusBarHidden", YES);
}

static BOOL LC32NeedsLegacyStatusBarOrientationOverride(void) {
    pthread_once(&LC32LegacyOrientationOnce,
        LC32ResolveLegacyOrientation);
    if(!LC32HostLegacyStatusBarOrientation) return NO;

    return (UIInterfaceOrientation)LC32InvokeHostCRet32(
        LC32HostLegacyStatusBarOrientation) !=
        UIInterfaceOrientationUnknown;
}

static void LC32SwapStatusBarOrientationImplementations(void) {
    Method original = class_getInstanceMethod(
        [UIApplication class], @selector(statusBarOrientation));
    Method compatibility = class_getInstanceMethod(
        [UIApplication class], @selector(lc32_statusBarOrientation));
    if(original && compatibility) {
        method_exchangeImplementations(original, compatibility);
    }
}

static void LC32InstallLegacyStatusBarOrientationGetter(void) {
    /* Install the paired getter once. Canvas-paired applications install at
     * load time below; a native-legacy-rotation process cannot know at load
     * time whether the application will declare an orientation, so the
     * setters install the pairing after the first request. */
    pthread_once(&LC32LegacyStatusBarGetterOnce,
        LC32SwapStatusBarOrientationImplementations);
}

static void LC32ForwardLegacyOrientation(
        UIInterfaceOrientation orientation) {
    pthread_once(&LC32LegacyOrientationOnce,
        LC32ResolveLegacyOrientation);
    if(!LC32HostLegacyOrientation) return;
    LC32InvokeHostCRet32(LC32HostLegacyOrientation,
        (uint32_t)orientation, (uint32_t)0);
}

static void LC32ForwardLegacyStatusBarHidden(BOOL hidden) {
    pthread_once(&LC32LegacyOrientationOnce,
        LC32ResolveLegacyOrientation);
    if(!LC32HostLegacyStatusBarHidden) return;
    LC32InvokeHostCRet32(LC32HostLegacyStatusBarHidden,
        (uint32_t)hidden, (uint32_t)0);
}

@interface UIApplication (LC32LegacyOrientation)
- (UIInterfaceOrientation)lc32_statusBarOrientation;
- (void)setStatusBarOrientation:(UIInterfaceOrientation)orientation;
- (void)setStatusBarOrientation:(UIInterfaceOrientation)orientation
                        animated:(BOOL)animated;
- (void)lc32_setStatusBarHidden:(BOOL)hidden animated:(BOOL)animated;
@end

@implementation UIApplication (LC32LegacyOrientation)

+ (void)load {
    /* Most phone applications must keep the generated direct forwarder.
     * Install this override only for the fixed legacy canvases whose scene
     * orientation and guest projection need to remain paired. Besides
     * avoiding an extra bridge round trip, this leaves applications that
     * manage both landscape sides themselves (such as old movie-based
     * launchers) completely untouched. */
    if(LC32NeedsLegacyStatusBarOrientationOverride())
        LC32InstallLegacyStatusBarOrientationGetter();

    /* Runtime status-bar visibility is part of the same pre-iOS-7 contract.
     * The generated shim still forwards the obsolete selector while modern
     * UIKit ignores it, so exchange implementations to record the request
     * while preserving the forward itself. The host gates the recording to
     * legacy-mode pre-iOS-8 executables; everyone else forwards unchanged. */
    Method hiddenOriginal = class_getInstanceMethod(
        self, @selector(setStatusBarHidden:animated:));
    Method hiddenCompatibility = class_getInstanceMethod(
        self, @selector(lc32_setStatusBarHidden:animated:));
    if(hiddenOriginal && hiddenCompatibility) {
        method_exchangeImplementations(hiddenOriginal, hiddenCompatibility);
    }
}

- (UIInterfaceOrientation)lc32_statusBarOrientation {
    pthread_once(&LC32LegacyOrientationOnce,
        LC32ResolveLegacyOrientation);
    if(LC32HostLegacyStatusBarOrientation) {
        const UIInterfaceOrientation orientation =
            (UIInterfaceOrientation)LC32InvokeHostCRet32(
            LC32HostLegacyStatusBarOrientation);
        if(orientation != UIInterfaceOrientationUnknown) {
            return orientation;
        }
    }

    /* The generated forwarder uses _cmd, so calling its exchanged IMP would
     * incorrectly ask native UIApplication for lc32_statusBarOrientation.
     * Forward the original selector explicitly when the compatibility host
     * has no legacy-canvas override. */
    static uint64_t hostSelector __attribute__((aligned(8)));
    const uint64_t selector = LC32CachedHostSelector(
        &hostSelector, @selector(statusBarOrientation), NO);
    return (UIInterfaceOrientation)(uint32_t)LC32InvokeHostSelector(
        self.host_self, selector, (uint64_t)0);
}

- (void)setStatusBarOrientation:(UIInterfaceOrientation)orientation {
    /* GenerateShimAPI deliberately omits this obsolete forwarding shim.
     * Modern UIApplication ignores it, while LC32's host scene adapter must
     * retain the old app's orientation intent. Calling the UIKit-specific C
     * bridge here keeps that policy out of the generic Objective-C bridge. */
    static uint64_t hostSelector __attribute__((aligned(8)));
    const uint64_t selector = LC32CachedHostSelector(
        &hostSelector, _cmd, NO);
    const uint64_t hostSelf = self.host_self;
    LC32ForwardLegacyOrientation(orientation);
    if(LC32GuestNativeLegacyRotationEnabled())
        LC32InstallLegacyStatusBarOrientationGetter();
    LC32InvokeHostSelector(hostSelf, selector,
        (uint64_t)(int64_t)orientation, (uint64_t)0);
}

- (void)setStatusBarOrientation:(UIInterfaceOrientation)orientation
                        animated:(BOOL)animated {
    static uint64_t hostSelector __attribute__((aligned(8)));
    const uint64_t selector = LC32CachedHostSelector(
        &hostSelector, _cmd, NO);
    const uint64_t hostSelf = self.host_self;
    LC32ForwardLegacyOrientation(orientation);
    if(LC32GuestNativeLegacyRotationEnabled())
        LC32InstallLegacyStatusBarOrientationGetter();
    LC32InvokeHostSelector(hostSelf, selector,
        (uint64_t)(int64_t)orientation,
        (uint64_t)(animated != NO), (uint64_t)0);
}

- (void)lc32_setStatusBarHidden:(BOOL)hidden animated:(BOOL)animated {
    /* The exchanged generated forwarder derives its host selector from
     * _cmd, so forward the public selector explicitly, exactly like the
     * orientation getter pairing above. Recording happens before the
     * forward; the host adapter stores it only for legacy-mode pre-iOS-8
     * executables. */
    static uint64_t hostSelector __attribute__((aligned(8)));
    const uint64_t selector = LC32CachedHostSelector(
        &hostSelector, @selector(setStatusBarHidden:animated:), NO);
    const uint64_t hostSelf = self.host_self;
    LC32ForwardLegacyStatusBarHidden(hidden);
    LC32InvokeHostSelector(hostSelf, selector,
        (uint64_t)hidden, (uint64_t)animated, (uint64_t)0);
}

@end
