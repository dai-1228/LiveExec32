#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#include <dispatch/dispatch.h>
#include <stdarg.h>
#include <stdio.h>

/*
 * Guest-side legacy UIAlertView presentation adapter.
 *
 * Modern hosts still carry the UIAlertView class, so the generated
 * forwarders resolve, but -show never presents for a scene-based host
 * application and the delegate callbacks never fire.  Legacy titles lose
 * every dialog built on this vocabulary: mfm's data-reset confirm waits on
 * alertView:didDismissWithButtonIndex: before resetting state, the IAP
 * please-wait spinner and error notices are invisible, and the GameCenter
 * "unavailable" notice never appears.
 *
 * Keep the legacy entry points guest-local: the title, message, delegate
 * and ordered button list live in associated storage, and -show translates
 * to a UIAlertController built through the ordinary forwarding shims.
 * Button taps complete in guest code and deliver the legacy delegate
 * vocabulary.  The instance keeps its host peer only for the plain UIView
 * surface the delegates already exercise (tag/setTag:).
 *
 * The adapter methods carry lc32_ names and replace the generated
 * forwarders from +load, following the legacy-orientation adapter's
 * pattern: the generated sources cannot be edited, and a same-named
 * category would rely on formally undefined attach precedence.
 */

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

@interface LC32LegacyAlertState : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *message;
@property (nonatomic, weak) id delegate;
@property (nonatomic, strong) NSMutableArray<NSString *> *buttonTitles;
@property (nonatomic, assign) NSInteger cancelButtonIndex;
@property (nonatomic, strong) UIAlertController *controller;
/* Legacy UIView surface the delegates exercise. The adapted alert keeps no
 * host peer, so tag would otherwise forward on a nil receiver and read 0
 * forever; mfm's delegates gate on tag (data-reset checks tag == 5). */
@property (nonatomic, assign) NSInteger tag;
/* Subviews the application adds while the presentation is still animating
 * are stashed here: the adapted alert keeps no host peer, so a plain
 * -addSubview: would dispatch on a nil receiver and drop the view.  The
 * presentation completion moves the stash into the live alert view. */
@property (nonatomic, strong) NSMutableArray<UIView *> *pendingSubviews;
@end

@implementation LC32LegacyAlertState

- (instancetype)init {
    if((self = [super init])) {
        _buttonTitles = [NSMutableArray array];
        _pendingSubviews = [NSMutableArray array];
        _cancelButtonIndex = -1;
    }
    return self;
}

@end

static char LC32LegacyAlertStateKey;

