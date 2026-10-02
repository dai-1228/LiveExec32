#import <AVFAudio/AVFAudio.h>
#import <Foundation/Foundation.h>
#import <LC32/LC32.h>
#import <objc/runtime.h>

#include <pthread.h>
#include <stdio.h>

/*
 * Guest-side legacy audio-interruption adapter (AUD-01 + AUD-03).
 *
 * Legacy titles drive audio interruptions through the deprecated
 * AVAudioSessionDelegate protocol: mfm's CDAudioManager init calls
 * [AVAudioSession sharedInstance] + setDelegate: as its FIRST audio
 * calls, and beginInterruption/endInterruption then suspend and
 * restore the OpenAL context and the AVAudioPlayer music.  The
 * generated AVAudioSession shim is a pure forwarder, and two defects
 * follow: the modern host never invokes the deprecated protocol, so
 * a phone call or Siri interruption permanently silences the game
 * until relaunch; and if the host class dropped setDelegate:
 * entirely, the forward raises at CDAudioManager init - a
 * launch-time abort.  (mfm's own NSNotification-based handler is dead
 * code with no selref caller; the delegate protocol is its only live
 * interruption path.)
 *
 * Keep the session delegate guest-local: setDelegate: records the
 * delegate here instead of forwarding, and a relay object observes
 * AVAudioSessionInterruptionNotification through the ordinary
 * forwarding shims (the host-center alias machinery that already
 * delivers UIApplication notifications to guest observers; the
 * notification name and user-info key are content-equal strings, and
 * the host center compares by value).  The relay converts the
 * notification back into the legacy delegate vocabulary, mirroring
 * the app's own dead handler: type 1 (Began) -> beginInterruption,
 * type 0 (Ended) -> endInterruptionWithFlags:0 when implemented,
 * else endInterruption.  The session property was historically
 * `assign`; retaining the recorded delegate is the deliberate,
 * documented deviation - legacy audio managers are process-lifetime
 * singletons, and a dangling assign slot would crash the relay.
 *
 * The AVAudioPlayer half (AUD-03) restores music after an
 * interruption: CDLongAudioSource.audioPlayerEndInterru: resumes the
 * player, but the modern host player never invokes the deprecated
 * player-delegate interruption callbacks.  The player category below
 * still forwards setDelegate: to the host - the
 * audioPlayerDidFinishPlaying:successfully: mirror delivery depends
 * on the host-side delegate remaining set - and additionally records
 * (player, delegate) pairs in weak slots.  The relay walks the
 * registry on each interruption edge and delivers
 * audioPlayerBeginInterruption:/audioPlayerEndInterruption:
 * (respondsToSelector-guarded, passing the weakly-held player).  A
 * stale player or delegate loads as nil from its weak slot and the
 * entry is discarded instead of delivered, because a call through a
 * dead guest pointer is a guest-memory crash.
 *
 * The relay is armed lazily from both adapters rather than from a
 * framework constructor: a delivery can only name a delegate that was
 * registered, and registration arms the relay first, so no
 * interruption can be missed while every constructor-time guest
 * allocation and host-mirror interaction is avoided.
 *
 * The adapter methods carry lc32_ names and replace the generated
 * forwarders from +load, following the legacy-alert adapter's
 * pattern: the generated sources cannot be edited, and a same-named
 * category would rely on formally undefined attach precedence.
 */

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#pragma clang diagnostic ignored "-Wunguarded-availability-new"

/* ------------------------------------------------------------------ */
/* Session delegate slot and player registry                            */
/* ------------------------------------------------------------------ */

/* Strong, process-lifetime session delegate slot (see header comment). */
static id LC32SessionDelegateSlot;

enum { LC32InterruptionRegistryCapacity = 16 };

/* Parallel weak slots; a NULL location marks an unused entry.  The
 * registry is touched from the main thread only in practice (legacy
 * audio managers configure everything at launch), so it carries no
 * lock of its own. */
static id LC32PlayerSlots[LC32InterruptionRegistryCapacity];
static id LC32PlayerDelegateSlots[LC32InterruptionRegistryCapacity];

static void LC32ClearRegistryEntry(unsigned index) {
    objc_storeWeak(&LC32PlayerSlots[index], nil);
    objc_storeWeak(&LC32PlayerDelegateSlots[index], nil);
    LC32PlayerSlots[index] = nil;
    LC32PlayerDelegateSlots[index] = nil;
}

