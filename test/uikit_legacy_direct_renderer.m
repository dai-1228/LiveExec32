#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <LC32/LC32.h>

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

/*
 * Rootless pre-controller renderer fixture. Use a phone-only .app with
 * Default.png, no tall launch image, UIStatusBarHidden=YES, and initial
 * UIInterfaceOrientationLandscapeRight; omit UISupportedInterfaceOrientations.
 * For the SDK-zero case, apply vtool -set-version-min ios 7.0 0.0 -replace
 * to the guest executable before injecting the normal arm64 shim with lipo.
 *
 * The direct EAGL-backed child starts with flexible width AND height. Modern
 * UIKit must not resize its portrait drawable while installing the inert
 * native root and transitioning the window into a landscape scene. Only
 * presentation may be corrected; the renderer is never reparented. Explicit
 * guest autoresizing and a real guest root must supersede that preservation.
 * All operations use ordinary UIKit APIs, with no production test hooks.
 */

static int failures;
static BOOL checkingSynchronousLayout;
static NSUInteger synchronousLayouts;
static const UIViewAutoresizing flexibleSize =
    UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

static void report(const char *name, BOOL passed) {
    printf("legacy-direct-renderer-%s: %s\n", name, passed ? "PASS" : "FAIL");
    failures += !passed;
}

static BOOL closeScalar(CGFloat a, CGFloat b) {
    return isfinite(a) && isfinite(b) && fabs(a - b) < 0.01;
}

static BOOL closePoint(CGPoint a, CGPoint b) {
    return closeScalar(a.x, b.x) && closeScalar(a.y, b.y);
}

static BOOL identityTransform(CGAffineTransform value) {
    return closeScalar(value.a, 1) && closeScalar(value.b, 0) &&
        closeScalar(value.c, 0) && closeScalar(value.d, 1) &&
        closeScalar(value.tx, 0) && closeScalar(value.ty, 0);
}

static UIInterfaceOrientation nativeSceneOrientation(UIWindow *window) {
    NSString *key = @"windowScene.interfaceOrientation";
    NSNumber *result = LC32InvokeHostObjectSelector([window host_self],
        LC32GetHostSelector(@selector(valueForKeyPath:)),
        [key host_self], (uint64_t)0);
    return (UIInterfaceOrientation)[result integerValue];
}

@interface LC32DirectRendererView : UIView
@end
@implementation LC32DirectRendererView
+ (Class)layerClass {
    return [CAEAGLLayer class];
}
- (void)layoutSubviews {
    if(checkingSynchronousLayout) ++synchronousLayouts;
    [super layoutSubviews];
}
@end

@interface LC32DirectRendererRoot : UIViewController
@end
@implementation LC32DirectRendererRoot
- (void)loadView {
    self.view = [[[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 480)]
        autorelease];
}
@end

@interface LC32DirectRendererDelegate : NSObject <UIApplicationDelegate> {
    LC32DirectRendererView *_renderer;
    UIView *_overlay;
    NSUInteger _waitCount;
    NSUInteger _stableCount;
    CGRect _lastBounds;
    BOOL _configuredWindow;
}
@property(nonatomic, retain) UIWindow *window;
@end

@implementation LC32DirectRendererDelegate
@synthesize window = _window;

- (void)applicationDidFinishLaunching:(UIApplication *)application {
    const CGRect canvas = CGRectMake(0, 0, 320, 480);
    self.window = [[[UIWindow alloc] initWithFrame:canvas] autorelease];
    _renderer = [[LC32DirectRendererView alloc] initWithFrame:canvas];
    [_renderer setAutoresizingMask:flexibleSize];
    _overlay = [[UIView alloc] initWithFrame:CGRectMake(13, 17, 60, 30)];
    report("portrait-precondition",
        CGRectEqualToRect([self.window bounds], canvas) &&
        CGRectEqualToRect([_renderer bounds], canvas) &&
        [_renderer autoresizingMask] == flexibleSize);
    checkingSynchronousLayout = YES;
    [self.window addSubview:_renderer];
    [self.window addSubview:_overlay];
    [self.window makeKeyAndVisible];
    checkingSynchronousLayout = NO;
    report("no-synchronous-renderer-layout", synchronousLayouts == 0);
    report("synthetic-root-freezes-flexible-mask",
        [_renderer autoresizingMask] == UIViewAutoresizingNone);
    report("initial-drawable-preserved",
        CGRectEqualToRect([_renderer bounds], canvas) &&
        closePoint([_renderer center], CGPointMake(160, 240)));
    [application setStatusBarOrientation:UIInterfaceOrientationLandscapeRight];
    [NSTimer scheduledTimerWithTimeInterval:0.1 target:self
        selector:@selector(waitForLandscape:) userInfo:nil repeats:YES];
}

