// Exercise the shared runtime-declared canvas classifier and the fixed
// canvas presentation math from the real include/LC32LegacyCanvas.h (the
// canvas model's single source of truth). Everything here is deterministic
// pure math, so no UIKit is needed; the host adapter and the guest UIScreen
// overrides both consume these inlines. The bundle-level classifiers read
// real Info.plists through small on-disk fixtures under the temporary
// directory. Window eligibility and the measured fit's drawable-layer
// selection live in the host UIKit adapter (real UIKit windows and layers),
// so they are device/CI coverage, not this pure fixture.
#import <Foundation/Foundation.h>

#include "LC32LegacyCanvas.h"

#include <math.h>
#include <stdio.h>

static unsigned checks, failures;

static void check(BOOL condition, const char *name) {
    ++checks;
    failures += !condition;
    printf("%s %s\n", condition ? "PASS" : "FAIL", name);
}

static BOOL closeScalar(CGFloat a, CGFloat b) {
    return isfinite(a) && isfinite(b) && fabs(a - b) < 0.0001;
}

static BOOL closeTransform(
        CGAffineTransform value, CGFloat a, CGFloat b, CGFloat c,
        CGFloat d, CGFloat tx, CGFloat ty) {
    return closeScalar(value.a, a) && closeScalar(value.b, b) &&
        closeScalar(value.c, c) && closeScalar(value.d, d) &&
        closeScalar(value.tx, tx) && closeScalar(value.ty, ty);
}

/* Minimal on-disk bundle fixtures: the header's bundle-level helpers read
 * real Info.plists and probe real resource paths, so their truth tables
 * need actual bundles. Each lives under a unique temporary directory and
 * is removed after its checks. */
