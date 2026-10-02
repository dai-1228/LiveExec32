#import <AVFoundation/AVFoundation.h>
#import <LC32/LC32.h>

/*
 * The generated AVPlayer shim mirrors the host class's iOS 10 method list,
 * so a guest `respondsToSelector:` probe of the proxy is answered from the
 * guest method table and returns YES for deprecated selectors the running
 * host may no longer implement (setAllowsAirPlayVideo: is the load-bearing
 * one for legacy games).  Forward the probe across the bridge instead, so
 * the host peer answers for itself, exactly like the generated GKPlayer
 * shim does for GameKit classes.  Scoped to AVPlayer on purpose: it is the
 * only class in the intro-video chain whose respondsToSelector answer
 * guards a subsequent bridged call (mfm probes setAllowsAirPlayVideo: in
 * the AVPlayerItem currentItem KVO handler on every ReadyToPlay).
 *
 * Risk accepted deliberately: a selector the host implements but the guest
 * method list lacks now answers YES, and a subsequent call would abort
 * through the dispatch shield as a reported crash instead of silently
 * invoking a missing guest method.  See the wave-3 report 08 and the
 * MAC-OS-VERIFY full-suite run before shipping this blanket override; the
 * fallback (guest-local deprecated-AirPlay no-ops) is documented there.
 */
@implementation AVPlayer (LC32HostProbing)
- (BOOL)respondsToSelector:(SEL)aSelector {
    static uint64_t hostSelector __attribute__((aligned(8)));
    const uint64_t selector = LC32CachedHostSelector(
        &hostSelector, _cmd, NO);
    const char answer = (char)LC32InvokeHostSelector(
        self.host_self, selector,
        LC32GetHostSelector(aSelector), (uint64_t)0);
    return answer != 0;
}
@end