static LC32LegacyAlertState *LC32LegacyAlertStateFor(UIAlertView *alert) {
    LC32LegacyAlertState *state =
        objc_getAssociatedObject(alert, &LC32LegacyAlertStateKey);
    if(!state) {
        state = [[LC32LegacyAlertState alloc] init];
        objc_setAssociatedObject(alert, &LC32LegacyAlertStateKey, state,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}

static LC32LegacyAlertState *LC32ExistingAlertState(UIAlertView *alert) {
    return objc_getAssociatedObject(alert, &LC32LegacyAlertStateKey);
}

@interface UIAlertView (LC32LegacyAlerts)
- (id)lc32_initWithTitle:(NSString *)title
                 message:(NSString *)message
                 delegate:(id)delegate
        cancelButtonTitle:(NSString *)cancelButtonTitle
        otherButtonTitles:(NSString *)otherButtonTitles, ...;
- (NSInteger)lc32_addButtonWithTitle:(NSString *)title;
- (void)lc32_setTitle:(NSString *)title;
- (void)lc32_setMessage:(NSString *)message;
- (void)lc32_setDelegate:(id)delegate;
- (id)lc32_delegate;
- (id)lc32_title;
- (id)lc32_message;
- (NSInteger)lc32_numberOfButtons;
- (NSInteger)lc32_cancelButtonIndex;
- (NSInteger)lc32_firstOtherButtonIndex;
- (id)lc32_buttonTitleAtIndex:(NSInteger)buttonIndex;
- (char)lc32_isVisible;
- (void)lc32_show;
- (void)lc32_dismissWithClickedButtonIndex:(NSInteger)buttonIndex
                                  animated:(BOOL)animated;
- (void)lc32_handleButtonTap:(NSInteger)buttonIndex;
- (UIViewController *)lc32_presenter;
- (void)lc32_addSubview:(UIView *)subview;
- (NSArray<UIView *> *)lc32_subviews;
- (void)lc32_setTag:(NSInteger)tag;
- (NSInteger)lc32_tag;
- (CGRect)lc32_bounds;
@end

@implementation UIAlertView (LC32LegacyAlerts)

+ (void)load {
    static const char *const publicNames[] = {
        "initWithTitle:message:delegate:cancelButtonTitle:otherButtonTitles:",
        "addButtonWithTitle:",
        "setTitle:",
        "setMessage:",
        "setDelegate:",
        "delegate",
        "title",
        "message",
        "numberOfButtons",
        "cancelButtonIndex",
        "firstOtherButtonIndex",
        "buttonTitleAtIndex:",
        "isVisible",
        "show",
        "dismissWithClickedButtonIndex:animated:",
        "addSubview:",
        "subviews",
        "setTag:",
        "tag",
        "bounds",
    };
    static const char *const adapterNames[] = {
        "lc32_initWithTitle:message:delegate:cancelButtonTitle:otherButtonTitles:",
        "lc32_addButtonWithTitle:",
        "lc32_setTitle:",
        "lc32_setMessage:",
        "lc32_setDelegate:",
        "lc32_delegate",
        "lc32_title",
        "lc32_message",
        "lc32_numberOfButtons",
        "lc32_cancelButtonIndex",
        "lc32_firstOtherButtonIndex",
        "lc32_buttonTitleAtIndex:",
        "lc32_isVisible",
        "lc32_show",
        "lc32_dismissWithClickedButtonIndex:animated:",
        "lc32_addSubview:",
        "lc32_subviews",
        "lc32_setTag:",
        "lc32_tag",
        "lc32_bounds",
    };
    for(size_t index = 0;
            index < sizeof(publicNames) / sizeof(publicNames[0]);
            index++) {
        Method original = class_getInstanceMethod(
            self, sel_registerName(publicNames[index]));
        Method adapter = class_getInstanceMethod(
            self, sel_registerName(adapterNames[index]));
        if(!adapter) continue;
        if(original) {
            class_replaceMethod(self,
                sel_registerName(publicNames[index]),
                method_getImplementation(adapter),
                method_getTypeEncoding(original));
        } else {
            /* A future generator run may skip-list these selectors and
             * mark them @dynamic; install the adapter directly then. */
            class_addMethod(self, sel_registerName(publicNames[index]),
                method_getImplementation(adapter),
                method_getTypeEncoding(adapter));
        }
    }
}

- (id)lc32_initWithTitle:(NSString *)title
                 message:(NSString *)message
                 delegate:(id)delegate
        cancelButtonTitle:(NSString *)cancelButtonTitle
        otherButtonTitles:(NSString *)otherButtonTitles, ... {
    LC32LegacyAlertState *state = [[LC32LegacyAlertState alloc] init];
    state.title = title;
    state.message = message;
    state.delegate = delegate;
    if(cancelButtonTitle.length) {
        state.cancelButtonIndex = 0;
        [state.buttonTitles addObject:cancelButtonTitle];
    }
    if(otherButtonTitles) {
        [state.buttonTitles addObject:otherButtonTitles];
        va_list otherTitles;
        va_start(otherTitles, otherButtonTitles);
        NSString *nextTitle;
        while((nextTitle = va_arg(otherTitles, id))) {
            [state.buttonTitles addObject:nextTitle];
        }
        va_end(otherTitles);
    }
    objc_setAssociatedObject(self, &LC32LegacyAlertStateKey, state,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return self;
}

- (NSInteger)lc32_addButtonWithTitle:(NSString *)title {
    LC32LegacyAlertState *state = LC32LegacyAlertStateFor(self);
    const NSInteger buttonIndex = (NSInteger)state.buttonTitles.count;
    if(title) [state.buttonTitles addObject:title];
    return buttonIndex;
}

- (void)lc32_setTitle:(NSString *)title {
    LC32LegacyAlertStateFor(self).title = title;
}

- (void)lc32_setMessage:(NSString *)message {
    LC32LegacyAlertStateFor(self).message = message;
}

- (void)lc32_setDelegate:(id)delegate {
    LC32LegacyAlertStateFor(self).delegate = delegate;
}

- (id)lc32_delegate {
    return LC32ExistingAlertState(self).delegate;
}

- (id)lc32_title {
    return LC32ExistingAlertState(self).title;
}

- (id)lc32_message {
    return LC32ExistingAlertState(self).message;
}

- (NSInteger)lc32_numberOfButtons {
    return (NSInteger)LC32ExistingAlertState(self).buttonTitles.count;
}

- (NSInteger)lc32_cancelButtonIndex {
    return LC32ExistingAlertState(self).cancelButtonIndex;
}

- (NSInteger)lc32_firstOtherButtonIndex {
    LC32LegacyAlertState *state = LC32ExistingAlertState(self);
    if(state.buttonTitles.count == 0) return -1;
    return state.cancelButtonIndex >= 0
        ? state.cancelButtonIndex + 1 : 0;
}

- (id)lc32_buttonTitleAtIndex:(NSInteger)buttonIndex {
    LC32LegacyAlertState *state = LC32ExistingAlertState(self);
    if(buttonIndex < 0 ||
            (NSUInteger)buttonIndex >= state.buttonTitles.count) {
        return nil;
    }
    return state.buttonTitles[buttonIndex];
}

- (char)lc32_isVisible {
    return LC32ExistingAlertState(self).controller != nil;
}

- (UIViewController *)lc32_presenter {
    UIApplication *application = [UIApplication sharedApplication];
    if(!application) return nil;
    UIWindow *window = nil;
    id<UIApplicationDelegate> applicationDelegate = application.delegate;
    if([applicationDelegate respondsToSelector:@selector(window)]) {
        window = [applicationDelegate window];
    }
    if(!window) window = application.keyWindow;
    if(!window) return nil;
    UIViewController *presenter = window.rootViewController;
    while(presenter) {
        UIViewController *presented = presenter.presentedViewController;
        if(!presented) break;
        presenter = presented;
    }
    return presenter;
}

- (void)lc32_show {
    LC32LegacyAlertState *state = LC32LegacyAlertStateFor(self);
    if(state.controller) return;
    if(![NSThread isMainThread]) {
        /* Analytics clients (Crittercism's developer-message alerts) can
         * reach -show from a network queue. Presentation off the main
         * thread raises inside the bridged call, so hop like the legacy
         * class documented for its own delegate delivery. */
        __weak UIAlertView *weakAlert = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakAlert lc32_show];
        });
        return;
    }
    UIViewController *presenter = [self lc32_presenter];
    if(!presenter) {
        fprintf(stderr, "LC32: UIAlertView show found no presenting view "
                "controller; alert not displayed\n");
        return;
    }

    id delegate = state.delegate;
    if([delegate respondsToSelector:@selector(willPresentAlertView:)]) {
        [delegate willPresentAlertView:self];
    }

    UIAlertController *controller = [UIAlertController
        alertControllerWithTitle:state.title
                         message:state.message
                  preferredStyle:UIAlertControllerStyleAlert];
    const NSUInteger buttonCount = state.buttonTitles.count;
    for(NSUInteger buttonIndex = 0; buttonIndex < buttonCount;
            buttonIndex++) {
        NSString *buttonTitle = state.buttonTitles[buttonIndex];
        if(buttonTitle.length == 0) continue;
        const UIAlertActionStyle style =
            (NSInteger)buttonIndex == state.cancelButtonIndex
                ? UIAlertActionStyleCancel
                : UIAlertActionStyleDefault;
        UIAlertAction *action = [UIAlertAction
            actionWithTitle:buttonTitle
                     style:style
                   handler:^(UIAlertAction *tappedAction) {
                       (void)tappedAction;
                       [self lc32_handleButtonTap:(NSInteger)buttonIndex];
                   }];
        [controller addAction:action];
    }
    state.controller = controller;

    [presenter presentViewController:controller
                            animated:YES
                          completion:^{
        id completionDelegate = state.delegate;
        if([completionDelegate
                respondsToSelector:@selector(didPresentAlertView:)]) {
            [completionDelegate didPresentAlertView:self];
        }
        /* Legacy code adds activity indicators to the alert after -show.
         * The stash below kept them guest-side while the presentation was
         * animating; move everything into the live alert view now and
         * center it there, matching the old alert's plain-UIView surface. */
        UIView *alertView = controller.view;
        NSArray<UIView *> *hostedSubviews = [state.pendingSubviews copy];
        for(UIView *subview in hostedSubviews) {
            [alertView addSubview:subview];
            subview.center = alertView.center;
        }
        [state.pendingSubviews removeAllObjects];
    }];
}

