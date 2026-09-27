#import "LC32LegacyRotation.h"
#import <objc/message.h>
#import <objc/runtime.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

// This unit deliberately restores UIKit's deprecated pre-iOS-8 contract.
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

@interface LC32LegacyRotationState : NSObject
@property(nonatomic, weak) UIViewController *initializedController;
@property(nonatomic) BOOL initializedControllerless;
@end
@implementation LC32LegacyRotationState
@end

struct LC32RotationBuildVersion { uint32_t platform, version; };
extern "C" bool dyld_program_sdk_at_least(LC32RotationBuildVersion version);

namespace {
const void *RegisteredClassKey = &RegisteredClassKey;
const void *WindowStateKey = &WindowStateKey;
bool startupFinished;
using NativeRotationQuery = BOOL (*)(id, SEL, UIInterfaceOrientation, BOOL, BOOL *);
NativeRotationQuery nativeRotationQuery;
thread_local __unsafe_unretained UIWindow *configuringLegacyWindow;

LC32LegacyRotationState *WindowState(UIWindow *window) {
    LC32LegacyRotationState *state = objc_getAssociatedObject(window, WindowStateKey);
    if(!state) {
        state = [LC32LegacyRotationState new];
        objc_setAssociatedObject(window, WindowStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}

UIInterfaceOrientationMask DeclaredOrientations();
UIInterfaceOrientation PreferredOrientation();

UIInterfaceOrientationMask LegacySupportedOrientations(id, SEL) {
    // This is a policy query, not a rotation request. In particular, old Unity
    // writes its pending orientation even when shouldAutorotate returns NO.
    // Probing all four directions here would leave an arbitrary pending turn.
    return DeclaredOrientations();
}

UIInterfaceOrientation LegacyPreferredOrientation(id, SEL) {
    return PreferredOrientation();
}

bool RegisteredClass(Class cls) {
    for(Class current = cls; current && current != UIViewController.class;
            current = class_getSuperclass(current)) {
        if(objc_getAssociatedObject((id)current, RegisteredClassKey)) return true;
    }
    return false;
}

bool UsesLegacyRotationPolicy(Class cls) {
    if(!RegisteredClass(cls)) return false;
    if(class_getMethodImplementation(cls, @selector(shouldAutorotateToInterfaceOrientation:)) ==
            class_getMethodImplementation(UIViewController.class,
                @selector(shouldAutorotateToInterfaceOrientation:))) return false;
    // Recheck the actual subclass: a guest can inherit the old callback but
    // deliberately replace its policy with the modern orientation API.
    IMP supported = class_getMethodImplementation(
        cls, @selector(supportedInterfaceOrientations));
    IMP should = class_getMethodImplementation(cls, @selector(shouldAutorotate));
    return (supported == (IMP)LegacySupportedOrientations ||
            supported == class_getMethodImplementation(UIViewController.class,
                @selector(supportedInterfaceOrientations))) &&
        should == class_getMethodImplementation(UIViewController.class,
            @selector(shouldAutorotate));
}

NSHashTable<UIViewController *> *Controllers() {
    static NSHashTable<UIViewController *> *controllers;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ controllers = [NSHashTable weakObjectsHashTable]; });
    return controllers;
}

NSHashTable<UIWindow *> *ControllerlessWindows() {
    static NSHashTable<UIWindow *> *windows;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ windows = [NSHashTable weakObjectsHashTable]; });
    return windows;
}

UIView *NativeView(UIViewController *controller) {
    using Getter = UIView *(*)(id, SEL);
    static Getter getter = (Getter)class_getMethodImplementation(
        UIViewController.class, @selector(viewIfLoaded));
    return getter(controller, @selector(viewIfLoaded));
}

UIView *NativeSuperview(UIView *view) {
    using Getter = UIView *(*)(id, SEL);
    static Getter getter = (Getter)class_getMethodImplementation(
        UIView.class, @selector(superview));
    return getter(view, @selector(superview));
}

UIWindow *NativeWindow(UIView *view) {
    using Getter = UIWindow *(*)(id, SEL);
    static Getter getter = (Getter)class_getMethodImplementation(
        UIView.class, @selector(window));
    return getter(view, @selector(window));
}

UIViewController *NativeRoot(UIWindow *window) {
    using Getter = UIViewController *(*)(id, SEL);
    static Getter getter = (Getter)class_getMethodImplementation(
        UIWindow.class, @selector(rootViewController));
    return getter(window, @selector(rootViewController));
}

