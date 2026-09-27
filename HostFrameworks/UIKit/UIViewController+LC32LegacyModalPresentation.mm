#import <UIKit/UIKit.h>

/*
 * The guest UIKit shim forwards the pre-iOS-6 modal presentation vocabulary
 * by selector name, so the call resolves against whichever implementation
 * the current host UIKit carries for those selectors.  Modern UIKit no
 * longer implements that vocabulary with the tolerant semantics the modal
 * era documented, and an exception raised midway through a bridged call
 * terminates the whole process without any guest crash report, because the
 * guest fault machinery only covers signals raised inside the emulated CPU.
 *
 * Restore the documented iOS 5 behavior on the host: presenting forwards to
 * the modern API, and dismissing is a no-op unless a presentation actually
 * exists.  Nothing outside a legacy guest explicitly sends these selectors,
 * so the methods are their own gate.
 */

@implementation UIViewController (LC32LegacyModalPresentation)

- (void)presentModalViewController:(UIViewController *)controller
        animated:(BOOL)animated {
    if(!controller) return;
    [self presentViewController:controller
                        animated:animated
                      completion:nil];
}

- (void)dismissModalViewControllerAnimated:(BOOL)animated {
    if(!self.presentedViewController) return;
    [self dismissViewControllerAnimated:animated completion:nil];
}

@end