- (void)lc32_addSubview:(UIView *)subview {
    LC32LegacyAlertState *state = LC32LegacyAlertStateFor(self);
    if(state.controller) {
        /* The presentation completed; the live alert view can host the
         * subview directly, exactly like the legacy class's own view. */
        [state.controller.view addSubview:subview];
        subview.center = state.controller.view.center;
        return;
    }
    if(!subview) return;
    if(![state.pendingSubviews containsObject:subview]) {
        [state.pendingSubviews addObject:subview];
    }
}

- (NSArray<UIView *> *)lc32_subviews {
    LC32LegacyAlertState *state = LC32ExistingAlertState(self);
    if(state.controller) {
        return state.controller.view.subviews;
    }
    return state.pendingSubviews.count
        ? [state.pendingSubviews copy]
        : nil;
}

- (void)lc32_setTag:(NSInteger)tag {
    LC32LegacyAlertStateFor(self).tag = tag;
}

- (NSInteger)lc32_tag {
    return LC32ExistingAlertState(self).tag;
}

- (CGRect)lc32_bounds {
    /* The legacy class answered its offscreen container view's frame while
     * unshown, and callers (the IAP spinner's center math) only use it as a
     * positioning hint. Once presented, the live alert view is the more
     * faithful answer. */
    LC32LegacyAlertState *state = LC32ExistingAlertState(self);
    if(state.controller) {
        return state.controller.view.bounds;
    }
    return CGRectMake(0, 0, 320, 200);
}

