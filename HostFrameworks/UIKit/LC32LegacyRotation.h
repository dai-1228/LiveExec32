#pragma once

#import <UIKit/UIKit.h>

/* CAEAGLLayer is declared by QuartzCore/OpenGLES; this header only needs
 * the object type for the drawable-adoption hook below. */
@class CAEAGLLayer;

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

/* Supplied by the UIKit adapter: schedule the fixed-canvas presentation fit
 * (uniform MIN scale plus centering composed onto the window layer's
 * sublayer transform) for a window that just reported a geometry or
 * orientation event.  The adapter re-checks the runtime-declared landscape
 * phone-canvas class and the declared-universal class, the window shape
 * each class serves (controller-less for the former, both for the latter),
 * and the live viewport, and coalesces the work onto the main queue; the
 * call is cheap for processes outside the classes, which never leave the
 * static gates. */
void LC32ScheduleNativeLegacyCanvasFit(UIWindow *window);

/* Supplied by the UIKit adapter: adopt the canonical phone-canvas bounds
 * for the drawable view that is about to allocate CAEAGLLayer renderbuffer
 * storage.  The runtime-declared canvas class can reach this allocation
 * with scene-sized launch bounds because the application's first UIScreen
 * read precedes the status-bar request that defines the class; the adapter
 * re-fits the view before storage is allocated so the renderbuffer, the
 * read-back viewport, and the engine's fixed projection agree.  The
 * declared-universal class re-fits to its own 480/568-point canvas the
 * same way, leaves views authored at or below canvas size untouched, and
 * records the drawable layer so the measured fit can target the rendered
 * content of controller-backed windows.  Returns whether the view was
 * re-fitted. */
BOOL LC32UIKitAdoptNativeLegacyCanvasDrawable(CAEAGLLayer *drawable);

/* React to a newly recorded pre-iOS-8 status-bar request. Safe to call from
 * the guest's setter bridge: startup, main-thread, and declared-mask gates
 * are applied by the rotation unit itself. */
void LC32NativeLegacyRotationRefreshRequested(UIInterfaceOrientation orientation);

#ifdef __cplusplus
}
#endif