- (void)waitForLandscape:(NSTimer *)timer {
    const CGRect bounds = [self.window bounds];
    const UIInterfaceOrientation orientation = nativeSceneOrientation(self.window);
    if(!_configuredWindow && orientation == UIInterfaceOrientationLandscapeRight) {
        /* Isolate the legacy 480x320 native viewport from the simulator's
         * physical screen dimensions. Do not touch any child geometry, or
         * overwrite an already fitted landscape window's presentation. */
        const CGRect viewport = CGRectMake(0, 0, 480, 320);
        if(!CGRectEqualToRect(bounds, viewport)) {
            [self.window setTransform:CGAffineTransformIdentity];
            [self.window setFrame:viewport];
            [self.window setBounds:viewport];
        }
        _lastBounds = viewport;
        _configuredWindow = YES;
        return;
    }
    const BOOL ready = _configuredWindow &&
        orientation == UIInterfaceOrientationLandscapeRight &&
        CGRectEqualToRect(bounds, CGRectMake(0, 0, 480, 320));
    _stableCount = ready && CGRectEqualToRect(bounds, _lastBounds)
        ? _stableCount + 1 : 0;
    _lastBounds = bounds;
    if(_stableCount >= 2) {
        [timer invalidate];
        report("landscape-ready", YES);
        [self finish:nil];
    } else if(++_waitCount >= 100) {
        [timer invalidate];
        report("landscape-ready", NO);
        [self finish:nil];
    }
}

