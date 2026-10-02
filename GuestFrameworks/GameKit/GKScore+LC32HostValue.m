#import <GameKit/GameKit.h>
#import <LC32/LC32.h>

/*
 * The guest GKScore implementation imports the SDK header whose
 * `@property(assign) int64_t value` clang auto-synthesizes into direct
 * guest-ivar accessors.  Instances allocated through the forwarding shim
 * are mirror-backed, though, and reportScoreWithCompletionHandler:
 * forwards self.host_self to the host GKScore whose value was therefore
 * never set: every score report silently submitted an empty value (the
 * GKSCORE-01 fidelity gap; the fatal-abort theory was already refuted by
 * the built binary, which contains the synthesized accessors).
 *
 * The minimal, regeneration-proof fix is this pair of forwarding
 * accessors.  A category method overrides the auto-synthesized one at
 * runtime, the ARM32 int64 argument and result already ride the bridge's
 * 64-bit register transport like every other scalar shim property, and no
 * adapter state is required.  The guest keeps working whether or not a
 * future pass wires real Game Center authentication.
 */
@implementation GKScore (LC32HostValueCompatibility)

- (int64_t)value {
    static uint64_t hostCommand __attribute__((aligned(8)));
    return (int64_t)LC32InvokeHostSelector(
        self.host_self, LC32CachedHostSelector(&hostCommand, _cmd, NO),
        (uint64_t)0);
}

- (void)setValue:(int64_t)value {
    static uint64_t hostCommand __attribute__((aligned(8)));
    (void)LC32InvokeHostSelector(
        self.host_self, LC32CachedHostSelector(&hostCommand, _cmd, NO),
        (uint64_t)value, (uint64_t)0);
}

@end
