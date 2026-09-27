// Exercise the shared runtime-declared canvas classifier and the fixed
// canvas presentation math from the real include/LC32LegacyCanvas.h (the
// canvas model's single source of truth). Everything here is deterministic
// pure math, so no UIKit is needed; the host adapter and the guest UIScreen
// overrides both consume these inlines.
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