UIViewController *NativeParent(UIViewController *controller) {
    using Getter = UIViewController *(*)(id, SEL);
    static Getter getter = (Getter)class_getMethodImplementation(
        UIViewController.class, @selector(parentViewController));
    return getter(controller, @selector(parentViewController));
}

UIViewController *NativePresenting(UIViewController *controller) {
    using Getter = UIViewController *(*)(id, SEL);
    static Getter getter = (Getter)class_getMethodImplementation(
        UIViewController.class, @selector(presentingViewController));
    return getter(controller, @selector(presentingViewController));
}

UIViewController *NativePresented(UIViewController *controller) {
    using Getter = UIViewController *(*)(id, SEL);
    static Getter getter = (Getter)class_getMethodImplementation(
        UIViewController.class, @selector(presentedViewController));
    return getter(controller, @selector(presentedViewController));
}

UIViewController *ControllerForWindow(UIWindow *window, bool forBacking = false) {
    if(!window) return nil;
    UIViewController *root = NativeRoot(window);
    if(root) {
        // Low-SDK UIKit still rotates a modern-policy root's view in portrait
        // window coordinates. It needs the same inverse backing rotation, but
        // must retain its modern policy without deprecated policy queries.
        Class cls = object_getClass(root);
        return forBacking ? (RegisteredClass(cls) ? root : nil) :
            (!NativePresented(root) && UsesLegacyRotationPolicy(cls) ? root : nil);
    }
    UIViewController *candidate = nil;
    for(UIViewController *controller in Controllers().allObjects) {
        // A renderer-owned controller can omit every rotation-policy method.
        // It still needs portrait backing coordinates, without old queries.
        Class cls = object_getClass(controller);
        if(!(forBacking ? RegisteredClass(cls) : UsesLegacyRotationPolicy(cls))) continue;
        UIView *view = NativeView(controller);
        if(view && NativeSuperview(view) == window &&
                !NativeParent(controller) &&
                !NativePresenting(controller) &&
                (forBacking || !NativePresented(controller))) {
            // Two independent direct children do not establish one rotation
            // owner. Do not pick one based on weak-table enumeration order.
            if(candidate) return nil;
            candidate = controller;
        }
    }
    return candidate;
}

bool ControllerlessLegacyWindow(UIWindow *window) {
    /* Main-nib applications from the controller-less era archived their
     * drawable directly under the window: no root controller, no
     * renderer-owned controller, only subviews. Their pre-iOS-8 coordinates
     * still need the inverse root-layer rotation whenever the scene turns,
     * but nothing in their hierarchy may be asked a rotation-policy
     * question, so they cannot enter through the controller table. */
    if(!window || NativeRoot(window)) return false;
    if(ControllerForWindow(window, true)) return false;
    return LC32NativeLegacyRotationWindowIsGuest(window);
}

bool WindowNeedsLegacyBacking(UIWindow *window) {
    if(!window) return false;
    if(ControllerForWindow(window, true)) return true;
    return ControllerlessLegacyWindow(window);
}

UIInterfaceOrientation OrientationNamed(id name) {
    if([name isEqual:@"UIInterfaceOrientationPortrait"]) return UIInterfaceOrientationPortrait;
    if([name isEqual:@"UIInterfaceOrientationPortraitUpsideDown"]) return UIInterfaceOrientationPortraitUpsideDown;
    if([name isEqual:@"UIInterfaceOrientationLandscapeLeft"]) return UIInterfaceOrientationLandscapeLeft;
    if([name isEqual:@"UIInterfaceOrientationLandscapeRight"]) return UIInterfaceOrientationLandscapeRight;
    return UIInterfaceOrientationUnknown;
}

UIInterfaceOrientationMask OrientationBit(UIInterfaceOrientation orientation) {
    return orientation >= UIInterfaceOrientationPortrait &&
        orientation <= UIInterfaceOrientationLandscapeLeft
        ? (UIInterfaceOrientationMask)(1UL << orientation) : 0;
}

NSArray *DeclaredOrientationNames() {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    id names;
    if(UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad)
        names = info[@"UISupportedInterfaceOrientations~ipad"];
    if(![names isKindOfClass:NSArray.class]) names = info[@"UISupportedInterfaceOrientations"];
    return [names isKindOfClass:NSArray.class] ? names : nil;
}