static void LC32RegisterPlayerDelegate(AVAudioPlayer *player, id delegate) {
    if(!player) return;
    /* Update an existing pair for this player, pruning entries whose
     * player already deallocated along the way. */
    for(unsigned index = 0; index < LC32InterruptionRegistryCapacity;
            index++) {
        if(!LC32PlayerSlots[index]) continue;
        AVAudioPlayer *registered =
            objc_loadWeak(&LC32PlayerSlots[index]);
        if(!registered) {
            LC32ClearRegistryEntry(index);
            continue;
        }
        if(registered != player) continue;
        if(delegate) {
            objc_storeWeak(&LC32PlayerDelegateSlots[index], delegate);
        } else {
            LC32ClearRegistryEntry(index);
        }
        return;
    }
    if(!delegate) return;
    for(unsigned index = 0; index < LC32InterruptionRegistryCapacity;
            index++) {
        if(LC32PlayerSlots[index]) continue;
        objc_storeWeak(&LC32PlayerSlots[index], player);
        objc_storeWeak(&LC32PlayerDelegateSlots[index], delegate);
        return;
    }
    fprintf(stderr, "LC32: AVAudioPlayer interruption registry is full; "
            "dropping interruption delivery for one player\n");
}

static void LC32DeliverPlayerInterruption(BOOL began) {
    for(unsigned index = 0; index < LC32InterruptionRegistryCapacity;
            index++) {
        if(!LC32PlayerSlots[index]) continue;
        /* objc_loadWeak retains (and autoreleases) the result, so the
         * player and delegate stay alive through delivery even if the
         * delegate releases the player from inside the callback. */
        AVAudioPlayer *player = objc_loadWeak(&LC32PlayerSlots[index]);
        id delegate = objc_loadWeak(&LC32PlayerDelegateSlots[index]);
        if(!player || !delegate) {
            LC32ClearRegistryEntry(index);
            continue;
        }
        if(began) {
            if([delegate
                    respondsToSelector:@selector(audioPlayerBeginInterruption:)]) {
                [delegate audioPlayerBeginInterruption:player];
            }
        } else {
            if([delegate
                    respondsToSelector:@selector(audioPlayerEndInterruption:)]) {
                [delegate audioPlayerEndInterruption:player];
            }
        }
    }
}

/* ------------------------------------------------------------------ */
/* Interruption notification relay                                     */
/* ------------------------------------------------------------------ */

@interface LC32AudioSessionInterruptionRelay : NSObject
- (void)lc32_sessionInterrupted:(NSNotification *)notification;
@end

/* The host center has held selector-based observers weakly since
 * iOS 9, so the relay is kept here for the process lifetime. */
static LC32AudioSessionInterruptionRelay *LC32InterruptionRelay;
static pthread_once_t LC32InterruptionRelayOnce = PTHREAD_ONCE_INIT;

@implementation LC32AudioSessionInterruptionRelay

- (void)lc32_sessionInterrupted:(NSNotification *)notification {
    NSDictionary *userInfo = notification.userInfo;
    if(!userInfo) return;
    NSNumber *typeValue =
        [userInfo objectForKey:AVAudioSessionInterruptionTypeKey];
    if(!typeValue) return;
    const int interruptionType = [typeValue intValue];
    id sessionDelegate = LC32SessionDelegateSlot;
    if(interruptionType == 1) { /* AVAudioSessionInterruptionTypeBegan */
        if([sessionDelegate respondsToSelector:@selector(beginInterruption)]) {
            [sessionDelegate beginInterruption];
        }
        LC32DeliverPlayerInterruption(YES);
    } else if(interruptionType == 0) { /* AVAudioSessionInterruptionTypeEnded */
        if([sessionDelegate
                respondsToSelector:@selector(endInterruptionWithFlags:)]) {
            [sessionDelegate endInterruptionWithFlags:0];
        } else if([sessionDelegate
                respondsToSelector:@selector(endInterruption)]) {
            [sessionDelegate endInterruption];
        }
        /* Session reactivation (including CDAudioManager's setActive
         * retry and OpenAL context re-current) must settle before the
         * players restart, matching the historical ordering. */
        LC32DeliverPlayerInterruption(NO);
    }
}

@end

