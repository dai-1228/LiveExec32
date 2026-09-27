#import <UIKit/UIKit.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

@interface NSObject (LC32OrientationStartupTest)
- (uint64_t)host_self;
@end
extern uint64_t LC32GetHostSelector(SEL selector);
extern uint64_t LC32InvokeHostSelector(uint64_t object,
                                       uint64_t selector, ...);
extern id LC32HostToGuestObject(uint64_t hostObject);

/*
 * UIApplication fixture: use a phone-only .app with all four supported
 * orientations, UIInterfaceOrientationLandscapeRight as the initial
 * orientation, and UIStatusBarHidden=YES. Inject the normal arm64 launcher
 * with lipo. Like uikit_legacy_overlay, this target advertises SDK 7.0 so it
 * exercises legacy launch policy without a production test override.
 *
 * Older game engines install their UIWindow/root before a zero-delay
 * start-engine selector initializes renderer-owned state. Orientation policy
 * must use the bundle fallback until that deferred setup has had a turn.
 */

enum {
    ModernSupported,
    ModernPreferred,
    ModernAutorotate,
    ModernLegacyAutorotate,
    LegacyAutorotate,
    CallbackCount,
};

static const char * const callbackNames[CallbackCount] = {
    "supportedInterfaceOrientations",
    "preferredInterfaceOrientationForPresentation",
    "shouldAutorotate",
    "modern-shouldAutorotateToInterfaceOrientation:",
    "legacy-shouldAutorotateToInterfaceOrientation:",
};
static uint32_t engineReady;
static uint32_t callbacks[CallbackCount];
static uint32_t prematureCallbacks;
static int failures;

static void recordCallback(unsigned callback) {
    __atomic_fetch_add(&callbacks[callback], 1, __ATOMIC_RELAXED);
    if(!__atomic_load_n(&engineReady, __ATOMIC_ACQUIRE)) {
        const uint32_t previous = __atomic_fetch_add(
            &prematureCallbacks, 1, __ATOMIC_RELAXED);
        if(previous < 12)
            fprintf(stderr, "orientation-startup: premature %s\n",
                callbackNames[callback]);
    }
}

static uint32_t callbackCount(unsigned callback) {
    return __atomic_load_n(&callbacks[callback], __ATOMIC_RELAXED);
}

static void report(const char *name, BOOL passed) {
    printf("orientation-startup-%s: %s\n", name, passed ? "PASS" : "FAIL");
    failures += !passed;
}

static UIInterfaceOrientationMask nativeCachedMask(UIViewController *controller) {
    /* A normal guest message would directly invoke the guest override and
     * make this a false positive. The ordinary host selector bridge starts
     * at the first native superclass, so asking it for the mask directly
     * would instead read UIViewController's default. Native KVC dispatches
     * back through the mirror's actual adapter, outside its query scope. */
    NSString *key = @"supportedInterfaceOrientations";
    const uint64_t result = LC32InvokeHostSelector(
        [controller host_self],
        LC32GetHostSelector(@selector(valueForKey:)),
        [key host_self], (uint64_t)0);
    return (UIInterfaceOrientationMask)[
        LC32HostToGuestObject(result) unsignedIntegerValue];
}

static UIInterfaceOrientation nativeControllerOrientation(
        UIViewController *controller) {
    return (UIInterfaceOrientation)LC32InvokeHostSelector(
        [controller host_self],
        LC32GetHostSelector(@selector(interfaceOrientation)), (uint64_t)0);
}

@interface LC32StartupOrientationController : UIViewController
@end

