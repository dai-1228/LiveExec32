#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>
#import <LC32/LC32.h>

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

/*
 * End-to-end regression for the declared-universal legacy phone canvas
 * (the mfm 4.1.1 / com.turner.mfm class). Run this guest under a launcher
 * whose effective process SDK is pre-iOS-8 (LiveContainer's 2.0* fallback,
 * per-app spoofSDKVersion left unclamped, Classic Mode enabled).
 *
 * The .app must be packaged exactly like the game: UIDeviceFamily [1, 2]
 * (universal), a landscape-only generic UISupportedInterfaceOrientations
 * policy (both sides, plus the inert ~ipad variant), UIStatusBarHidden true
 * with UIViewControllerBasedStatusBarAppearance false, MinimumOSVersion 4.3,
 * and all five launch-art names present (Default.png, Default@2x.png,
 * Default-568h@2x.png, Default-Landscape~ipad.png,
 * Default-Landscape@2x~ipad.png) as zero-byte files — the classifier probes
 * paths only. The binary itself must carry LC_VERSION_MIN_IPHONEOS sdk 7.0
 * (the Makefile forces -Wl,-sdk_version,7.0; with the sysroot default of
 * 10.3 every canvas classifier answers NO and the test fails for the wrong
 * reason).
 *
 * Unlike the runtime-declared (keyless) fixture, this class is declared by
 * the plist alone: the fixture makes NO runtime status-bar call — never
 * setStatusBarOrientation: nor setStatusBarHidden: — exactly like mfm, which
 * only ever reads the orientation getter. The canvas therefore arrives
 * purely from the plist terms plus the 4-inch launch art, through the
 * LC32BundleUsesDeclaredLandscapePhoneCanvasInPhoneIdiom classifier, and the
 * engine hierarchy (window from mainScreen.bounds, a rootViewController
 * wrapping a hardcoded portrait 320x480 ES2 renderer) matches the game's:
 * CCGLView is authored {0,0,320,480} and never UIScreen-derived, and
 * resizeOnce_ stores the renderbuffer exactly once after makeKeyAndVisible.
 *
 * The presentation assertions are intentionally presentation-model agnostic:
 * the fit must be a uniform scale of the authored aspect up to transposition
 * (the rotation unit turns the window), centered on the window's midpoint,
 * and fully inside the window's hit region.
 */

static int failures;

static void report(const char *name, BOOL passed) {
    printf("declared-canvas-%s: %s\n", name, passed ? "PASS" : "FAIL");
    failures += !passed;
}

static BOOL closeScalar(CGFloat a, CGFloat b) {
    return isfinite(a) && isfinite(b) && fabs(a - b) < 0.75;
}

static BOOL exactScalar(CGFloat a, CGFloat b) {
    return isfinite(a) && isfinite(b) && fabs(a - b) < 0.01;
}

static uint32_t hostAnswer(const char *symbol) {
    const uint64_t fn = LC32Dlsym(symbol, YES);
    return fn ? LC32InvokeHostCRet32(fn) : 0;
}

/*
 * mfm's GL API is OpenGL ES 2 only (CCES2Renderer, initWithAPI:2). The
 * renderer is authored at the engine's hardcoded portrait size, never
 * UIScreen-derived, and allocates its drawable storage exactly once.
 */
@interface LC32DeclaredCanvasRenderer : UIView
@end

@implementation LC32DeclaredCanvasRenderer
+ (Class)layerClass {
    return [CAEAGLLayer class];
}
@end

/*
 * RootNavigationController declares both landscape sides and prefers
 * LandscapeRight; the programmatic loadView exercises the guest NIB-loading
 * guard path benignly (no nib in the bundle).
 */
@interface LC32DeclaredCanvasController : UIViewController {
@private
    UIView *_rendererView;
}
@end

@implementation LC32DeclaredCanvasController

- (instancetype)initWithNibName:(NSString *)nibNameOrNil
                         bundle:(NSBundle *)nibBundleOrNil {
    (void)nibNameOrNil; (void)nibBundleOrNil;
    self = [super initWithNibName:nil bundle:nil];
    return self;
}

- (void)loadView {
    /* Declared before the ivar is consumed: the authored renderer is handed
     * in via -attachRenderer: before the view is first requested. */
    if(!_rendererView) _rendererView = [[UIView alloc]
        initWithFrame:CGRectMake(0, 0, 320, 480)];
    self.view = _rendererView;
    [_rendererView release];
    _rendererView = nil;
}

- (void)attachRenderer:(UIView *)renderer {
    _rendererView = [renderer retain];
    if(self.isViewLoaded) {
        self.view = renderer;
        [_rendererView release];
        _rendererView = nil;
    }
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscapeRight |
        UIInterfaceOrientationMaskLandscapeLeft;
}

- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation {
    return UIInterfaceOrientationLandscapeRight;
}

@end

