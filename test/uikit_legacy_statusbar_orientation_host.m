// Exercise the real guest UIKit status-bar orientation categories with a
// deterministic native bridge (the mediaplayer-stop host-test pattern).
//
// The load-time configuration models the 2009 guest that motivates the
// gates: an executable with no SDK version marker under a host process that
// runs UIKit's own pre-iOS-8 rotation. The shared gate's remaining
// combinations are verified through its pure decision function.
#import <UIKit/UIKit.h>
#import <LC32/LC32.h>
#import <objc/runtime.h>

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "LC32UIKitCompatibility.h"

@implementation NSObject (LC32StatusBarTestBridge)
- (uint64_t)host_self { return (uint64_t)(uintptr_t)self; }
@end

static unsigned checks, failures;

static void check(BOOL condition, const char *name) {
    ++checks;
    failures += !condition;
    printf("%s %s\n", condition ? "PASS" : "FAIL", name);
}

enum {
    LC32TestStubGetSDK = 1,
    LC32TestStubNativeRotation,
    LC32TestStubHandleOrientation,
    LC32TestStubGetOrientation,
    LC32TestStubHandleHidden,
    LC32TestStubGetControllerOrientation,
};

static const uint32_t stubExecutableSDK = 0;
static UIInterfaceOrientation recordedOrientation = UIInterfaceOrientationUnknown;
static unsigned recordedOrientationCalls;
static int recordedHidden = -1;
static unsigned recordedHiddenCalls;
static UIInterfaceOrientation reportedStatusBarOrientation =
    UIInterfaceOrientationUnknown;
static UIInterfaceOrientation reportedControllerOrientation =
    UIInterfaceOrientationUnknown;
static UIInterfaceOrientation nativeStatusBarOrientation =
    UIInterfaceOrientationPortrait;
static BOOL nativeStatusBarHidden;
static UIInterfaceOrientation nativeControllerOrientation =
    UIInterfaceOrientationPortrait;
static unsigned forwardedOrientationCalls;
static unsigned forwardedHiddenCalls;
static uint64_t forwardedOrientation;
static uint64_t forwardedAnimated;
static uint64_t forwardedHidden;

@implementation UIApplication
- (UIInterfaceOrientation)statusBarOrientation {
    return nativeStatusBarOrientation;
}
- (void)setStatusBarHidden:(BOOL)hidden animated:(BOOL)animated {
    nativeStatusBarHidden = hidden;
    (void)animated;
}
@end

@implementation UIViewController
- (UIInterfaceOrientation)interfaceOrientation {
    return nativeControllerOrientation;
}
@end

uint64_t LC32Dlsym(const char *name, BOOL isFunction) {
    check(isFunction, "dlsym resolves function pointers");
    if(!strcmp(name, "LC32GetGuestExecutableSDKVersion"))
        return LC32TestStubGetSDK;
    if(!strcmp(name, "LC32NativeLegacyRotationEnabled"))
        return LC32TestStubNativeRotation;
    if(!strcmp(name, "LC32UIKitHandleLegacyStatusBarOrientation"))
        return LC32TestStubHandleOrientation;
    if(!strcmp(name, "LC32UIKitGetLegacyStatusBarOrientation"))
        return LC32TestStubGetOrientation;
    if(!strcmp(name, "LC32UIKitHandleLegacyStatusBarHidden"))
        return LC32TestStubHandleHidden;
    if(!strcmp(name, "LC32UIKitGetLegacyControllerOrientation"))
        return LC32TestStubGetControllerOrientation;
    /* An older host without an entry keeps the no-op forwarder. */
    return 0;
}

uint32_t LC32InvokeHostCRet32(uint64_t hostPtr, ...) {
    va_list arguments;
    va_start(arguments, hostPtr);
    uint32_t result = 0;
    switch(hostPtr) {
        case LC32TestStubGetSDK:
            result = stubExecutableSDK;
            break;
        case LC32TestStubNativeRotation:
            result = 1;
            break;
        case LC32TestStubHandleOrientation:
            recordedOrientation = (UIInterfaceOrientation)
                va_arg(arguments, uint32_t);
            ++recordedOrientationCalls;
            break;
        case LC32TestStubGetOrientation:
            result = (uint32_t)reportedStatusBarOrientation;
            break;
        case LC32TestStubHandleHidden:
            recordedHidden = va_arg(arguments, uint32_t) != 0;
            ++recordedHiddenCalls;
            break;
        case LC32TestStubGetControllerOrientation:
            result = (uint32_t)reportedControllerOrientation;
            break;
        default:
            check(NO, "unexpected host C entry");
            break;
    }
    va_end(arguments);
    return result;
}

static uint64_t stubSelectorToken(SEL selector) {
    const char *name = sel_getName(selector);
    if(!strcmp(name, "statusBarOrientation")) return 1;
    if(!strcmp(name, "setStatusBarOrientation:")) return 2;
    if(!strcmp(name, "setStatusBarOrientation:animated:")) return 3;
    if(!strcmp(name, "setStatusBarHidden:animated:")) return 4;
    if(!strcmp(name, "interfaceOrientation")) return 5;
    check(NO, "unexpected forwarded selector");
    return 0;
}

uint64_t LC32CachedHostSelector(uint64_t *cache, SEL selector, BOOL superCall) {
    check(!superCall, "forwards the public selector, not a super call");
    return *cache = stubSelectorToken(selector);
}