UIInterfaceOrientationMask DeclaredOrientations() {
    UIInterfaceOrientationMask mask = 0;
    for(id name in DeclaredOrientationNames()) mask |= OrientationBit(OrientationNamed(name));
    return mask ?: UIInterfaceOrientationMaskAllButUpsideDown;
}

UIInterfaceOrientation PreferredOrientation() {
    UIInterfaceOrientationMask mask = DeclaredOrientations();
    // A pre-iOS-8 application can declare its interface orientation through
    // the status-bar API instead of the Info.plist. Mirror the canvas-mode
    // target resolution: the explicit runtime request wins over the status
    // bar, the plist hint, and the first declared name.
    UIInterfaceOrientation current = LC32LegacyRequestedStatusBarOrientation();
    if(OrientationBit(current) & mask) return current;
    current = UIApplication.sharedApplication.statusBarOrientation;
    if(OrientationBit(current) & mask) return current;
    current = OrientationNamed(NSBundle.mainBundle.infoDictionary[@"UIInterfaceOrientation"]);
    if(OrientationBit(current) & mask) return current;
    for(id name in DeclaredOrientationNames()) {
        current = OrientationNamed(name);
        if(OrientationBit(current) & mask) return current;
    }
    return UIInterfaceOrientationPortrait;
}

struct RotationRequest {
    __unsafe_unretained UIWindow *window;
    __unsafe_unretained UIViewController *controller;
    UIInterfaceOrientation orientation;
    BOOL accepted;
    RotationRequest *previous;
};
thread_local RotationRequest *activeRequest;

BOOL QueryRotation(UIWindow *window, UIViewController *controller,
        UIInterfaceOrientation orientation) {
    if(!(OrientationBit(orientation) & DeclaredOrientations())) return NO;
    if(activeRequest && activeRequest->window == window && activeRequest->controller == controller &&
            activeRequest->orientation == orientation) return activeRequest->accepted;
    if(!startupFinished || !LC32NativeLegacyRotationCanCallGuest()) return NO;
    return ((BOOL (*)(id, SEL, UIInterfaceOrientation))objc_msgSend)(controller,
        @selector(shouldAutorotateToInterfaceOrientation:), orientation);
}

void UpdateControllerlessWindow(UIWindow *window,
        UIInterfaceOrientation orientation, bool initialOnly) {
    /* A controller-less window follows the pre-iOS-8 status-bar contract:
     * the application declared its interface orientation exclusively through
     * setStatusBarOrientation: and rotates its content itself. Turn the
     * window only to that explicitly requested orientation; ambient device
     * and plist fallbacks must not invent turns for a hierarchy that has no
     * rotation policy to consult. */
    const UIInterfaceOrientation requested =
        LC32LegacyRequestedStatusBarOrientation();
    if(!OrientationBit(requested) || orientation != requested) return;
    LC32LegacyRotationState *state = WindowState(window);
    const bool initializing = !state.initializedControllerless;
    if(initialOnly && !initializing) return;
    // The swizzled update refreshes the restored backing on both sides of
    // the turn, keeping the window extent and its inverse root-layer
    // rotation in the same order as the explicit-root path.
    SEL rotate = sel_registerName("_updateToInterfaceOrientation:duration:force:");
    if([window respondsToSelector:rotate]) {
        ((void (*)(id, SEL, UIInterfaceOrientation, NSTimeInterval, BOOL))objc_msgSend)(
            window, rotate, orientation, 0, YES);
    } else {
        [UIViewController attemptRotationToDeviceOrientation];
    }
    state.initializedControllerless = YES;
}

