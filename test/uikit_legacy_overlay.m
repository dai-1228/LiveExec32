#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

#include <math.h>
#include <stdio.h>
#include <stdlib.h>

/*
 * Run this UIApplication fixture from a phone-only .app whose Info.plist
 * declares initial UIInterfaceOrientationLandscapeRight, all four supported
 * orientations, and UIStatusBarHidden=YES. The guest root restricts the scene
 * to landscape right; the broad bundle mask excludes fixed-phone canvases.
 * Inject the normal arm64 shim into the executable with lipo, as for other
 * UI fixtures. The target deliberately advertises SDK 7.0: this exercises
 * pre-iOS-8 portrait-window conventions, not a production test override.
 */

static int failures;

static void report(const char *name, BOOL passed) {
    printf("legacy-overlay-%s: %s\n", name, passed ? "PASS" : "FAIL");
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

@interface LC32OverlayView : UIView
@end
@implementation LC32OverlayView
@end

@interface LC32OverlayRenderer : UIView
@end
@implementation LC32OverlayRenderer
+ (Class)layerClass {
    return [CAEAGLLayer class];
}
@end

@interface LC32OverlayController : UIViewController
@end
@implementation LC32OverlayController
- (void)loadView {
    LC32OverlayView *view = [[LC32OverlayView alloc]
        initWithFrame:CGRectMake(0, 0, 956, 440)];
    self.view = view;
    [view release];
}
- (BOOL)shouldAutorotateToInterfaceOrientation:
        (UIInterfaceOrientation)orientation {
    return orientation == UIInterfaceOrientationLandscapeRight;
}
@end

typedef struct {
    const char *name;
    UIView *view;
    CGRect bounds;
    CGPoint center;
    CGAffineTransform transform;
} OverlayCase;

@interface LC32OverlayDelegate : NSObject <UIApplicationDelegate> {
    NSMutableArray *_controllers;
    OverlayCase _cases[12];
    NSUInteger _caseCount;
    NSUInteger _waitCount;
    NSUInteger _stableCount;
    BOOL _configuredWindowGeometry;
    CGRect _lastWindowBounds;
    UIView *_preservedChild;
    CGRect _childBounds;
    CGPoint _childCenter;
    CGAffineTransform _childTransform;
}
@property(nonatomic, retain) UIWindow *window;
@end

@implementation LC32OverlayDelegate
@synthesize window = _window;

- (LC32OverlayController *)newController {
    LC32OverlayController *controller = [LC32OverlayController new];
    [_controllers addObject:controller];
    [controller release];
    return controller;
}

- (void)addCase:(const char *)name view:(UIView *)view
        bounds:(CGRect)bounds center:(CGPoint)center
        transform:(CGAffineTransform)transform {
    if(_caseCount == sizeof(_cases) / sizeof(_cases[0])) abort();
    _cases[_caseCount++] = (OverlayCase){
        name, view, bounds, center, transform,
    };
}

- (void)setLegacyGeometry:(UIView *)view bounds:(CGRect)bounds
        center:(CGPoint)center transform:(CGAffineTransform)transform {
    /* These three writes must settle before the coalesced native correction.
     * In particular, an eager setTransform hook must not observe stale size
     * or be undone by this subsequent portrait-window center assignment. */
    view.transform = transform;
    view.bounds = bounds;
    view.center = center;
}

- (void)applicationDidFinishLaunching:(UIApplication *)application {
    (void)application;
    _controllers = [NSMutableArray new];
    const CGSize screenSize = UIScreen.mainScreen.bounds.size;
    const CGRect initialBounds = CGRectMake(0, 0,
        MAX(screenSize.width, screenSize.height),
        MIN(screenSize.width, screenSize.height));
    self.window = [[[UIWindow alloc] initWithFrame:initialBounds]
        autorelease];
    self.window.rootViewController = [self newController];
    [self.window makeKeyAndVisible];
    [NSTimer scheduledTimerWithTimeInterval:0.1 target:self
        selector:@selector(waitForLandscape:) userInfo:nil repeats:YES];
}

- (void)waitForLandscape:(NSTimer *)timer {
    CGRect bounds = self.window.bounds;
    const UIInterfaceOrientation orientation =
        UIApplication.sharedApplication.statusBarOrientation;
    if(!_configuredWindowGeometry &&
            orientation == UIInterfaceOrientationLandscapeRight &&
            bounds.size.width > 0 && bounds.size.height > 0) {
        /* Model a game-owned landscape UIWindow explicitly. UIKit's initial
         * scene attachment can retain a portrait window for this old-SDK
         * fixture, even after the scene orientation itself has settled. */
        const CGRect landscape = CGRectMake(0, 0,
            MAX(bounds.size.width, bounds.size.height),
            MIN(bounds.size.width, bounds.size.height));
        self.window.transform = CGAffineTransformIdentity;
        self.window.frame = landscape;
        self.window.bounds = landscape;
        _configuredWindowGeometry = YES;
        _lastWindowBounds = landscape;
        return;
    }
    const BOOL ready = orientation == UIInterfaceOrientationLandscapeRight &&
        bounds.size.width > bounds.size.height &&
        bounds.size.height > 0 &&
        closeTransform(self.window.transform, CGAffineTransformIdentity);
    _stableCount = ready && closeRect(bounds, _lastWindowBounds)
        ? _stableCount + 1 : 0;
    _lastWindowBounds = bounds;
    if(_stableCount >= 2) {
        [timer invalidate];
        report("landscape-fixture-ready", YES);
        [self runCases];
    } else if(++_waitCount >= 100) {
        [timer invalidate];
        fprintf(stderr, "Overlay fixture never settled: orientation=%ld "
            "window=%gx%g. Check its bundle orientation metadata.\n",
            (long)orientation, (double)bounds.size.width,
            (double)bounds.size.height);
        report("landscape-fixture-ready", NO);
        [self finish:nil];
    }
}

- (void)runCases {
    const CGRect bounds = self.window.bounds;
    const CGPoint nativeCenter = CGPointMake(
        CGRectGetMidX(bounds), CGRectGetMidY(bounds));
    const CGPoint legacyCenter = CGPointMake(
        bounds.origin.x + bounds.size.height * 0.5,
        bounds.origin.y + bounds.size.width * 0.5);
    const CGAffineTransform turn = CGAffineTransformMake(0, 1, -1, 0, 0, 0);

    for(NSUInteger index = 0; index < 2; ++index) {
        UIView *view = [self newController].view;
        if(index == 0) [self.window addSubview:view];
        [self setLegacyGeometry:view bounds:bounds center:legacyCenter
            transform:turn];
        if(index == 1) [self.window addSubview:view];
        [self addCase:index == 0 ? "mutate-after-insertion" :
            "mutate-before-insertion" view:view bounds:bounds
            center:nativeCenter transform:CGAffineTransformIdentity];
        if(index == 0) {
            _preservedChild = [[[LC32OverlayView alloc]
                initWithFrame:CGRectMake(13, 17, 80, 30)] autorelease];
            _preservedChild.transform =
                CGAffineTransformMake(0.8, 0.2, -0.1, 0.9, 3, 4);
            [view addSubview:_preservedChild];
            _childBounds = _preservedChild.bounds;
            _childCenter = _preservedChild.center;
            _childTransform = _preservedChild.transform;
        }
    }

    UIView *rootView = self.window.rootViewController.view;
    [self setLegacyGeometry:rootView bounds:bounds center:legacyCenter
        transform:turn];
    [self addCase:"root-preserved" view:rootView bounds:bounds
        center:legacyCenter transform:turn];

    UIView *parentView = [[[LC32OverlayView alloc]
        initWithFrame:bounds] autorelease];
    [self.window addSubview:parentView];
    UIView *nestedView = [self newController].view;
    [parentView addSubview:nestedView];
    [self setLegacyGeometry:nestedView bounds:bounds center:legacyCenter
        transform:turn];
    [self addCase:"nested-preserved" view:nestedView bounds:bounds
        center:legacyCenter transform:turn];

    LC32OverlayController *parented = [self newController];
    [self.window.rootViewController addChildViewController:parented];
    /* Keep UIKit's controller-parent invariant valid: a contained child
     * cannot be attached directly to UIWindow as though it were standalone. */
    [self.window.rootViewController.view addSubview:parented.view];
    [parented didMoveToParentViewController:self.window.rootViewController];
    [self setLegacyGeometry:parented.view bounds:bounds center:legacyCenter
        transform:turn];
    [self addCase:"contained-controller-preserved" view:parented.view
        bounds:bounds center:legacyCenter transform:turn];

    UIView *rendererContainer = [self newController].view;
    UIView *renderer = [[[LC32OverlayRenderer alloc]
        initWithFrame:CGRectMake(0, 0, 64, 64)] autorelease];
    [rendererContainer addSubview:renderer];
    [self.window addSubview:rendererContainer];
    [self setLegacyGeometry:rendererContainer bounds:bounds
        center:legacyCenter transform:turn];
    [self addCase:"renderer-subtree-preserved" view:rendererContainer
        bounds:bounds center:legacyCenter transform:turn];

    const CGAffineTransform otherTransforms[] = {
        CGAffineTransformMake(0, 0.5, -0.5, 0, 0, 0),
        CGAffineTransformMake(0, -1, 1, 0, 0, 0),
        CGAffineTransformMake(0, 1, -1, 0, 12, 0),
    };
    const char *otherNames[] = {
        "scaled-turn-preserved", "opposite-turn-preserved",
        "translated-turn-preserved",
    };
    for(NSUInteger index = 0; index < 3; ++index) {
        UIView *view = [self newController].view;
        [self.window addSubview:view];
        [self setLegacyGeometry:view bounds:bounds center:legacyCenter
            transform:otherTransforms[index]];
        [self addCase:otherNames[index] view:view bounds:bounds
            center:legacyCenter transform:otherTransforms[index]];
    }

    UIView *ownerless = [[[LC32OverlayView alloc]
        initWithFrame:bounds] autorelease];
    [self.window addSubview:ownerless];
    [self setLegacyGeometry:ownerless bounds:bounds center:legacyCenter
        transform:turn];
    [self addCase:"ownerless-view-preserved" view:ownerless bounds:bounds
        center:legacyCenter transform:turn];

    [NSTimer scheduledTimerWithTimeInterval:0.2 target:self
        selector:@selector(finish:) userInfo:nil repeats:NO];
}

- (void)finish:(NSTimer *)timer {
    (void)timer;
    for(NSUInteger index = 0; index < _caseCount; ++index) {
        const OverlayCase *test = &_cases[index];
        const BOOL passed = closeRect(test->view.bounds, test->bounds) &&
            closePoint(test->view.center, test->center) &&
            closeTransform(test->view.transform, test->transform);
        report(test->name, passed);
        if(!passed) {
            const CGRect bounds = test->view.bounds;
            const CGPoint center = test->view.center;
            const CGAffineTransform transform = test->view.transform;
            fprintf(stderr, "  actual bounds=(%g,%g;%g,%g) "
                "center=(%g,%g) transform=(%g,%g,%g,%g,%g,%g)\n",
                (double)bounds.origin.x, (double)bounds.origin.y,
                (double)bounds.size.width, (double)bounds.size.height,
                (double)center.x, (double)center.y,
                (double)transform.a, (double)transform.b,
                (double)transform.c, (double)transform.d,
                (double)transform.tx, (double)transform.ty);
        }
    }
    if(_preservedChild) {
        report("descendant-geometry-preserved",
            closeRect(_preservedChild.bounds, _childBounds) &&
            closePoint(_preservedChild.center, _childCenter) &&
            closeTransform(_preservedChild.transform, _childTransform));
    }
    printf("legacy-overlay-regression: %s\n", failures ? "FAIL" : "PASS");
    exit(failures != 0);
}

@end

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil,
            NSStringFromClass([LC32OverlayDelegate class]));
    }
}
