#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES1/gl.h>
#import <OpenGLES/ES1/glext.h>
#import <LC32/LC32.h>

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

/*
 * End-to-end regression for the runtime-declared landscape phone canvas in
 * native legacy rotation mode. Run this guest under a launcher whose
 * effective process SDK is pre-iOS-8 (LiveContainer's 2.0* fallback) with
 * Classic Mode enabled. The .app must be phone-only, declare NO orientation
 * keys (neither UISupportedInterfaceOrientations nor UIInterfaceOrientation),
 * and leave UIStatusBarHidden unset: the runtime status-bar request below is
 * the only orientation declaration, exactly like a 2009 main-nib game.
 *
 * The launch order mirrors that engine shape: the window and renderer are
 * sized from the first UIScreen read, the status-bar request follows, and
 * the renderbuffer storage is allocated before the renderer is attached to
 * the window. The fixed canvas must therefore arrive through the drawable
 * adoption, and the presentation fit must compose with the existing native
 * rotation without any further guest-visible geometry.
 *
 * The presentation assertions are intentionally presentation-model
 * agnostic: the fit must be a uniform scale (exact 3:2 aspect), centered on
 * the window's midpoint, and fully inside the window's hit region, whatever
 * the live Classic-Mode viewport is at the time.
 */

static int failures;

static void report(const char *name, BOOL passed) {
    printf("native-canvas-%s: %s\n", name, passed ? "PASS" : "FAIL");
    failures += !passed;
}

static BOOL closeScalar(CGFloat a, CGFloat b) {
    return isfinite(a) && isfinite(b) && fabs(a - b) < 0.75;
}

@interface LC32NativeCanvasRenderer : UIView
@end

@implementation LC32NativeCanvasRenderer
+ (Class)layerClass {
    return [CAEAGLLayer class];
}
@end

@interface LC32NativeCanvasDelegate : NSObject <UIApplicationDelegate> {
    UIWindow *_window;
    LC32NativeCanvasRenderer *_renderer;
    EAGLContext *_context;
    CGRect _initialScreenBounds;
    GLint _backingWidth;
    GLint _backingHeight;
    NSUInteger _ticks;
    NSUInteger _settledTicks;
}
@property(nonatomic, retain) UIWindow *window;
@end

@implementation LC32NativeCanvasDelegate
@synthesize window = _window;

- (void)applicationDidFinishLaunching:(UIApplication *)application {
    (void)application;
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    report("keyless-bundle-shape",
        ![info[@"UISupportedInterfaceOrientations"] isKindOfClass:NSArray.class] &&
        ![info objectForKey:@"UIInterfaceOrientation"]);

    _initialScreenBounds = [UIScreen mainScreen].bounds;
    self.window = [[[UIWindow alloc] initWithFrame:
        CGRectMake(0, 0, 320, 480)] autorelease];
    _renderer = [[LC32NativeCanvasRenderer alloc]
        initWithFrame:_initialScreenBounds];
    _renderer.opaque = YES;
    CAEAGLLayer *drawableLayer = (CAEAGLLayer *)_renderer.layer;
    drawableLayer.drawableProperties = @{
        kEAGLDrawablePropertyRetainedBacking: @NO,
        kEAGLDrawablePropertyColorFormat: kEAGLColorFormatRGB565,
    };

    /* The 2009 status-bar declaration that defines the canvas class. */
    [[UIApplication sharedApplication]
        setStatusBarOrientation:UIInterfaceOrientationLandscapeRight
                       animated:NO];

    _context = [[EAGLContext alloc]
        initWithAPI:kEAGLRenderingAPIOpenGLES1];
    [EAGLContext setCurrentContext:_context];
    GLuint renderbuffer = 0;
    glGenRenderbuffersOES(1, &renderbuffer);
    glBindRenderbufferOES(GL_RENDERBUFFER_OES, renderbuffer);
    [_context renderbufferStorage:GL_RENDERBUFFER_OES
                      fromDrawable:drawableLayer];
    glGetRenderbufferParameterivOES(GL_RENDERBUFFER_OES,
        GL_RENDERBUFFER_WIDTH_OES, &_backingWidth);
    glGetRenderbufferParameterivOES(GL_RENDERBUFFER_OES,
        GL_RENDERBUFFER_HEIGHT_OES, &_backingHeight);

    [_window addSubview:_renderer];
    [_window makeKeyAndVisible];
    [NSTimer scheduledTimerWithTimeInterval:0.1 target:self
        selector:@selector(tick:) userInfo:nil repeats:YES];
}

- (void)tick:(NSTimer *)timer {
    ++_ticks;
    const CGRect screenBounds = [UIScreen mainScreen].bounds;
    const CGRect rendererBounds = _renderer.bounds;
    const CGRect presented = [_renderer convertRect:rendererBounds
                                              toView:_window];
    /* The deferred fit may need a couple of main-queue passes after the
     * startup events; treat two consecutive settled readings as final. */
    const BOOL uniform = presented.size.width > 0 &&
        presented.size.height > 0 &&
        closeScalar(presented.size.width / presented.size.height,
                    320.0 / 480.0);
    const BOOL centered =
        closeScalar(CGRectGetMidX(presented), CGRectGetMidX(_window.bounds)) &&
        closeScalar(CGRectGetMidY(presented), CGRectGetMidY(_window.bounds));
    _settledTicks = uniform && centered ? _settledTicks + 1 : 0;
    if(_settledTicks < 2 && _ticks < 100) return;
    [timer invalidate];

    UIApplication *application = [UIApplication sharedApplication];
    report("canvas-bounds-spoof", CGRectEqualToRect(screenBounds,
        CGRectMake(0, 0, 320, 480)));
    report("statusbar-request-paired",
        application.statusBarOrientation ==
            UIInterfaceOrientationLandscapeRight);
    report("drawable-adopted", CGRectEqualToRect(rendererBounds,
        CGRectMake(0, 0, 320, 480)));
    report("renderbuffer-canvas-shaped",
        _backingWidth > 0 && _backingHeight > 0 &&
        _backingWidth % 320 == 0 && _backingHeight % 480 == 0 &&
        _backingWidth / 320 == _backingHeight / 480);
    report("presentation-uniform-and-centered", uniform && centered);
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
        "Native canvas: screen=%s initial-screen=%s renderer=%s "
        "backing=%dx%d presented=%s\n",
        NSStringFromCGRect(screenBounds).UTF8String,
        NSStringFromCGRect(_initialScreenBounds).UTF8String,
        NSStringFromCGRect(rendererBounds).UTF8String,
        _backingWidth, _backingHeight,
        NSStringFromCGRect(presented).UTF8String);
    printf("native-canvas: %s (%d failures)\n",
        failures ? "FAIL" : "PASS", failures);
    fflush(stdout);
    exit(failures ? 1 : 0);
}

- (void)dealloc {
    [_window release];
    [_renderer release];
    [_context release];
    [super dealloc];
}

@end

int main(int argc, char **argv) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil,
            NSStringFromClass([LC32NativeCanvasDelegate class]));
    }
}
