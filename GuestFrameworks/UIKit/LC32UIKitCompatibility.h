#ifndef LC32_UIKIT_COMPATIBILITY_H
#define LC32_UIKIT_COMPATIBILITY_H

#import <Foundation/Foundation.h>

#include <stdint.h>

/* Process-wide host policy, cached once for all guest UIKit adaptations. */
__attribute__((visibility("hidden")))
BOOL LC32GuestUIKitLegacyCompatibilityEnabled(void);

/* True when the host process runs UIKit's own pre-iOS-8 rotation and geometry
 * (effective SDK before iOS 8, without the compatibility kill switch). */
__attribute__((visibility("hidden")))
BOOL LC32GuestNativeLegacyRotationEnabled(void);

/* Shared gate for the legacy UIKit geometry contracts: portrait-ordered
 * UIScreen coordinates, the paired status-bar orientation, and the controller
 * interfaceOrientation override. Canvas hosts serve their own adapted
 * geometry and keep their existing SDK-1..7 executable population. A binary
 * with no SDK version marker predates the iOS 8 geometry change whenever the
 * effective process SDK does, so it inherits the pre-iOS-8 contract under
 * native legacy rotation. A pre-iOS-8 universal executable that declares a
 * landscape-only phone policy inherits the same contract while it executes
 * in the phone idiom: declaredLandscapePhoneCanvas is the host's live
 * answer for that class, and iPad-idiom execution keeps the normal universal
 * path. SDK-8+ executables never use legacy geometry. */
static inline BOOL LC32GuestSDKUsesLegacyGeometryContract(
        uint32_t executableSDK, BOOL canvasCompatibility,
        BOOL nativeLegacyRotation, BOOL declaredLandscapePhoneCanvas) {
    if(executableSDK >= 0x00080000) return NO;
    if(canvasCompatibility) return executableSDK != 0;
    if(nativeLegacyRotation && executableSDK == 0) return YES;
    return nativeLegacyRotation && declaredLandscapePhoneCanvas;
}

#endif