@interface LC32DeclaredCanvasDelegate : NSObject <UIApplicationDelegate> {
    UIWindow *_window;
    LC32DeclaredCanvasRenderer *_renderer;
    LC32DeclaredCanvasController *_controller;
    EAGLContext *_context;
    CGRect _initialScreenBounds;
    GLint _backingWidth;
    GLint _backingHeight;
    NSUInteger _ticks;
    NSUInteger _settledTicks;
}
@property(nonatomic, retain) UIWindow *window;
@end

@implementation LC32DeclaredCanvasDelegate
@synthesize window = _window;

- (void)applicationDidFinishLaunching:(UIApplication *)application {
    (void)application;
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;

    /* The positive of the keyless fixture's shape check: the declared keys
     * ARE the class definition, so a run against a wrong bundle fails the
     * first line instead of silently testing the wrong class. */
    BOOL shapeOK = [info[@"UIDeviceFamily"] isEqualToArray:@[@1, @2]];
    NSArray *orientations = info[@"UISupportedInterfaceOrientations"];
    shapeOK = shapeOK && [orientations isKindOfClass:NSArray.class] &&
        orientations.count > 0;
    for(NSString *orientation in orientations) {
        shapeOK = shapeOK &&
            [orientation hasPrefix:@"UIInterfaceOrientationLandscape"];
    }
    shapeOK = shapeOK &&
        [info[@"UIStatusBarHidden"] boolValue] == YES;
    shapeOK = shapeOK && [NSBundle.mainBundle
        pathForResource:@"Default-568h@2x" ofType:@"png"] != nil;
    shapeOK = shapeOK && [NSBundle.mainBundle
        pathForResource:@"Default" ofType:@"png"] != nil;
    report("declared-universal-bundle-shape", shapeOK);

    /* Preconditions on the host's live classifiers. Assertion 2 failing on
     * a device means the launcher was misconfigured (clamped effective SDK),
     * not a regression. */
    report("native-legacy-rotation-active",
        hostAnswer("LC32NativeLegacyRotationEnabled") != 0);
    report("declared-class-active",
        hostAnswer("LC32UIKitUsesNativeDeclaredLandscapePhoneCanvas") != 0);
    report("fixed-class-inactive",
        hostAnswer("LC32UIKitUsesNativeFixedPhoneCanvas") == 0);

    /* First canvas read resolves the lazy bundle snapshot. mfm derives the
     * window from mainScreen.bounds; the renderer alone is hardcoded. */
    _initialScreenBounds = [UIScreen mainScreen].bounds;
    self.window = [[[UIWindow alloc]
        initWithFrame:_initialScreenBounds] autorelease];
    _renderer = [[LC32DeclaredCanvasRenderer alloc]
        initWithFrame:CGRectMake(0, 0, 320, 480)];
    _renderer.opaque = YES;
    CAEAGLLayer *drawableLayer = (CAEAGLLayer *)_renderer.layer;
    drawableLayer.drawableProperties = @{
        kEAGLDrawablePropertyRetainedBacking: @NO,
        kEAGLDrawablePropertyColorFormat: kEAGLColorFormatRGBA8,
    };
    /* enableRetinaDisplay: contentsScale follows the screen's clamped 2.0. */
    drawableLayer.contentsScale = [UIScreen mainScreen].scale;

    _controller = [[LC32DeclaredCanvasController alloc] init];
    [_controller attachRenderer:_renderer];
    _window.rootViewController = _controller;

    /* Inside the launch delegate, exactly like the game; the rotation turn
     * finishes at first idle after this and the fit waits for it. */
    [_window makeKeyAndVisible];

    /* resizeOnce_: one-shot renderbufferStorage at first layout, i.e. after
     * the superview exists — the backing-size-protecting order. Plain ES2
     * names only (mfm is ES2-only); never re-stored. */
    _context = [[EAGLContext alloc]
        initWithAPI:kEAGLRenderingAPIOpenGLES2];
    [EAGLContext setCurrentContext:_context];
    GLuint renderbuffer = 0;
    glGenRenderbuffers(1, &renderbuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, renderbuffer);
    [_context renderbufferStorage:GL_RENDERBUFFER
                      fromDrawable:drawableLayer];
    glGetRenderbufferParameteriv(GL_RENDERBUFFER,
        GL_RENDERBUFFER_WIDTH, &_backingWidth);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER,
        GL_RENDERBUFFER_HEIGHT, &_backingHeight);

    [NSTimer scheduledTimerWithTimeInterval:0.1 target:self
        selector:@selector(tick:) userInfo:nil repeats:YES];
}

