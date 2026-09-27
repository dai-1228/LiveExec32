#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

/*
 * Run in an SDK-7 universal .app declaring both landscape orientations,
 * initial LandscapeRight, and a hidden status bar. The landscape-only bundle
 * policy also applies before controller orientation callbacks are safe. Both
 * device families, without exclusively iPad launch art, avoid fixed canvases.
 * Inject the ordinary arm64 launcher with lipo; no test-only host hook is used.
 */

@interface NSObject (LC32RootGeometryTest)
- (uint64_t)host_self;
@end
extern uint64_t LC32GetHostSelector(SEL selector);
extern uint64_t LC32InvokeHostSelector(uint64_t object,
                                       uint64_t selector, ...);
extern id LC32HostToGuestObject(uint64_t hostObject);

static int failures;

static void report(const char *name, BOOL passed) {
    printf("legacy-root-geometry-%s: %s\n", name, passed ? "PASS" : "FAIL");
    failures += !passed;
}

static BOOL closeScalar(CGFloat a, CGFloat b) {
    return isfinite(a) && isfinite(b) && fabs(a - b) < 0.01;
}

static BOOL closePoint(CGPoint a, CGPoint b) {
    return closeScalar(a.x, b.x) && closeScalar(a.y, b.y);
}

static BOOL closeRect(CGRect a, CGRect b) {
    return closePoint(a.origin, b.origin) &&
        closeScalar(a.size.width, b.size.width) &&
        closeScalar(a.size.height, b.size.height);
}

static BOOL closeTransform(CGAffineTransform a, CGAffineTransform b) {
    return closeScalar(a.a, b.a) && closeScalar(a.b, b.b) &&
        closeScalar(a.c, b.c) && closeScalar(a.d, b.d) &&
        closeScalar(a.tx, b.tx) && closeScalar(a.ty, b.ty);
}

static UIInterfaceOrientation nativeSceneOrientation(UIWindow *window) {
    /* UIWindowScene is newer than the guest SDK. Query the ordinary native
     * key path through the already-mapped window: a raw native UIWindowScene
     * is not itself a registered receiver for the guest selector bridge. */
    NSString *key = @"windowScene.interfaceOrientation";
    const uint64_t result = LC32InvokeHostSelector([window host_self],
        LC32GetHostSelector(@selector(valueForKeyPath:)),
        [key host_self], (uint64_t)0);
    return (UIInterfaceOrientation)[LC32HostToGuestObject(result) integerValue];
}

@interface LC32RootGeometryRenderer : UIView
@end
@implementation LC32RootGeometryRenderer
+ (Class)layerClass {
    return [CAEAGLLayer class];
}
@end

@interface LC32RootGeometryController : UIViewController
@end
@implementation LC32RootGeometryController
- (void)loadView {
    const CGSize size = [[UIScreen mainScreen] bounds].size;
    UIView *view = [[LC32RootGeometryRenderer alloc] initWithFrame:
        CGRectMake(0, 0, MAX(size.width, size.height),
            MIN(size.width, size.height))];
    [self setView:view];
    [view release];
}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscapeRight;
}
- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation {
    return UIInterfaceOrientationLandscapeRight;
}
@end

@interface LC32RootGeometryDelegate : NSObject <UIApplicationDelegate> {
    LC32RootGeometryController *_controller;
    UIView *_nestedRenderer;
    NSUInteger _waitCount;
    NSUInteger _stableCount;
    NSUInteger _caseIndex;
    BOOL _configuredWindow;
    CGRect _lastWindowBounds;
    CGRect _expectedBounds;
    CGPoint _expectedCenter;
    CGAffineTransform _expectedTransform;
    CGRect _nestedBounds;
    CGPoint _nestedCenter;
    CGAffineTransform _nestedTransform;
}
@property(nonatomic, retain) UIWindow *window;
@end

@implementation LC32RootGeometryDelegate
@synthesize window = _window;