void UpdateWindow(UIWindow *window, UIInterfaceOrientation orientation,
        bool initialOnly) {
    if(!pthread_main_np() || !startupFinished) return;
    UIViewController *controller = ControllerForWindow(window, true);
    if(!controller && !ControllerlessLegacyWindow(window)) return;
    if(!(OrientationBit(orientation) & DeclaredOrientations())) return;
    if(!controller) {
        UpdateControllerlessWindow(window, orientation, initialOnly);
        return;
    }
    UIView *view = NativeView(controller);
    if(!view || NativeWindow(view) != window) return;
    // Synchronize the portrait window extent before a guest rotation callback
    // sizes its renderer from UIScreen. Resizing afterwards applies the same
    // scene-size delta a second time through the view's autoresizing mask.
    ((void (*)(id, SEL))objc_msgSend)(window, sel_registerName("_updateTransformLayer"));
    if(!LC32NativeLegacyRotationCanCallGuest()) return;
    if(NativePresented(controller)) return;
    LC32LegacyRotationState *state = WindowState(window);
    const bool initializing = state.initializedController != controller;
    if(initialOnly && !initializing) return;
    // Rootless legacy windows have no native rotation client yet. Once one is
    // registered, respect UIKit's presentation and rotation-lock decisions.
    if(NativeRoot(window) && nativeRotationQuery) {
        BOOL disabled = NO;
        if(!nativeRotationQuery(window,
                sel_registerName("_shouldAutorotateToInterfaceOrientation:checkForDismissal:isRotationDisabled:"),
                orientation, YES, &disabled) || disabled) return;
    }

    BOOL accepted = !UsesLegacyRotationPolicy(object_getClass(controller)) ||
        QueryRotation(window, controller, orientation);
    if(ControllerForWindow(window, true) != controller) return;
    state.initializedController = controller;
    if(!NativeRoot(window)) {
        // A direct-window renderer owns its view hierarchy and may perform the
        // requested turn on its next repaint. Autopromoting it with the modern
        // root setter resizes its view/backing store before that repaint.
        // Keep it rootless and restore only the window's backing coordinates.
        ((void (*)(id, SEL))objc_msgSend)(window, sel_registerName("_updateTransformLayer"));
        return;
    }
    // A NO may still have queued a renderer-owned turn. Do not rotate the
    // controller before giving the game that choice.
    if(!accepted) {
        ((void (*)(id, SEL))objc_msgSend)(window, sel_registerName("_updateTransformLayer"));
        return;
    }
    RotationRequest request{window, controller, orientation, accepted, activeRequest};
    activeRequest = &request;
    @try {
        // Synchronize the newly registered rotation client with the window.
        // Unlike the old force-rotation API this is also valid for a window
        // whose scene owns orientation. It leaves Classic Mode to UIKit.
        SEL rotate = sel_registerName("_updateToInterfaceOrientation:duration:force:");
        if([window respondsToSelector:rotate]) {
            // A window may already have the scene's orientation before the
            // game attaches its controller. UIKit then only lays out the new
            // client, without a will/did pair. Supply that initial lifecycle
            // before the next guest frame can perform a competing manual turn.
            SEL current = sel_registerName("interfaceOrientation");
            bool initialSync = initializing &&
                ((UIInterfaceOrientation (*)(id, SEL))objc_msgSend)(window, current) == orientation;
            if(initialSync) [controller willRotateToInterfaceOrientation:orientation duration:0];
            ((void (*)(id, SEL, UIInterfaceOrientation, NSTimeInterval, BOOL))objc_msgSend)(
                window, rotate, orientation, 0, YES);
            if(initialSync) [controller didRotateFromInterfaceOrientation:orientation];
        } else {
            [UIViewController attemptRotationToDeviceOrientation];
        }
    } @finally {
        activeRequest = request.previous;
    }
}

void UpdateWindows(UIInterfaceOrientation orientation, bool initialOnly) {
    NSMutableSet<UIWindow *> *windows = [NSMutableSet set];
    for(UIViewController *controller in Controllers().allObjects) {
        UIView *view = NativeView(controller);
        UIWindow *window = view ? NativeWindow(view) : nil;
        if(window) [windows addObject:window];
    }
    // Controller-less guest windows have no registered controller to
    // enumerate from; the visibility observer records them instead.
    for(UIWindow *window in ControllerlessWindows()) {
        if(window) [windows addObject:window];
    }
    for(UIWindow *window in windows) UpdateWindow(window, orientation, initialOnly);
}

void Swizzle(Class cls, SEL original, SEL replacement) {
    Method method = class_getInstanceMethod(cls, original);
    if(!method) {
        NSLog(@"LC32: %s not found", sel_getName(original));
        return;
    }
    method_exchangeImplementations(method, class_getInstanceMethod(cls, replacement));
}
} // namespace

extern "C" bool LC32NativeLegacyRotationEnabled(void) {
    static const bool enabled = [] {
        const char *disabled = getenv("LC32_DISABLE_UIKIT_COMPATIBILITY");
        return !(disabled && strcmp(disabled, "1") == 0) &&
            !dyld_program_sdk_at_least({2, 0x00080000});
    }();
    return enabled;
}

