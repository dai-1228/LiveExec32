#import <QuartzCore/QuartzCore.h>
#import <LC32/LC32.h>

/*
 * LC-05: the generated CADisplayLink shim forwards -setFrameInterval:
 * verbatim.  frameInterval is the pre-iOS-10 rate vocabulary: an interval
 * of 1 meant "every display refresh, i.e. 60 Hz on the devices this guest
 * surface emulates".  On a ProMotion-class host the native link is allowed
 * to fire at the panel's maximum rate for a process that never declares a
 * preferred rate, so a guest engine authored for the 60 Hz era receives
 * double-frequency callbacks: every frame crosses the host->guest bridge
 * and the engine's fixed-step accumulator silently drops the remainder
 * (slight slow-motion under sustained load) instead of pacing at the
 * device period the game was tuned for.
 *
 * Minimal, regeneration-proof fix: forward the legacy property first so
 * hosts that still honor frameInterval behave exactly as before, then pin
 * the modern -setPreferredFramesPerSecond: property to the same device
 * period (60 / interval).  The extra call is probed: when the host peer
 * does not implement the modern selector the adapter degrades to the
 * previous raw-forward behavior, so no host can regress.  Only intervals
 * 1 and 2 are pinned (60 and 30 Hz) -- the two rates every host supports
 * exactly; larger legacy intervals (20 Hz and below) have no exact
 * modern equivalent, so they keep the raw forward rather than letting the
 * host clamp preferredFramesPerSecond to a different period than the
 * guest asked for.
 *
 * mfm's CCDirectorIOSUniversal uses exactly frameInterval = 1
 * (floor(1/60 * 60)), registered in NSRunLoopCommonModes.
 */
@implementation CADisplayLink (LC32LegacyFramePacing)

- (void)setFrameInterval:(NSInteger)interval {
    static uint64_t frameIntervalSelector __attribute__((aligned(8)));
    (void)LC32InvokeHostSelector(
        self.host_self,
        LC32CachedHostSelector(&frameIntervalSelector, _cmd, NO),
        (uint64_t)interval, (uint64_t)0);

    if (interval != 1 && interval != 2) {
        return;
    }

    static uint64_t respondsSelector __attribute__((aligned(8)));
    const char responds = (char)LC32InvokeHostSelector(
        self.host_self,
        LC32CachedHostSelector(
            &respondsSelector, @selector(respondsToSelector:), NO),
        LC32GetHostSelector(@selector(setPreferredFramesPerSecond:)),
        (uint64_t)0);
    if (!responds) {
        return;
    }

    static uint64_t preferredSelector __attribute__((aligned(8)));
    (void)LC32InvokeHostSelector(
        self.host_self,
        LC32CachedHostSelector(
            &preferredSelector, @selector(setPreferredFramesPerSecond:), NO),
        (uint64_t)(60 / (int)interval), (uint64_t)0);
}

@end