- (void)applicationDidFinishLaunching:(UIApplication *)application {
    const CGSize size = [[UIScreen mainScreen] bounds].size;
    const CGRect frame = CGRectMake(0, 0, MAX(size.width, size.height),
        MIN(size.width, size.height));
    self.window = [[[UIWindow alloc] initWithFrame:frame] autorelease];
    _controller = [LC32RootGeometryController new];
    [self.window setRootViewController:_controller];
    [self.window makeKeyAndVisible];

    /* Old engines install their game renderer while UIWindow already has a
     * landscape viewport but its newly attached scene can still report
     * portrait. Exercise that first installation before yielding to UIKit. */
    [application setStatusBarOrientation:UIInterfaceOrientationLandscapeRight];
    [self.window setTransform:CGAffineTransformIdentity];
    [self.window setFrame:frame];
    [self.window setBounds:frame];
    LC32RootGeometryController *earlyRoot = [LC32RootGeometryController new];
    UIView *earlyView = [earlyRoot view];
    [earlyView setCenter:CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame))];
    [earlyView setAutoresizingMask:UIViewAutoresizingNone];
    [earlyView setTransform:CGAffineTransformMake(0, 1, -1, 0, 0, 0)];
    [earlyView setBounds:frame];
    const UIInterfaceOrientation nativeApplicationOrientation =
        (UIInterfaceOrientation)LC32InvokeHostSelector([application host_self],
            LC32GetHostSelector(@selector(statusBarOrientation)), (uint64_t)0);
    fprintf(stderr, "Early root install: scene=%ld app=%ld key=%d window=%gx%g\n",
        (long)nativeSceneOrientation(self.window),
        (long)nativeApplicationOrientation, [self.window isKeyWindow],
        (double)[self.window bounds].size.width,
        (double)[self.window bounds].size.height);
    [self.window addSubview:earlyView];
    [self.window setRootViewController:earlyRoot];
    [_controller release];
    _controller = earlyRoot;
    [NSTimer scheduledTimerWithTimeInterval:0.1 target:self
        selector:@selector(waitForLandscape:) userInfo:nil repeats:YES];
}

- (void)waitForLandscape:(NSTimer *)timer {
    const CGRect bounds = [self.window bounds];
    const UIInterfaceOrientation orientation = nativeSceneOrientation(self.window);
    if(!_configuredWindow && orientation == UIInterfaceOrientationLandscapeRight &&
            bounds.size.width > 0 && bounds.size.height > 0) {
        /* Model the landscape window an old renderer owns, after the actual
         * scene settles. This fixture must not depend on legacy launch sizing. */
        const CGRect landscape = CGRectMake(0, 0,
            MAX(bounds.size.width, bounds.size.height),
            MIN(bounds.size.width, bounds.size.height));
        [self.window setTransform:CGAffineTransformIdentity];
        [self.window setFrame:landscape];
        [self.window setBounds:landscape];
        _lastWindowBounds = landscape;
        _configuredWindow = YES;
        return;
    }
    const BOOL ready = _configuredWindow &&
        orientation == UIInterfaceOrientationLandscapeRight &&
        bounds.size.width > bounds.size.height && bounds.size.height > 0 &&
        closeTransform([self.window transform], CGAffineTransformIdentity);
    _stableCount = ready && closeRect(bounds, _lastWindowBounds)
        ? _stableCount + 1 : 0;
    _lastWindowBounds = bounds;
    if(_stableCount >= 2) {
        [timer invalidate];
        report("landscape-scene-ready", YES);
        UIView *earlyView = [_controller view];
        const BOOL earlyPassed = closeRect([earlyView bounds], bounds) &&
            closePoint([earlyView center], CGPointMake(
                CGRectGetMidX(bounds), CGRectGetMidY(bounds))) &&
            closeTransform([earlyView transform], CGAffineTransformIdentity);
        report("early-root-installation-normalized", earlyPassed);
        if(!earlyPassed) {
            const CGRect earlyBounds = [earlyView bounds];
            const CGPoint earlyCenter = [earlyView center];
            const CGAffineTransform earlyTransform = [earlyView transform];
            fprintf(stderr, "Early root: bounds=(%g,%g;%g,%g) center=(%g,%g) "
                "transform=(%g,%g,%g,%g,%g,%g)\n",
                (double)earlyBounds.origin.x, (double)earlyBounds.origin.y,
                (double)earlyBounds.size.width, (double)earlyBounds.size.height,
                (double)earlyCenter.x, (double)earlyCenter.y,
                (double)earlyTransform.a, (double)earlyTransform.b,
                (double)earlyTransform.c, (double)earlyTransform.d,
                (double)earlyTransform.tx, (double)earlyTransform.ty);
        }
        _nestedRenderer = [[LC32RootGeometryRenderer alloc] initWithFrame:bounds];
        [[_controller view] addSubview:_nestedRenderer];
        [_nestedRenderer setTransform:CGAffineTransformMake(0, 1, -1, 0, 0, 0)];
        [_nestedRenderer setBounds:bounds];
        [_nestedRenderer setCenter:CGPointMake(
            CGRectGetMidX(bounds), CGRectGetMidY(bounds))];
        _nestedBounds = [_nestedRenderer bounds];
        _nestedCenter = [_nestedRenderer center];
        _nestedTransform = [_nestedRenderer transform];
        [self configureCase];
    } else if(++_waitCount >= 100) {
        [timer invalidate];
        fprintf(stderr, "Root fixture never settled: scene=%ld window=%gx%g\n",
            (long)orientation, (double)bounds.size.width,
            (double)bounds.size.height);
        report("landscape-scene-ready", NO);
        [self finish];
    }
}