extern "C" void LC32PrepareNativeLegacyRotationClass(Class cls) {
    if(!cls || !LC32NativeLegacyRotationEnabled()) return;
    // Modern rotation policy arrived in iOS 6, before the iOS 8 geometry
    // change. Those guest controllers still need portrait backing coordinates
    // and the deprecated will/did lifecycle, but not legacy policy queries.
    objc_setAssociatedObject((id)cls, RegisteredClassKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if(!UsesLegacyRotationPolicy(cls)) return;
    class_addMethod(cls, @selector(supportedInterfaceOrientations),
        (IMP)LegacySupportedOrientations, method_getTypeEncoding(class_getInstanceMethod(
            UIViewController.class, @selector(supportedInterfaceOrientations))));
    SEL preferred = @selector(preferredInterfaceOrientationForPresentation);
    if(class_getMethodImplementation(cls, preferred) ==
            class_getMethodImplementation(UIViewController.class, preferred))
        class_addMethod(cls, preferred, (IMP)LegacyPreferredOrientation,
            method_getTypeEncoding(class_getInstanceMethod(UIViewController.class, preferred)));
}

extern "C" void LC32FinishNativeLegacyRotationStartup(void) {
    if(!LC32NativeLegacyRotationEnabled()) return;
    startupFinished = true;
    UpdateWindows(PreferredOrientation(), true);
}

extern "C" void LC32NativeLegacyRotationRefreshRequested(
        UIInterfaceOrientation orientation) {
    if(!LC32NativeLegacyRotationEnabled()) return;
    /* The bridge invokes this while the guest's status-bar setter is still
     * on the JIT stack; UpdateWindow applies the startup, main-thread, and
     * declared-mask gates, and never asks this guest hierarchy a policy
     * question. */
    if(!OrientationBit(orientation)) return;
    UpdateWindows(orientation, false);
}

@interface UIViewController (LC32NativeLegacyRotation)
- (void)lc32_rotationViewDidMoveToWindow:(UIWindow *)window shouldAppearOrDisappear:(BOOL)appear;
- (void)lc32_rotationWindow:(UIWindow *)window willRotateToInterfaceOrientation:(UIInterfaceOrientation)orientation
    duration:(NSTimeInterval)duration newSize:(CGSize)size;
- (void)lc32_rotationWindow:(UIWindow *)window didRotateFromInterfaceOrientation:(UIInterfaceOrientation)orientation
    oldSize:(CGSize)size;
@end

@implementation UIViewController (LC32NativeLegacyRotation)
- (void)lc32_rotationViewDidMoveToWindow:(UIWindow *)window shouldAppearOrDisappear:(BOOL)appear {
    [self lc32_rotationViewDidMoveToWindow:window shouldAppearOrDisappear:appear];
    if(!window || !pthread_main_np() || !RegisteredClass(object_getClass(self))) return;
    [Controllers() addObject:self];
    if(!startupFinished) return;
    // Revalidate deferred attachment work; a replaced or detached controller
    // must not initialize the next owner of its old window.
    __weak UIViewController *pendingController = self;
    __weak UIWindow *pendingWindow = window;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *controller = pendingController;
        UIWindow *target = pendingWindow;
        if(controller && target && ControllerForWindow(target, true) == controller)
            UpdateWindow(target, PreferredOrientation(), true);
    });
}

- (void)lc32_rotationWindow:(UIWindow *)window willRotateToInterfaceOrientation:(UIInterfaceOrientation)orientation
        duration:(NSTimeInterval)duration newSize:(CGSize)size {
    [self lc32_rotationWindow:window willRotateToInterfaceOrientation:orientation duration:duration newSize:size];
    if(RegisteredClass(object_getClass(self)) && startupFinished && LC32NativeLegacyRotationCanCallGuest())
        [self willRotateToInterfaceOrientation:orientation duration:duration];
}

- (void)lc32_rotationWindow:(UIWindow *)window didRotateFromInterfaceOrientation:(UIInterfaceOrientation)orientation
        oldSize:(CGSize)size {
    [self lc32_rotationWindow:window didRotateFromInterfaceOrientation:orientation oldSize:size];
    if(RegisteredClass(object_getClass(self)) && startupFinished && LC32NativeLegacyRotationCanCallGuest())
        [self didRotateFromInterfaceOrientation:orientation];
}
@end