static NSBundle *LC32TestBundleWithInfo(
        NSDictionary *info, NSArray<NSString *> *launchImages) {
    NSString *directory = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[@"lc32-canvas-fit-"
            stringByAppendingString:
                NSProcessInfo.processInfo.globallyUniqueString]];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
    [info writeToFile:[directory
        stringByAppendingPathComponent:@"Info.plist"] atomically:YES];
    for(NSString *name in launchImages) {
        [@"" writeToFile:[directory stringByAppendingPathComponent:name]
              atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    return [NSBundle bundleWithPath:directory];
}

static void LC32TestDiscardBundle(NSBundle *bundle) {
    if(bundle) {
        [[NSFileManager defaultManager] removeItemAtPath:bundle.bundlePath
                                                  error:nil];
    }
}

int main(void) {
    @autoreleasepool {
        /* The class: keyless pre-iOS-8 phone bundles that declared a
         * landscape interface orientation through the runtime status-bar
         * API. Values follow UIInterfaceOrientation: 3 == LandscapeRight,
         * 4 == LandscapeLeft. */
        check(LC32UsesRuntimeLandscapePhoneCanvas(
                  0, YES, NO, NO, 3),
              "sdk0-keyless-phone-landscape-right-qualifies");
        check(LC32UsesRuntimeLandscapePhoneCanvas(
                  0, YES, NO, NO, 4),
              "sdk0-keyless-phone-landscape-left-qualifies");
        check(LC32UsesRuntimeLandscapePhoneCanvas(
                  0x00070000, YES, NO, NO, 3),
              "sdk7-keyless-phone-landscape-right-qualifies");
        check(!LC32UsesRuntimeLandscapePhoneCanvas(
                  0, YES, NO, NO, 1),
              "portrait-request-does-not-qualify");
        check(!LC32UsesRuntimeLandscapePhoneCanvas(
                  0, YES, NO, NO, 2),
              "portrait-upside-down-request-does-not-qualify");
        check(!LC32UsesRuntimeLandscapePhoneCanvas(
                  0, YES, NO, NO, 0),
              "unrecorded-request-does-not-qualify");
        check(!LC32UsesRuntimeLandscapePhoneCanvas(
                  0, YES, NO, YES, 3),
              "declared-orientation-keys-keep-their-class");
        check(!LC32UsesRuntimeLandscapePhoneCanvas(
                  0, YES, YES, NO, 3),
              "pad-idiom-bundle-does-not-qualify");
        check(!LC32UsesRuntimeLandscapePhoneCanvas(
                  0, NO, NO, NO, 3),
              "phone-unsupported-bundle-does-not-qualify");
        check(!LC32UsesRuntimeLandscapePhoneCanvas(
                  0x00080000, YES, NO, NO, 3),
              "sdk8-executable-does-not-qualify");
        check(!LC32UsesRuntimeLandscapePhoneCanvas(
                  0x000B0000, YES, NO, NO, 3),
              "sdk11-executable-does-not-qualify");

        /* The declared-universal class: a pre-iOS-8 bundle supporting both
         * device families that declares a landscape-only phone policy,
         * executing in the phone idiom. Truth table over real bundles,
         * including the strictly-additive guarantee against the existing
         * classes. */
        NSDictionary *universalLandscape = @{
            @"UIDeviceFamily": @[@1, @2],
            @"UISupportedInterfaceOrientations": @[
                @"UIInterfaceOrientationLandscapeLeft",
                @"UIInterfaceOrientationLandscapeRight",
            ],
        };
        NSBundle *bundle = LC32TestBundleWithInfo(universalLandscape,
            @[@"Default.png", @"Default@2x.png"]);
        check(LC32BundleUsesDeclaredLandscapePhoneCanvasInPhoneIdiom(
                  bundle, 0x00070000, YES),
              "universal-landscape-pre8-phone-idiom-qualifies");
        check(LC32BundleUsesDeclaredLandscapePhoneCanvasInPhoneIdiom(
                  bundle, 0, YES),
              "sdk0-marker-universal-landscape-still-qualifies");
        check(!LC32BundleUsesDeclaredLandscapePhoneCanvasInPhoneIdiom(
                  bundle, 0x00070000, NO),
              "pad-idiom-execution-does-not-qualify");
        check(!LC32BundleUsesDeclaredLandscapePhoneCanvasInPhoneIdiom(
                  bundle, 0x00080000, YES),
              "sdk8-executable-does-not-qualify-in-declared-class");
        check(LC32BundleLegacyIPadCanvasKind(bundle, 0x00070000) ==
                  LC32LegacyIPadCanvasNone,
              "universal-bundle-stays-out-of-ipad-canvas-classes");
        /* Canvas size selection: no tall launch art means the fixed canvas
         * stays 480 points tall. */
        check(!LC32BundleContainsTallPhoneLaunchArt(
                  bundle, bundle.infoDictionary),
              "no-tall-art-selects-480-point-canvas");
        LC32TestDiscardBundle(bundle);

        bundle = LC32TestBundleWithInfo(universalLandscape,
            @[@"Default.png", @"Default@2x.png",
              @"Default-568h@2x.png"]);
        check(LC32BundleUsesDeclaredLandscapePhoneCanvasInPhoneIdiom(
                  bundle, 0x00070000, YES),
              "tall-art-universal-landscape-still-qualifies");
        /* Canvas size selection: 4-inch launch art extends the fixed canvas
         * to 568 points, exactly the historical 4-inch device screen. */
        check(LC32BundleContainsTallPhoneLaunchArt(
                  bundle, bundle.infoDictionary),
              "tall-art-selects-568-point-canvas");
        LC32TestDiscardBundle(bundle);

        bundle = LC32TestBundleWithInfo(@{
            @"UIDeviceFamily": @[@1, @2],
            @"UISupportedInterfaceOrientations":
                @[@"UIInterfaceOrientationPortrait"],
        }, @[@"Default.png"]);
        check(!LC32BundleUsesDeclaredLandscapePhoneCanvasInPhoneIdiom(
                  bundle, 0x00070000, YES),
              "portrait-declaring-bundle-does-not-qualify");
        LC32TestDiscardBundle(bundle);

        bundle = LC32TestBundleWithInfo(universalLandscape, @[]);
        check(!LC32BundleUsesDeclaredLandscapePhoneCanvasInPhoneIdiom(
                  bundle, 0x00070000, YES),
              "missing-phone-launch-art-does-not-qualify");
        LC32TestDiscardBundle(bundle);

        bundle = LC32TestBundleWithInfo(@{
            @"UIDeviceFamily": @[@1, @2],
        }, @[@"Default.png"]);
        check(!LC32BundleUsesDeclaredLandscapePhoneCanvasInPhoneIdiom(
                  bundle, 0x00070000, YES),
              "keyless-universal-bundle-does-not-qualify");
        LC32TestDiscardBundle(bundle);

        bundle = LC32TestBundleWithInfo(@{
            @"UIDeviceFamily": @[@1, @2],
            @"UIInterfaceOrientation":
                @"UIInterfaceOrientationLandscapeRight",
        }, @[@"Default.png"]);
        check(LC32BundleUsesDeclaredLandscapePhoneCanvasInPhoneIdiom(
                  bundle, 0x00070000, YES),
              "initial-orientation-key-declares-landscape-policy");
        LC32TestDiscardBundle(bundle);

        /* Strictly additive: phone-only bundles never enter the new class,
         * and the populations of the existing classes are unchanged. */
        bundle = LC32TestBundleWithInfo(@{
            @"UIDeviceFamily": @[@1],
            @"UISupportedInterfaceOrientations":
                @[@"UIInterfaceOrientationLandscapeRight"],
        }, @[@"Default.png"]);
        check(!LC32BundleUsesDeclaredLandscapePhoneCanvasInPhoneIdiom(
                  bundle, 0x00070000, YES),
              "phone-only-bundle-stays-out-of-declared-class");
        check(LC32BundleUsesFixedLandscapePhoneCanvas(bundle, 0x00070000),
              "phone-only-bundle-keeps-plist-canvas-class");
        LC32TestDiscardBundle(bundle);

        bundle = LC32TestBundleWithInfo(@{
            @"UIDeviceFamily": @[@1],
            @"UISupportedInterfaceOrientations": @[
                @"UIInterfaceOrientationLandscapeLeft",
                @"UIInterfaceOrientationLandscapeRight",
            ],
        }, @[@"Default.png"]);
        check(!LC32BundleUsesDeclaredLandscapePhoneCanvasInPhoneIdiom(
                  bundle, 0x00070000, YES),
              "both-sides-phone-only-stays-out-of-declared-class");
        check(!LC32BundleUsesFixedLandscapePhoneCanvas(bundle, 0x00070000),
              "both-sides-phone-only-stays-unclassified");
        LC32TestDiscardBundle(bundle);

        bundle = LC32TestBundleWithInfo(@{
            @"UIDeviceFamily": @[@2],
            @"UISupportedInterfaceOrientations~ipad": @[
                @"UIInterfaceOrientationLandscapeLeft",
                @"UIInterfaceOrientationLandscapeRight",
            ],
        }, @[@"Default-Portrait~ipad.png"]);
        check(!LC32BundleUsesDeclaredLandscapePhoneCanvasInPhoneIdiom(
                  bundle, 0x00070000, YES),
              "pad-only-bundle-does-not-qualify");
        LC32TestDiscardBundle(bundle);

        /* Fit math: a canonical portrait 320x480 canvas fitted into the
         * live viewport expressed in the canvas' own coordinate space. For
         * the classic tall portrait scene the canvas' short edge binds:
         * scale 440/320 == 1.375, full width, centered vertical bars. */
        const CGAffineTransform plus = LC32PhoneCanvasFitTransform(
            CGRectMake(0, 0, 440, 956), 320, 480);
        check(closeTransform(plus, 1.375, 0, 0, 1.375, 0, 148),
              "tall-viewport-scales-canvas-to-fill-width");
        check(closeScalar(
                  CGRectGetWidth(CGRectApplyAffineTransform(
                      CGRectMake(0, 0, 320, 480), plus)), 440) &&
              closeScalar(
                  CGRectGetHeight(CGRectApplyAffineTransform(
                      CGRectMake(0, 0, 320, 480), plus)), 660),
              "tall-viewport-canvas-keeps-exact-3-2-aspect");

        /* The 16:9 classic viewport letterboxes at exactly 1x. */
        const CGAffineTransform classic = LC32PhoneCanvasFitTransform(
            CGRectMake(0, 0, 320, 568), 320, 480);
        check(closeTransform(classic, 1, 0, 0, 1, 0, 44),
              "classic-viewport-letterboxes-at-1x");

        /* A landscape-ordered viewport (a rotated presentation of the same
         * tall scene) pairs the canvas' long edge with the short axis
         * instead and never crops: the MIN fit stays uniform. */
        const CGAffineTransform turned = LC32PhoneCanvasFitTransform(
            CGRectMake(0, 0, 956, 440), 320, 480);
        const CGFloat turnedScale = MIN((CGFloat)440 / 480,
                                        (CGFloat)956 / 320);
        check(closeTransform(turned, turnedScale, 0, 0, turnedScale,
                  478 - turnedScale * 160, 220 - turnedScale * 240),
              "rotated-viewport-derives-scale-from-the-paired-axes");
        check(closeScalar(
                  CGRectGetWidth(CGRectApplyAffineTransform(
                      CGRectMake(0, 0, 320, 480), turned)),
                  320 * turnedScale) &&
              closeScalar(
                  CGRectGetHeight(CGRectApplyAffineTransform(
                      CGRectMake(0, 0, 320, 480), turned)),
                  480 * turnedScale),
              "rotated-viewport-never-stretches-the-canvas");

        /* The fitted canvas stays centered on the viewport midpoint for
         * every aspect, and always fills the binding axis. */
        const CGRect tall = CGRectMake(0, 0, 440, 956);
        const CGAffineTransform tallFit =
            LC32PhoneCanvasFitTransform(tall, 320, 480);
        const CGRect presented = CGRectApplyAffineTransform(
            CGRectMake(0, 0, 320, 480), tallFit);
        check(closeScalar(CGRectGetMidX(presented), CGRectGetMidX(tall)) &&
              closeScalar(CGRectGetMidY(presented), CGRectGetMidY(tall)),
              "fitted-canvas-is-centered-on-the-viewport");
        check(CGRectContainsRect(tall, presented),
              "fitted-canvas-stays-inside-the-viewport");

        /* Degenerate and non-finite viewports fall back to the identity. */
        check(CGAffineTransformIsIdentity(
                  LC32PhoneCanvasFitTransform(CGRectZero, 320, 480)),
              "zero-viewport-is-identity");
        check(CGAffineTransformIsIdentity(
                  LC32PhoneCanvasFitTransform(
                      CGRectMake(0, 0, NAN, 480), 320, 480)),
              "non-finite-viewport-is-identity");
        check(CGAffineTransformIsIdentity(
                  LC32PhoneCanvasFitTransform(
                      CGRectMake(0, 0, 440, 480), 0, 480)),
              "degenerate-canvas-is-identity");

        printf("uikit-legacy-canvas-fit: %u checks, %u failures\n",
               checks, failures);
        return failures != 0;
    }
}