- (void)configureCase {
    LC32RootGeometryController *replacement = _caseIndex == 6
        ? [LC32RootGeometryController new] : nil;
    UIView *view = [replacement ?: _controller view];
    const CGRect windowBounds = [self.window bounds];
    const CGRect portraitBounds = CGRectMake(0, 0,
        MIN(windowBounds.size.width, windowBounds.size.height),
        MAX(windowBounds.size.width, windowBounds.size.height));
    const CGPoint center = CGPointMake(
        CGRectGetMidX(windowBounds), CGRectGetMidY(windowBounds));
    [view setTransform:CGAffineTransformIdentity];
    [view setBounds:_caseIndex == 4 ? portraitBounds : windowBounds];
    [view setCenter:center];
    [view setAutoresizingMask:UIViewAutoresizingNone];

    CGRect bounds = windowBounds;
    CGAffineTransform transform = CGAffineTransformMake(0, 1, -1, 0, 0, 0);
    if(_caseIndex == 1) bounds.size.width *= 0.75;
    if(_caseIndex == 2) transform = CGAffineTransformMake(0, -1, 1, 0, 0, 0);
    if(_caseIndex == 3) transform = CGAffineTransformMakeRotation(0.35);
    if(_caseIndex == 4 || _caseIndex == 5) bounds = portraitBounds;
    _expectedBounds = bounds;
    _expectedCenter = center;
    _expectedTransform = _caseIndex == 0 || replacement
        ? CGAffineTransformIdentity : transform;

    /* Unity-era OrientView writes these in this order and does not recenter.
     * Correction must observe the completed pair, not stale intermediate size. */
    [view setTransform:transform];
    /* Explicitly retract a landscape request before the queued correction.
     * The final portrait canvas belongs to the renderer's projection. */
    if(_caseIndex == 5) [view setBounds:windowBounds];
    [view setBounds:bounds];
    if(replacement) {
        /* The first renderer root can establish its old transform and size
         * before UIKit attaches it. Installation must retain that size intent
         * even if modern UIKit changes bounds during the root transition. */
        LC32RootGeometryController *previous = _controller;
        _controller = replacement;
        [self.window setRootViewController:replacement];
        [previous release];
    }
    [NSTimer scheduledTimerWithTimeInterval:0.2 target:self
        selector:@selector(checkCase:) userInfo:nil repeats:NO];
}

- (void)checkCase:(NSTimer *)timer {
    (void)timer;
    static const char *const names[] = {
        "full-root-turn-normalized", "partial-bounds-preserved",
        "opposite-turn-preserved", "arbitrary-angle-preserved",
        "portrait-canvas-turn-preserved", "portrait-request-clears-landscape-intent",
        "geometry-before-root-installation-normalized",
    };
    UIView *view = [_controller view];
    const BOOL passed = closeRect([view bounds], _expectedBounds) &&
        closePoint([view center], _expectedCenter) &&
        closeTransform([view transform], _expectedTransform);
    report(names[_caseIndex], passed);
    if(!passed) {
        const CGRect bounds = [view bounds];
        const CGPoint center = [view center];
        const CGAffineTransform transform = [view transform];
        fprintf(stderr, "Root case %lu: bounds=(%g,%g;%g,%g) center=(%g,%g) "
            "transform=(%g,%g,%g,%g,%g,%g)\n", (unsigned long)_caseIndex,
            (double)bounds.origin.x, (double)bounds.origin.y,
            (double)bounds.size.width, (double)bounds.size.height,
            (double)center.x, (double)center.y, (double)transform.a,
            (double)transform.b, (double)transform.c, (double)transform.d,
            (double)transform.tx, (double)transform.ty);
    }
    if(_caseIndex == 0) {
        report("nested-renderer-preserved",
            closeRect([_nestedRenderer bounds], _nestedBounds) &&
            closePoint([_nestedRenderer center], _nestedCenter) &&
            closeTransform([_nestedRenderer transform], _nestedTransform));
    }
    if(++_caseIndex < sizeof(names) / sizeof(names[0])) [self configureCase];
    else [self finish];
}

- (void)finish {
    printf("legacy-root-geometry-regression: %s\n", failures ? "FAIL" : "PASS");
    exit(failures != 0);
}

- (void)dealloc {
    [_nestedRenderer release];
    [_controller release];
    [_window release];
    [super dealloc];
}
@end

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil,
            NSStringFromClass([LC32RootGeometryDelegate class]));
    }
}