uint64_t LC32InvokeHostSelector(uint64_t receiver, uint64_t command, ...) {
    (void)receiver;
    va_list arguments;
    va_start(arguments, command);
    uint64_t result = 0;
    switch(command) {
        case 1:
            result = (uint32_t)nativeStatusBarOrientation;
            break;
        case 2:
            ++forwardedOrientationCalls;
            forwardedOrientation = va_arg(arguments, uint64_t);
            break;
        case 3:
            ++forwardedOrientationCalls;
            forwardedOrientation = va_arg(arguments, uint64_t);
            forwardedAnimated = va_arg(arguments, uint64_t);
            break;
        case 4:
            ++forwardedHiddenCalls;
            forwardedHidden = va_arg(arguments, uint64_t);
            forwardedAnimated = va_arg(arguments, uint64_t);
            break;
        case 5:
            result = (uint32_t)nativeControllerOrientation;
            break;
        default:
            check(NO, "unexpected forwarded host selector");
            break;
    }
    va_end(arguments);
    return result;
}

/* Supplied here in place of the guest UIKit shim unit that owns them. */
BOOL LC32GuestUIKitLegacyCompatibilityEnabled(void) {
    return NO;
}

BOOL LC32GuestNativeLegacyRotationEnabled(void) {
    return YES;
}

int main(void) {
    @autoreleasepool {
        /* Shared SDK gate: SDK-0 inherits the pre-iOS-8 geometry contract
         * under native rotation, every established population is unchanged. */
        check(LC32GuestSDKUsesLegacyGeometryContract(0, NO, YES),
              "sdk0-inherits-legacy-geometry-under-native-rotation");
        check(!LC32GuestSDKUsesLegacyGeometryContract(0, NO, NO),
              "sdk0-without-legacy-modes-stays-modern");
        check(!LC32GuestSDKUsesLegacyGeometryContract(0, YES, NO),
              "sdk0-stays-excluded-on-canvas-hosts");
        check(LC32GuestSDKUsesLegacyGeometryContract(0x00060000, YES, NO),
              "sdk6-canvas-population-unchanged");
        check(LC32GuestSDKUsesLegacyGeometryContract(0x00060000, YES, YES),
              "sdk6-canvas-answer-wins-over-native");
        check(!LC32GuestSDKUsesLegacyGeometryContract(0x00060000, NO, YES),
              "sdk6-native-stays-excluded");
        check(!LC32GuestSDKUsesLegacyGeometryContract(0x00080000, YES, NO),
              "sdk8-executable-excluded");
        check(!LC32GuestSDKUsesLegacyGeometryContract(0x000B0000, YES, YES),
              "sdk11-executable-excluded");

        /* The controller override installs for the load-time configuration. */
        UIViewController *controller = [[UIViewController alloc] init];
        reportedControllerOrientation = UIInterfaceOrientationLandscapeRight;
        check(controller.interfaceOrientation == UIInterfaceOrientationLandscapeRight,
              "controller-orientation-reads-adapter-pairing");
        reportedControllerOrientation = UIInterfaceOrientationUnknown;
        nativeControllerOrientation = UIInterfaceOrientationPortrait;
        check(controller.interfaceOrientation == UIInterfaceOrientationPortrait,
              "unknown-adapter-answer-falls-back-to-forwarder");

        /* The status-bar getter stays unpaired until a request is made:
         * load-time pairing remains a canvas-only property. */
        UIApplication *application = [[UIApplication alloc] init];
        reportedStatusBarOrientation = UIInterfaceOrientationLandscapeRight;
        check(application.statusBarOrientation == UIInterfaceOrientationPortrait,
              "getter-stays-unpaired-before-any-request");
        check(recordedOrientationCalls == 0,
              "no-orientation-recorded-before-request");

        /* The setter records the host request and still forwards. */
        [application setStatusBarOrientation:UIInterfaceOrientationLandscapeRight
                                      animated:NO];
        check(recordedOrientationCalls == 1 &&
              recordedOrientation == UIInterfaceOrientationLandscapeRight,
              "animated-setter-records-host-request");
        check(forwardedOrientationCalls == 1 &&
              forwardedOrientation == (uint64_t)UIInterfaceOrientationLandscapeRight &&
              forwardedAnimated == 0,
              "animated-setter-still-forwards-public-selector");
        check(application.statusBarOrientation == UIInterfaceOrientationLandscapeRight,
              "paired-getter-reads-back-recorded-request");

        /* The plain setter records too. */
        [application setStatusBarOrientation:UIInterfaceOrientationLandscapeLeft];
        check(recordedOrientationCalls == 2 &&
              recordedOrientation == UIInterfaceOrientationLandscapeLeft &&
              forwardedOrientationCalls == 2 &&
              forwardedOrientation == (uint64_t)UIInterfaceOrientationLandscapeLeft,
              "plain-setter-records-and-forwards");

        /* Runtime visibility requests record beside the plist preference. */
        [application setStatusBarHidden:YES animated:YES];
        check(recordedHiddenCalls == 1 && recordedHidden == 1 &&
              forwardedHiddenCalls == 1 && forwardedHidden == 1 &&
              forwardedAnimated == 1,
              "hidden-request-records-and-still-forwards");
        [application setStatusBarHidden:NO animated:NO];
        check(recordedHiddenCalls == 2 && recordedHidden == 0 &&
              forwardedHiddenCalls == 2 && forwardedHidden == 0 &&
              forwardedAnimated == 0,
              "unhide-request-records-and-still-forwards");
        (void)nativeStatusBarHidden;

        printf("uikit-legacy-statusbar: %u checks, %u failures\n",
               checks, failures);
        return failures != 0;
    }
}