- (void)tick:(NSTimer *)timer {
    ++_ticks;
    const CGRect screenBounds = [UIScreen mainScreen].bounds;
    const CGRect rendererBounds = _renderer.bounds;
    const CGRect presented = [_renderer convertRect:rendererBounds
                                              toView:_window];
    /* The rotation unit turns the window, so the presented rect is
     * landscape-shaped; accept the authored aspect up to transposition.
     * Treat two consecutive settled readings as final; hard cap 100 ticks. */
    const BOOL uniform = presented.size.width > 0 &&
        presented.size.height > 0 &&
        (closeScalar(presented.size.width / presented.size.height,
                     320.0 / 480.0) ||
         closeScalar(presented.size.width / presented.size.height,
                     480.0 / 320.0));
    const BOOL centered =
        closeScalar(CGRectGetMidX(presented), CGRectGetMidX(_window.bounds)) &&
        closeScalar(CGRectGetMidY(presented), CGRectGetMidY(_window.bounds));
    _settledTicks = uniform && centered ? _settledTicks + 1 : 0;
    if(_settledTicks < 2 && _ticks < 100) return;
    [timer invalidate];
    report("settle-timeout", _settledTicks >= 2);

    UIScreen *screen = [UIScreen mainScreen];
    report("initial-screen-bounds-spoof", CGRectEqualToRect(
        _initialScreenBounds, CGRectMake(0, 0, 320, 568)));
    report("canvas-bounds-spoof", CGRectEqualToRect(
        screenBounds, CGRectMake(0, 0, 320, 568)));
    report("application-frame-spoof", CGRectEqualToRect(
        screen.applicationFrame, CGRectMake(0, 0, 320, 568)));
    report("scale-clamped", exactScalar(screen.scale, 2.0));

    const UIInterfaceOrientation barOrientation =
        [UIApplication sharedApplication].statusBarOrientation;
    report("statusbar-orientation-landscape",
        barOrientation == UIInterfaceOrientationLandscapeLeft ||
        barOrientation == UIInterfaceOrientationLandscapeRight);

    const UIInterfaceOrientation controllerOrientation =
        _window.rootViewController.interfaceOrientation;
    report("controller-orientation-override",
        controllerOrientation == UIInterfaceOrientationLandscapeLeft ||
        controllerOrientation == UIInterfaceOrientationLandscapeRight);

    report("controller-wrapped-hierarchy",
        _window.rootViewController == _controller &&
        _controller.view.window == _window &&
        _renderer.window == _window &&
        [_renderer isDescendantOfView:_controller.view]);

    report("authored-view-untouched", CGRectEqualToRect(
        rendererBounds, CGRectMake(0, 0, 320, 480)));

    report("renderbuffer-authored-shaped",
        _backingWidth == 640 && _backingHeight == 960);

    const CGSize winSize = rendererBounds.size;
    const CGSize winSizeInPixels =
        CGSizeMake(winSize.width * 2.0, winSize.height * 2.0);
    report("winsize-pinned",
        exactScalar(winSize.width, 320.0) &&
        exactScalar(winSize.height, 480.0) &&
        exactScalar(winSizeInPixels.width, 640.0) &&
        exactScalar(winSizeInPixels.height, 960.0));

    /* INP-04: the recognizer-state enum must round-trip through the bridge
     * as stable raw values (unchanged since iOS 5). */
    UITapGestureRecognizer *recognizer =
        [[UITapGestureRecognizer alloc] initWithTarget:nil action:NULL];
    const NSInteger rawState = recognizer.state;
    [recognizer release];
    report("recognizer-state-raw-ints",
        rawState == UIGestureRecognizerStatePossible);

    report("presentation-uniform", uniform);
    report("presentation-centered", centered);
    report("presentation-inside-window",
        CGRectContainsRect(_window.bounds, presented));

    const CGPoint canvasCenter = [_renderer
        convertPoint:CGPointMake(160, 240) toView:_window];
    report("canvas-center-presents-at-viewport-center",
        closeScalar(canvasCenter.x, CGRectGetMidX(_window.bounds)) &&
        closeScalar(canvasCenter.y, CGRectGetMidY(_window.bounds)));

    const CGPoint presentedPoint = CGPointMake(
        CGRectGetMidX(presented), CGRectGetMidY(presented));
    const CGPoint roundTrip = [_renderer
        convertPoint:presentedPoint fromView:_window];
    report("touch-conversion-roundtrip",
        closeScalar(roundTrip.x, CGRectGetMidX(rendererBounds)) &&
        closeScalar(roundTrip.y, CGRectGetMidY(rendererBounds)));

    fprintf(stderr,
        "Declared canvas: screen=%s initial-screen=%s renderer=%s "
        "backing=%dx%d presented=%s\n",
        NSStringFromCGRect(screenBounds).UTF8String,
        NSStringFromCGRect(_initialScreenBounds).UTF8String,
        NSStringFromCGRect(rendererBounds).UTF8String,
        _backingWidth, _backingHeight,
        NSStringFromCGRect(presented).UTF8String);
    printf("declared-canvas: %s (%d failures)\n",
        failures ? "FAIL" : "PASS", failures);
    fflush(stdout);
    exit(failures ? 1 : 0);
}

- (void)dealloc {
    [_window release];
    [_renderer release];
    [_controller release];
    [_context release];
    [super dealloc];
}

@end

int main(int argc, char **argv) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil,
            NSStringFromClass([LC32DeclaredCanvasDelegate class]));
    }
}