static void LC32InstallInterruptionRelay(void) {
    LC32InterruptionRelay = [[LC32AudioSessionInterruptionRelay alloc] init];
    [[NSNotificationCenter defaultCenter]
        addObserver:LC32InterruptionRelay
               selector:@selector(lc32_sessionInterrupted:)
                   name:AVAudioSessionInterruptionNotification
                 object:nil];
}

static void LC32ArmInterruptionRelay(void) {
    pthread_once(&LC32InterruptionRelayOnce, LC32InstallInterruptionRelay);
}

/* ------------------------------------------------------------------ */
/* AVAudioSession: guest-local legacy delegate                          */
/* ------------------------------------------------------------------ */

@interface AVAudioSession (LC32SessionInterruptionAdapter)
- (void)lc32_setDelegate:(id)delegate;
- (id)lc32_delegate;
@end

@implementation AVAudioSession (LC32SessionInterruptionAdapter)

+ (void)load {
    static const char *const publicNames[] = {
        "setDelegate:",
        "delegate",
    };
    static const char *const adapterNames[] = {
        "lc32_setDelegate:",
        "lc32_delegate",
    };
    for(size_t index = 0;
            index < sizeof(publicNames) / sizeof(publicNames[0]);
            index++) {
        SEL publicSelector = sel_registerName(publicNames[index]);
        Method original = class_getInstanceMethod(self, publicSelector);
        Method adapter = class_getInstanceMethod(
            self, sel_registerName(adapterNames[index]));
        if(!adapter) continue;
        if(original) {
            class_replaceMethod(self, publicSelector,
                method_getImplementation(adapter),
                method_getTypeEncoding(original));
        } else {
            /* A future generator run may skip-list these deprecated
             * selectors; install the adapter directly then. */
            class_addMethod(self, publicSelector,
                method_getImplementation(adapter),
                method_getTypeEncoding(adapter));
        }
    }
}

- (void)lc32_setDelegate:(id)delegate {
    LC32ArmInterruptionRelay();
    if(LC32SessionDelegateSlot != delegate) {
        [delegate retain];
        [LC32SessionDelegateSlot release];
        LC32SessionDelegateSlot = delegate;
    }
    /* Deliberately NOT forwarded to the host session: the modern host
     * never invokes the deprecated AVAudioSessionDelegate protocol,
     * and not forwarding removes the launch-time unrecognized-selector
     * failure mode outright.  Interruptions reach the recorded
     * delegate through the relay above instead. */
}

- (id)lc32_delegate {
    return LC32SessionDelegateSlot;
}

@end

/* ------------------------------------------------------------------ */
/* AVAudioPlayer: forward AND record for player-level resume            */
/* ------------------------------------------------------------------ */

@interface AVAudioPlayer (LC32PlayerInterruptionAdapter)
- (void)lc32_setDelegate:(id)delegate;
@end

@implementation AVAudioPlayer (LC32PlayerInterruptionAdapter)

+ (void)load {
    static const char *const publicName = "setDelegate:";
    static const char *const adapterName = "lc32_setDelegate:";
    SEL publicSelector = sel_registerName(publicName);
    Method original = class_getInstanceMethod(self, publicSelector);
    Method adapter = class_getInstanceMethod(
        self, sel_registerName(adapterName));
    if(!adapter) return;
    if(original) {
        class_replaceMethod(self, publicSelector,
            method_getImplementation(adapter),
            method_getTypeEncoding(original));
    } else {
        class_addMethod(self, publicSelector,
            method_getImplementation(adapter),
            method_getTypeEncoding(adapter));
    }
}

- (void)lc32_setDelegate:(id)delegate {
    LC32ArmInterruptionRelay();
    LC32RegisterPlayerDelegate(self, delegate);
    /* Still forward: the host player keeps invoking its delegate for
     * audioPlayerDidFinishPlaying:successfully: and the guest mirror
     * delivery depends on the host-side delegate staying set.  The
     * generated forwarder resolved _cmd itself; the adapter runs under
     * the lc32_ selector, so pin the public selector explicitly. */
    static uint64_t hostCommand __attribute__((aligned(8)));
    const uint64_t command = LC32CachedHostSelector(
        &hostCommand, @selector(setDelegate:), NO);
    LC32InvokeHostSelector(
        self.host_self, command, [delegate host_self], (uint64_t)0);
}

@end

#pragma clang diagnostic pop
