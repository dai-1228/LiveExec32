#import <Foundation/Foundation.h>
#include <stdint.h>

typedef NS_ENUM(NSInteger, UIInterfaceOrientation) {
    UIInterfaceOrientationUnknown = 0,
    UIInterfaceOrientationPortrait = 1,
    UIInterfaceOrientationPortraitUpsideDown = 2,
    /* The landscape names are deliberately opposite UIDeviceOrientation's,
     * matching UIKit's public values exactly. */
    UIInterfaceOrientationLandscapeRight = 3,
    UIInterfaceOrientationLandscapeLeft = 4,
};

@interface UIApplication : NSObject
- (UIInterfaceOrientation)statusBarOrientation;
- (void)setStatusBarOrientation:(UIInterfaceOrientation)orientation;
- (void)setStatusBarOrientation:(UIInterfaceOrientation)orientation
                        animated:(BOOL)animated;
- (void)setStatusBarHidden:(BOOL)hidden animated:(BOOL)animated;
@end

@interface UIViewController : NSObject
- (UIInterfaceOrientation)interfaceOrientation;
@end