@interface UIWindow (LC32NativeLegacyRotation)
- (void)lc32_updateToInterfaceOrientation:(UIInterfaceOrientation)orientation
    duration:(NSTimeInterval)duration force:(BOOL)force;
- (void)lc32_configureRootLayer:(CALayer *)root sceneTransformLayer:(CALayer *)scene
    transformLayer:(CALayer *)transform;
- (void)lc32_updateTransformLayer;
- (BOOL)lc32_windowOwnsInterfaceOrientation;
- (BOOL)lc32_windowOwnsInterfaceOrientationTransform;
- (BOOL)lc32_shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation
    checkForDismissal:(BOOL)check isRotationDisabled:(BOOL *)disabled;
+ (void)lc32_nativeLegacyWindowDidBecomeVisible:(NSNotification *)notification;
+ (void)lc32_nativeLegacyDeviceOrientationChanged:(NSNotification *)notification;
@end

@implementation UIWindow (LC32NativeLegacyRotation)
- (void)lc32_updateToInterfaceOrientation:(UIInterfaceOrientation)orientation
        duration:(NSTimeInterval)duration force:(BOOL)force {
    // Scene-owned windows do not run the old backing update as part of their
    // view rotation. Sync its extent before resizing the client and its root
    // transform afterwards, including a same-orientation scene-size change.
    // Old-policy rootless controllers retain their renderer-owned turn
    // lifecycle. Controllers without that policy only need backing updates.
    UIViewController *backingController = ControllerForWindow(self, true);
    BOOL legacy = backingController
        ? (NativeRoot(self) ||
           !UsesLegacyRotationPolicy(object_getClass(backingController)))
        : ControllerlessLegacyWindow(self);
    SEL refresh = sel_registerName("_updateTransformLayer");
    if(legacy) ((void (*)(id, SEL))objc_msgSend)(self, refresh);
    [self lc32_updateToInterfaceOrientation:orientation duration:duration force:force];
    if(legacy) ((void (*)(id, SEL))objc_msgSend)(self, refresh);
    // The fixed-canvas presentation refits around the same turn; its scale
    // is derived from the live viewport, so this never invents an extra
    // rotation or a speculative backing refresh.
    if(legacy) LC32ScheduleNativeLegacyCanvasFit(self);
}
- (void)lc32_configureRootLayer:(CALayer *)root sceneTransformLayer:(CALayer *)scene
        transformLayer:(CALayer *)transform {
    // A presented overlay suspends the renderer's rotation queries, not the
    // backing coordinate system of the window beneath it.
    if(!WindowNeedsLegacyBacking(self)) {
        [self lc32_configureRootLayer:root sceneTransformLayer:scene transformLayer:transform];
        return;
    }
    // The pre-iOS-8 compositor rotates the client in portrait window space.
    // Scene-owned windows now skip its inverse root-layer rotation and retain
    // landscape backing bounds, leaving that client sideways and clipped.
    // Select UIKit's original backing-layer setup only inside this operation;
    // the scene must still own orientation requests and events everywhere else.
    UIWindow *previous = configuringLegacyWindow;
    configuringLegacyWindow = self;
    @try {
        [self lc32_configureRootLayer:root sceneTransformLayer:scene transformLayer:transform];
    } @finally {
        configuringLegacyWindow = previous;
    }
    // A backing reconfiguration is also a viewport event for the fixed-canvas
    // presentation; the adapter owns eligibility and coalesces the refit.
    LC32ScheduleNativeLegacyCanvasFit(self);
}
- (void)lc32_updateTransformLayer {
    // UIKit re-syncs the root/transform layers after every window geometry or
    // orientation change, including the dynamic Classic-Mode viewport changes
    // that arrive without any turn. That sync is the refit point for the
    // fixed-canvas presentation; the adapter gates and coalesces the work,
    // and nothing runs synchronously inside UIKit's own update.
    [self lc32_updateTransformLayer];
    LC32ScheduleNativeLegacyCanvasFit(self);
}
- (BOOL)lc32_windowOwnsInterfaceOrientation {
    return configuringLegacyWindow == self || [self lc32_windowOwnsInterfaceOrientation];
}
- (BOOL)lc32_windowOwnsInterfaceOrientationTransform {
    return configuringLegacyWindow == self || [self lc32_windowOwnsInterfaceOrientationTransform];
}
+ (void)lc32_nativeLegacyWindowDidBecomeVisible:(NSNotification *)notification {
    UIWindow *window = [notification.object isKindOfClass:UIWindow.class]
        ? (UIWindow *)notification.object : nil;
    /* Only controller-less guest windows need this discovery: every window
     * with a registered controller is already enumerated through the
     * controller table. A main-nib window can become visible before its
     * renderer is added, so revalidate ownership on the deferred pass. */
    if(!window || !pthread_main_np() || !ControllerlessLegacyWindow(window)) return;
    [ControllerlessWindows() addObject:window];
    // The window became visible: its renderer is attached and the fixed-canvas
    // presentation can be fitted against the settled viewport.
    LC32ScheduleNativeLegacyCanvasFit(window);
    if(!startupFinished) return;
    __weak UIWindow *pendingWindow = window;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *target = pendingWindow;
        if(target && ControllerlessLegacyWindow(target))
            UpdateWindow(target, PreferredOrientation(), true);
    });
}
+ (void)load {
    if(!LC32NativeLegacyRotationEnabled()) return;
    Swizzle(self, sel_registerName("_updateToInterfaceOrientation:duration:force:"),
        @selector(lc32_updateToInterfaceOrientation:duration:force:));
    Swizzle(self, sel_registerName("_configureRootLayer:sceneTransformLayer:transformLayer:"),
        @selector(lc32_configureRootLayer:sceneTransformLayer:transformLayer:));
    Swizzle(self, sel_registerName("_updateTransformLayer"),
        @selector(lc32_updateTransformLayer));
    Swizzle(self, sel_registerName("_windowOwnsInterfaceOrientation"),
        @selector(lc32_windowOwnsInterfaceOrientation));
    Swizzle(self, sel_registerName("_windowOwnsInterfaceOrientationTransform"),
        @selector(lc32_windowOwnsInterfaceOrientationTransform));
    Swizzle(UIViewController.class,
        sel_registerName("viewDidMoveToWindow:shouldAppearOrDisappear:"),
        @selector(lc32_rotationViewDidMoveToWindow:shouldAppearOrDisappear:));
    // The scene-era callbacks retained native bookkeeping but dropped the
    // deprecated public callbacks expected by pre-iOS-6 guest controllers.
    Swizzle(UIViewController.class,
        sel_registerName("window:willRotateToInterfaceOrientation:duration:newSize:"),
        @selector(lc32_rotationWindow:willRotateToInterfaceOrientation:duration:newSize:));
    Swizzle(UIViewController.class,
        sel_registerName("window:didRotateFromInterfaceOrientation:oldSize:"),
        @selector(lc32_rotationWindow:didRotateFromInterfaceOrientation:oldSize:));
    nativeRotationQuery = (NativeRotationQuery)class_getMethodImplementation(self,
        sel_registerName("_shouldAutorotateToInterfaceOrientation:checkForDismissal:isRotationDisabled:"));
    Swizzle(self,
        sel_registerName("_shouldAutorotateToInterfaceOrientation:checkForDismissal:isRotationDisabled:"),
        @selector(lc32_shouldAutorotateToInterfaceOrientation:checkForDismissal:isRotationDisabled:));
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(lc32_nativeLegacyDeviceOrientationChanged:)
        name:UIDeviceOrientationDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(lc32_nativeLegacyWindowDidBecomeVisible:)
        name:UIWindowDidBecomeVisibleNotification object:nil];
}

- (BOOL)lc32_shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation
        checkForDismissal:(BOOL)check isRotationDisabled:(BOOL *)disabled {
    BOOL allowed = [self lc32_shouldAutorotateToInterfaceOrientation:orientation
        checkForDismissal:check isRotationDisabled:disabled];
    UIViewController *controller = ControllerForWindow(self);
    if(!allowed || !controller) return allowed;
    return QueryRotation(self, controller, orientation);
}

+ (void)lc32_nativeLegacyDeviceOrientationChanged:(NSNotification *)notification {
    (void)notification;
    // The enums use the same values (the landscape *names* are opposite).
    UIInterfaceOrientation orientation = (UIInterfaceOrientation)UIDevice.currentDevice.orientation;
    if(OrientationBit(orientation)) UpdateWindows(orientation, false);
}
@end