@implementation LC32StartupOrientationController
- (void)loadView {
    UIView *view = [[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    [view setBackgroundColor:[UIColor blackColor]];
    [self setView:view];
    [view release];
}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    recordCallback(ModernSupported);
    return UIInterfaceOrientationMaskLandscapeRight;
}
- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation {
    recordCallback(ModernPreferred);
    return UIInterfaceOrientationLandscapeRight;
}
- (BOOL)shouldAutorotate {
    recordCallback(ModernAutorotate);
    return YES;
}
- (BOOL)shouldAutorotateToInterfaceOrientation:
        (UIInterfaceOrientation)orientation {
    recordCallback(ModernLegacyAutorotate);
    return orientation == UIInterfaceOrientationLandscapeRight;
}
@end

@interface LC32StartupLegacyOrientationController : UIViewController
@end

@implementation LC32StartupLegacyOrientationController
- (void)loadView {
    UIView *view = [[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    [view setBackgroundColor:[UIColor blackColor]];
    [self setView:view];
    [view release];
}
- (BOOL)shouldAutorotateToInterfaceOrientation:
        (UIInterfaceOrientation)orientation {
    recordCallback(LegacyAutorotate);
    return orientation == UIInterfaceOrientationLandscapeRight;
}
@end

@interface LC32StartupOrientationDelegate : NSObject <UIApplicationDelegate> {
    LC32StartupOrientationController *_modernController;
    LC32StartupLegacyOrientationController *_legacyController;
    UIWindow *_legacyWindow;
    NSUInteger _waitCount;
    BOOL _nestedInitializationTickRan;
    BOOL _activatedLegacyWindow;
}
@property(nonatomic, retain) UIWindow *window;
@end

@implementation LC32StartupOrientationDelegate
@synthesize window = _window;

- (void)applicationDidFinishLaunching:(UIApplication *)application {
    (void)application;
    CGRect bounds = [[UIScreen mainScreen] bounds];
    bounds = CGRectMake(0, 0, MAX(bounds.size.width, bounds.size.height),
        MIN(bounds.size.width, bounds.size.height));
    _modernController = [LC32StartupOrientationController new];
    self.window = [[[UIWindow alloc] initWithFrame:bounds] autorelease];
    [self.window setRootViewController:_modernController];
    [self.window makeKeyAndVisible];

    _legacyController = [LC32StartupLegacyOrientationController new];
    _legacyWindow = [[UIWindow alloc] initWithFrame:bounds];
    [_legacyWindow setRootViewController:_legacyController];
    [_legacyWindow setHidden:NO];
    [self.window makeKeyAndVisible];

    report("modern-bundle-fallback-during-launch",
        nativeCachedMask(_modernController) == UIInterfaceOrientationMaskAll);
    report("legacy-bundle-fallback-during-launch",
        nativeCachedMask(_legacyController) == UIInterfaceOrientationMaskAll);
    report("no-query-during-window-installation",
        __atomic_load_n(&prematureCallbacks, __ATOMIC_RELAXED) == 0);
    /* The startup bundle permits all four orientations. Even if the native
     * root is still portrait while UIApplication reports landscape, that
     * valid native transition must not be replaced by the app orientation. */
    report("launch-root-allowed-native-orientation-preserved",
        [_modernController interfaceOrientation] ==
            nativeControllerOrientation(_modernController));

    /* Do not mark the engine ready synchronously at the end of launch. This
     * ordering is the regression: UIKit can request policy after this method
     * returns but before the queued setup selector has executed. */
    [self performSelector:@selector(setupEngine) withObject:nil afterDelay:0.0];
}

- (void)setupEngine {
    report("no-query-before-deferred-engine-setup",
        __atomic_load_n(&prematureCallbacks, __ATOMIC_RELAXED) == 0);
    /* Engine initialization may pump native events while its guest callback
     * is still on the stack. An idle observer in this nested run loop is not
     * the application's first safe post-initialization idle boundary. */
    [NSTimer scheduledTimerWithTimeInterval:0.02 target:self
        selector:@selector(nestedInitializationTick:) userInfo:nil repeats:NO];
    /* A first-run JIT compilation between making the date and entering
     * Foundation can consume the whole interval. Retry bounded run-loop
     * turns until the timer actually executes, not just one wall-clock gap. */
    for(unsigned turn = 0; turn < 20 && !_nestedInitializationTickRan; ++turn) {
        [[NSRunLoop currentRunLoop] runUntilDate:
            [NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    report("nested-initialization-run-loop-executed", _nestedInitializationTickRan);
    report("no-query-during-nested-initialization-run-loop",
        __atomic_load_n(&prematureCallbacks, __ATOMIC_RELAXED) == 0);
    __atomic_store_n(&engineReady, 1, __ATOMIC_RELEASE);
    [self.window setNeedsLayout];
    [_legacyWindow setNeedsLayout];
    [NSTimer scheduledTimerWithTimeInterval:0.05 target:self
        selector:@selector(checkPolicy:) userInfo:nil repeats:YES];
}

- (void)nestedInitializationTick:(NSTimer *)timer {
    (void)timer;
    _nestedInitializationTickRan = YES;
}

- (void)checkPolicy:(NSTimer *)timer {
    if(!_activatedLegacyWindow && callbackCount(ModernSupported) > 0) {
        /* The launch refresh need only adopt the delegate's primary window.
         * Exercise the secondary controller through the ordinary initialized
         * window path once the primary callback proves the guard reopened. */
        _activatedLegacyWindow = YES;
        [_legacyWindow makeKeyAndVisible];
        [self.window makeKeyAndVisible];
    }
    const UIInterfaceOrientationMask modern = nativeCachedMask(_modernController);
    const UIInterfaceOrientationMask legacy = nativeCachedMask(_legacyController);
    const BOOL queried = callbackCount(ModernSupported) > 0 &&
        callbackCount(LegacyAutorotate) > 0;
    const BOOL narrowed = modern == UIInterfaceOrientationMaskLandscapeRight &&
        legacy == UIInterfaceOrientationMaskLandscapeRight;
    if(queried && narrowed) {
        [timer invalidate];
        report("modern-callback-resumes-after-setup", YES);
        report("legacy-callback-resumes-after-setup", YES);
        report("modern-native-cache-narrows-to-guest-policy", YES);
        report("legacy-native-cache-narrows-to-guest-policy", YES);
        [self finish];
    } else if(++_waitCount >= 200) {
        [timer invalidate];
        fprintf(stderr, "orientation-startup: policy timeout modern=0x%lx "
            "legacy=0x%lx\n", (unsigned long)modern, (unsigned long)legacy);
        report("modern-callback-resumes-after-setup", callbackCount(ModernSupported) > 0);
        report("legacy-callback-resumes-after-setup", callbackCount(LegacyAutorotate) > 0);
        report("modern-native-cache-narrows-to-guest-policy",
            modern == UIInterfaceOrientationMaskLandscapeRight);
        report("legacy-native-cache-narrows-to-guest-policy",
            legacy == UIInterfaceOrientationMaskLandscapeRight);
        [self finish];
    }
}

- (void)finish {
    const UIInterfaceOrientation orientation =
        [[UIApplication sharedApplication] statusBarOrientation];
    UIViewController *detached = [UIViewController new];
    report("detached-controller-uses-app-orientation",
        [detached interfaceOrientation] == orientation);
    report("detached-orientation-does-not-load-view", ![detached isViewLoaded]);
    (void)[detached view];
    report("loaded-detached-controller-uses-app-orientation",
        [detached interfaceOrientation] == orientation);
    [self.window addSubview:[detached view]];
    report("direct-window-subview-controller-uses-app-orientation",
        [detached interfaceOrientation] == orientation);
    [[detached view] removeFromSuperview];
    UIView *wrapper = [[UIView alloc] initWithFrame:[[detached view] frame]];
    [self.window addSubview:wrapper];
    [wrapper addSubview:[detached view]];
    const UIInterfaceOrientation nestedNative = (UIInterfaceOrientation)
        LC32InvokeHostSelector([detached host_self],
            LC32GetHostSelector(@selector(interfaceOrientation)), (uint64_t)0);
    report("nested-window-subview-controller-orientation-preserved",
        [detached interfaceOrientation] == nestedNative);
    [[detached view] removeFromSuperview];
    [wrapper removeFromSuperview];
    [wrapper release];
    report("attached-controller-orientation-preserved",
        [_modernController interfaceOrientation] ==
            nativeControllerOrientation(_modernController));
    UIViewController *parent = [UIViewController new];
    [parent addChildViewController:detached];
    [detached didMoveToParentViewController:parent];
    const UIInterfaceOrientation parentedNative = (UIInterfaceOrientation)
        LC32InvokeHostSelector([detached host_self],
            LC32GetHostSelector(@selector(interfaceOrientation)), (uint64_t)0);
    report("parented-controller-orientation-preserved",
        [detached interfaceOrientation] == parentedNative);
    [detached willMoveToParentViewController:nil];
    [detached removeFromParentViewController];
    [parent release];
    [detached release];
    report("no-premature-callbacks", __atomic_load_n(
        &prematureCallbacks, __ATOMIC_RELAXED) == 0);
    for(unsigned index = 0; index < CallbackCount; ++index)
        printf("orientation-startup-callback %s: %u\n",
            callbackNames[index], (unsigned)callbackCount(index));
    printf("orientation-startup-regression: %s\n", failures ? "FAIL" : "PASS");
    exit(failures != 0);
}

- (void)dealloc {
    [_window release];
    [_legacyWindow release];
    [_modernController release];
    [_legacyController release];
    [super dealloc];
}
@end

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil,
            NSStringFromClass([LC32StartupOrientationDelegate class]));
    }
}
