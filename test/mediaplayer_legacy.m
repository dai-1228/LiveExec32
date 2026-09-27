#import <CFNetwork/CFNetwork.h>
#import <Foundation/Foundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>

#include <stdio.h>

@interface MPMoviePlayerController (LC32MovieControlModeTest)
- (void)setMovieControlMode:(NSInteger)mode;
@end

@interface LC32MovieControlModeProbe : MPMoviePlayerController {
@public
    MPMovieControlStyle observedStyle;
}
@end

@implementation LC32MovieControlModeProbe
- (void)setControlStyle:(MPMovieControlStyle)style {
    observedStyle = style;
}
@end

static int failures;

static void check(const char *name, BOOL condition) {
    printf("%s: %s\n", name, condition ? "PASS" : "FAIL");
    failures += !condition;
}

int main(void) {
    check("socks-error-domain", kCFStreamErrorDomainSOCKS == 5);

    Class controllerClass = objc_getClass("MPMoviePlayerController");
    Method method = class_getInstanceMethod(controllerClass,
        sel_registerName("setMovieControlMode:"));
    check("movie-control-selector", method != NULL);

    Class probeClass = objc_getClass("LC32MovieControlModeProbe");
    LC32MovieControlModeProbe *probe =
        (LC32MovieControlModeProbe *)class_createInstance(probeClass, 0);
    check("movie-control-probe", probe != nil);
    if(probe) {
        [probe setMovieControlMode:2];
        check("movie-control-hidden",
            probe->observedStyle == MPMovieControlStyleNone);
        [probe setMovieControlMode:0];
        check("movie-control-default",
            probe->observedStyle == MPMovieControlStyleDefault);
        object_dispose(probe);
    }

    return failures ? 1 : 0;
}
