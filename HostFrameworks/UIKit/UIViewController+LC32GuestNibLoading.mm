#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "bridge.h"

#include <stdio.h>
#include <stdlib.h>

/*
 * App-defined guest view controllers can be presented without implementing
 * -loadView.  Their inherited UIKit loader then derives a nib name from the
 * class (or uses the name passed to initWithNibName:bundle:) and searches
 * the host process's bundles for it.  A legacy guest's nib lives in its
 * application bundle, which the host's main bundle (the container) does not
 * contain, so that search resolves against the wrong bundle: an explicitly
 * named missing nib raises "Could not load NIB in bundle" mid-presentation,
 * and even the class-name fallback never consults the bundle the legacy
 * application actually shipped.
 *
 * Restore the legacy resolution for guest-backed controllers: look the nib
 * up in the guest bundle (the bundle whose resources the guest's own
 * Foundation reports as its main bundle), load it tolerantly so a decode
 * failure degrades instead of raising, and when no such nib exists install
 * a plain programmatic view, matching the documented nil-nib-name fallback.
 * The inherited host loader is never consulted for these receivers.
 *
 * Controllers with their own -loadView implementation never reach this
 * hook: native subclasses keep their own method, and a guest class's
 * mirrored -loadView is re-bound by LC32UIKitPrepareGuestClass before this
 * base implementation could see the receiver.  Native-only controllers are
 * passed to the original implementation untouched, so the hook is its own
 * gate on the guest-backed class check.
 */

namespace {

using LoadViewImplementation = void (*)(id, SEL);
LoadViewImplementation OriginalViewControllerLoadView;

/* Reads the native view storage without dispatching through a guest
 * override of -viewIfLoaded, mirroring the native view helpers in
 * UIKit.mm: loadView must complete without re-entering guest code from a
 * native load callback. */
UIView *LoadedNativeView(UIViewController *controller) {
    using Getter = UIView *(*)(id, SEL);
    static Getter getter = reinterpret_cast<Getter>(
        class_getMethodImplementation(
            UIViewController.class, @selector(viewIfLoaded)));
    return controller ? getter(controller, @selector(viewIfLoaded)) : nil;
}

/* Guest-backed host classes form a contiguous band above the first native
 * superclass, matching LC32GuestClassHierarchyDefinesSelector's walk in
 * UIKit.mm. */
bool ControllerIsGuestBacked(UIViewController *controller) {
    const Class origin = object_getClass(controller);
    for(Class cls = origin; cls; cls = class_getSuperclass(cls)) {
        if([(id)cls isGuestClass]) return true;
        if(cls != origin) break;
    }
    return false;
}

NSBundle *GuestApplicationBundle(void) {
    const char *guestExecutable = getenv("LC32_GUEST_EXECUTABLE");
    /* UIKit can create internal windows and controllers before the guest
     * has been published.  A guest-backed receiver cannot exist before the
     * guest runs, but keep the readiness check with UIKit.mm's cache. */
    if(!guestExecutable || !guestExecutable[0]) return nil;
    NSString *path = [NSString stringWithUTF8String:guestExecutable];
    if(!path.length) return nil;
    return [NSBundle bundleWithPath:path.stringByDeletingLastPathComponent];
}

void LoadGuestBundleNib(UIViewController *controller,
                       NSBundle *bundle, NSString *nibName) {
    @try {
        [bundle loadNibNamed:nibName owner:controller options:nil];
    } @catch(NSException *exception) {
        /* A legacy nib can archive classes the current host no longer
         * carries or reference outlet keys the mirrored class does not
         * expose.  The guest's own Foundation treats a failed nib load as
         * a nil result (LegacyNibLoading.mm); present an empty view rather
         * than propagating the exception into the bridged presentation. */
        fprintf(stderr,
            "LC32: guest nib %s for %s failed to load (%s): %s\n",
            nibName.UTF8String,
            class_getName(object_getClass(controller)),
            exception.name.UTF8String, exception.reason.UTF8String);
    }
}

void InstallEmptyGuestView(UIViewController *controller) {
    UIView *view = [[UIView alloc] initWithFrame:CGRectZero];
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                            UIViewAutoresizingFlexibleHeight;
    controller.view = view;
}

void GuestInheritedLoadView(id self, SEL selector) {
    UIViewController *controller = self;
    if(!ControllerIsGuestBacked(controller)) {
        if(OriginalViewControllerLoadView) {
            OriginalViewControllerLoadView(self, selector);
        }
        return;
    }

    /* A guest-backed controller must never ask the host bundles for a nib:
     * the legacy application's resources are not there.  Resolve against
     * the guest bundle when it ships the nib, and fall back to the same
     * empty programmatic view the documented nil-nib path produces. */
    NSString *nibName = controller.nibName;
    if(!nibName.length) nibName = NSStringFromClass(controller.class);

    NSBundle *guestBundle = GuestApplicationBundle();
    if(guestBundle &&
            [guestBundle pathForResource:nibName ofType:@"nib"]) {
        LoadGuestBundleNib(controller, guestBundle, nibName);
        if(LoadedNativeView(controller)) return;
        fprintf(stderr,
            "LC32: guest nib %s for %s did not connect a view; "
            "using an empty view\n",
            nibName.UTF8String,
            class_getName(object_getClass(controller)));
    } else {
        fprintf(stderr,
            "LC32: guest view controller %s has no nib in the guest "
            "bundle; using an empty view\n",
            nibName.UTF8String);
    }
    InstallEmptyGuestView(controller);
}

} // namespace

@interface LC32GuestNibLoading : NSObject
@end

@implementation LC32GuestNibLoading
+ (void)load {
    Method loadView = class_getInstanceMethod(
        UIViewController.class, @selector(loadView));
    if(!loadView) return;
    /* A second install would capture our own trampoline as the original
     * and recurse on the non-guest passthrough. */
    if((IMP)GuestInheritedLoadView ==
            method_getImplementation(loadView)) return;
    OriginalViewControllerLoadView = reinterpret_cast<
        LoadViewImplementation>(method_getImplementation(loadView));
    if(!OriginalViewControllerLoadView) return;
    class_replaceMethod(UIViewController.class, @selector(loadView),
        (IMP)GuestInheritedLoadView, method_getTypeEncoding(loadView));
}
@end