- (void)lc32_handleButtonTap:(NSInteger)buttonIndex {
    LC32LegacyAlertState *state = LC32ExistingAlertState(self);
    if(!state) return;
    id delegate = state.delegate;
    if([delegate respondsToSelector:@selector(alertView:clickedButtonAtIndex:)]) {
        [delegate alertView:self clickedButtonAtIndex:buttonIndex];
    }
    /* The alert controller dismisses itself once this handler returns.
     * Deliver the dismissal pair from the guest rather than waiting for
     * the host's dismissal animation; no delegate in this vocabulary
     * distinguishes the two instants. */
    if([delegate respondsToSelector:@selector(alertView:willDismissWithButtonIndex:)]) {
        [delegate alertView:self willDismissWithButtonIndex:buttonIndex];
    }
    state.controller = nil;
    if([delegate respondsToSelector:@selector(alertView:didDismissWithButtonIndex:)]) {
        [delegate alertView:self didDismissWithButtonIndex:buttonIndex];
    }
}

- (void)lc32_dismissWithClickedButtonIndex:(NSInteger)buttonIndex
                                  animated:(BOOL)animated {
    LC32LegacyAlertState *state = LC32ExistingAlertState(self);
    if(!state) return;
    id delegate = state.delegate;
    if([delegate respondsToSelector:@selector(alertView:willDismissWithButtonIndex:)]) {
        [delegate alertView:self willDismissWithButtonIndex:buttonIndex];
    }
    UIAlertController *controller = state.controller;
    state.controller = nil;
    if(!controller) {
        /* The documented vocabulary delivered the dismissal callbacks even
         * when the receiver had never been shown. */
        if([delegate respondsToSelector:@selector(alertView:didDismissWithButtonIndex:)]) {
            [delegate alertView:self didDismissWithButtonIndex:buttonIndex];
        }
        return;
    }
    [controller dismissViewControllerAnimated:animated completion:^{
        id completionDelegate = state.delegate;
        if([completionDelegate
                respondsToSelector:@selector(alertView:didDismissWithButtonIndex:)]) {
            [completionDelegate alertView:self
                didDismissWithButtonIndex:buttonIndex];
        }
    }];
}

@end

#pragma clang diagnostic pop
