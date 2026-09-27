#pragma once

#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Restore pre-iOS-8 guest rotation queries/callbacks and the native legacy
 * backing-layer setup, independently of modern-host canvas compensation. */
bool LC32NativeLegacyRotationEnabled(void);
void LC32PrepareNativeLegacyRotationClass(Class cls);
void LC32FinishNativeLegacyRotationStartup(void);

/* Supplied by the emulator: native layout callbacks can arrive before the
 * guest renderer is initialized or on a thread without a guest CPU context. */
BOOL LC32NativeLegacyRotationCanCallGuest(void);

/* Supplied by the UIKit adapter: the interface orientation most recently
 * requested by the guest through the pre-iOS-8 status-bar API, or
 * UIInterfaceOrientationUnknown when the application never made a request. */
UIInterfaceOrientation LC32LegacyRequestedStatusBarOrientation(void);

/* Supplied by the UIKit adapter: true when window mirrors a guest object
 * from a pre-iOS-8 executable (a missing SDK version marker counts as
 * pre-iOS-8). Native UIKit-internal windows answer NO. */
BOOL LC32NativeLegacyRotationWindowIsGuest(UIWindow *window);

/* React to a newly recorded pre-iOS-8 status-bar request. Safe to call from
 * the guest's setter bridge: startup, main-thread, and declared-mask gates
 * are applied by the rotation unit itself. */
void LC32NativeLegacyRotationRefreshRequested(UIInterfaceOrientation orientation);

#ifdef __cplusplus
}
#endif