- (void)finish:(NSTimer *)timer {
    (void)timer;
    const CGRect canvas = CGRectMake(0, 0, 320, 480);
    report("guest-root-remains-nil", [self.window rootViewController] == nil);
    report("direct-siblings-preserved",
        [_renderer superview] == self.window &&
        [_overlay superview] == self.window &&
        [[self.window subviews] indexOfObjectIdenticalTo:_renderer] <
            [[self.window subviews] indexOfObjectIdenticalTo:_overlay]);
    report("portrait-drawable-preserved",
        CGRectEqualToRect([_renderer bounds], canvas) &&
        closePoint([_renderer center], CGPointMake(160, 240)) &&
        identityTransform([_renderer transform]));
    report("overlay-geometry-preserved",
        CGRectEqualToRect([_overlay frame], CGRectMake(13, 17, 60, 30)) &&
        [_overlay autoresizingMask] == UIViewAutoresizingNone &&
        identityTransform([_overlay transform]));
    report("mask-remains-frozen",
        [_renderer autoresizingMask] == UIViewAutoresizingNone);
    const CGPoint origin = [_renderer convertPoint:CGPointZero toView:self.window];
    const CGPoint x = [_renderer convertPoint:CGPointMake(1, 0) toView:self.window];
    const CGPoint y = [_renderer convertPoint:CGPointMake(0, 1) toView:self.window];
    fprintf(stderr, "Direct portrait renderer: bounds=%gx%g mask=%lu "
        "origin=(%g,%g) x-axis=(%g,%g) y-axis=(%g,%g)\n",
        (double)[_renderer bounds].size.width,
        (double)[_renderer bounds].size.height,
        (unsigned long)[_renderer autoresizingMask],
        (double)origin.x, (double)origin.y,
        (double)(x.x - origin.x), (double)(x.y - origin.y),
        (double)(y.x - origin.x), (double)(y.y - origin.y));
    report("right-compositor-coordinate-contract",
        closePoint(origin, CGPointMake(0, 320)) &&
        closePoint(x, CGPointMake(0, 319)) &&
        closePoint(y, CGPointMake(1, 320)));
    report("touch-conversion-contract", closePoint(
        [_renderer convertPoint:CGPointMake(120, 280) fromView:self.window],
        CGPointMake(40, 120)));
    [self.window makeKeyAndVisible];
    [self.window makeKeyAndVisible];
    report("repeated-fitting-idempotent",
        CGRectEqualToRect([_renderer bounds], canvas) &&
        [_renderer autoresizingMask] == UIViewAutoresizingNone &&
        closePoint([_renderer convertPoint:CGPointZero toView:self.window],
                   CGPointMake(0, 320)));

    LC32DirectRendererRoot *root = [LC32DirectRendererRoot new];
    [self.window setRootViewController:root];
    report("guest-root-handoff-restores-original-mask",
        [_renderer autoresizingMask] == flexibleSize);
    report("guest-root-handoff-visible", [self.window rootViewController] == root);
    [root release];

    /* A separate window avoids relying on re-capturing an already managed
     * renderer. Explicit guest mask changes transfer ownership immediately. */
    UIWindow *authoredWindow = [[UIWindow alloc] initWithFrame:canvas];
    LC32DirectRendererView *authoredRenderer =
        [[LC32DirectRendererView alloc] initWithFrame:canvas];
    [authoredRenderer setAutoresizingMask:flexibleSize];
    [authoredWindow addSubview:authoredRenderer];
    [authoredWindow makeKeyAndVisible];
    report("second-window-captured",
        [authoredRenderer autoresizingMask] == UIViewAutoresizingNone);
    const UIViewAutoresizing authoredMask = UIViewAutoresizingFlexibleLeftMargin;
    [authoredRenderer setAutoresizingMask:authoredMask];
    [authoredWindow makeKeyAndVisible];
    [authoredWindow makeKeyAndVisible];
    report("guest-authored-mask-preserved",
        [authoredRenderer autoresizingMask] == authoredMask);
    root = [LC32DirectRendererRoot new];
    [authoredWindow setRootViewController:root];
    report("handoff-preserves-guest-authored-mask",
        [authoredRenderer autoresizingMask] == authoredMask);
    [root release];
    [authoredRenderer release];
    [authoredWindow release];

    /* Writing the already-frozen value is still an explicit ownership
     * decision. Use a fresh window so a previous nonzero write cannot make
     * this test pass merely by having relinquished ownership earlier. */
    UIWindow *noneWindow = [[UIWindow alloc] initWithFrame:canvas];
    LC32DirectRendererView *noneRenderer =
        [[LC32DirectRendererView alloc] initWithFrame:canvas];
    [noneRenderer setAutoresizingMask:flexibleSize];
    [noneWindow addSubview:noneRenderer];
    [noneWindow makeKeyAndVisible];
    report("explicit-none-window-captured",
        [noneRenderer autoresizingMask] == UIViewAutoresizingNone);
    [noneRenderer setAutoresizingMask:UIViewAutoresizingNone];
    [noneWindow makeKeyAndVisible];
    root = [LC32DirectRendererRoot new];
    [noneWindow setRootViewController:root];
    report("handoff-preserves-explicit-none",
        [noneRenderer autoresizingMask] == UIViewAutoresizingNone);
    [root release];
    [noneRenderer release];
    [noneWindow release];

    /* The old window still owns a pending restore record after removal.
     * A detached guest write must relinquish that record even though the
     * renderer no longer has a window through which to find it. */
    UIWindow *detachedWindow = [[UIWindow alloc] initWithFrame:canvas];
    LC32DirectRendererView *detachedRenderer =
        [[LC32DirectRendererView alloc] initWithFrame:canvas];
    [detachedRenderer setAutoresizingMask:flexibleSize];
    [detachedWindow addSubview:detachedRenderer];
    [detachedWindow makeKeyAndVisible];
    report("detached-none-window-captured",
        [detachedRenderer autoresizingMask] == UIViewAutoresizingNone);
    [detachedRenderer removeFromSuperview];
    [detachedRenderer setAutoresizingMask:UIViewAutoresizingNone];
    root = [LC32DirectRendererRoot new];
    [detachedWindow setRootViewController:root];
    report("old-window-handoff-preserves-detached-none",
        [detachedRenderer superview] == nil &&
        [detachedRenderer autoresizingMask] == UIViewAutoresizingNone);
    [root release];
    [detachedRenderer release];
    [detachedWindow release];

    /* Without an authored write, detaching should restore the saved mask on
     * the next normal fitting opportunity; immediate removal is not required. */
    UIWindow *removedWindow = [[UIWindow alloc] initWithFrame:canvas];
    LC32DirectRendererView *removedRenderer =
        [[LC32DirectRendererView alloc] initWithFrame:canvas];
    [removedRenderer setAutoresizingMask:flexibleSize];
    [removedWindow addSubview:removedRenderer];
    [removedWindow makeKeyAndVisible];
    report("removal-only-window-captured",
        [removedRenderer autoresizingMask] == UIViewAutoresizingNone);
    [removedRenderer removeFromSuperview];
    [removedWindow makeKeyAndVisible];
    report("removal-only-restores-mask-on-next-fit",
        [removedRenderer superview] == nil &&
        [removedRenderer autoresizingMask] == flexibleSize);
    [removedRenderer release];
    [removedWindow release];
    printf("legacy-direct-renderer-regression: %s\n", failures ? "FAIL" : "PASS");
    exit(failures != 0);
}
@end

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil,
            NSStringFromClass([LC32DirectRendererDelegate class]));
    }
}
