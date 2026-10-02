#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>

#include <dispatch/dispatch.h>
#include <math.h>
#include <pthread.h>
#include <signal.h>
#include <stddef.h>
#include <stdio.h>
#include <unistd.h>

/*
 * Guest-side model of the mfm 4.1.1 intro-video chain (07-video contract,
 * com.turner.mfm): the AVURLAsset -> AVPlayerItem -> AVPlayer vocabulary the
 * game exercises, plus the built-in failure exits that keep a broken video
 * from hanging the launch (every exit converges on the app's own
 * "VideoCompleted" notification, which returns the player to the menu).
 *
 *  T-0  CMTimeMake / CMTimeGetSeconds / kCMTimeInvalid ABI values (the
 *       ducking timestamp CMTimeMakeWithSeconds(0.0, 1) and the 24-byte
 *       CMTime layout the app copies with objc_msgSend_stret).
 *  T-1  AVURLAsset + loadValuesAsynchronouslyForKeys:@[@"tracks",
 *       @"playable"]: the completion block fires on a foreign thread, the
 *       game's stack block re-dispatches to the main queue, and
 *       prepareToPlayAsset enumerates the keys calling
 *       statusOfValueForKey:error:.  With a bogus asset URL (/dev/null is a
 *       file, so its child cannot exist) both keys must report
 *       AVKeyValueStatusFailed with a non-nil error -> FAILURE EXIT #1
 *       posts VideoCompleted.
 *  T-2  AVPlayerItem + AVPlayer creation, then KVO registered exactly like
 *       prepareToPlayAsset: options 5 (New|Initial) with the app's
 *       self-referential context globals, observeValueForKeyPath delivering
 *       on the guest side with the context token intact.  A failed asset
 *       must drive the item's status to Failed (FAILURE EXIT #3: New ==
 *       AVPlayerItemStatusFailed -> VideoCompleted) with a non-nil -error.
 *  T-3  AVPlayerItemDidPlayToEndTimeNotification round trip: a guest
 *       observer registered with the guest framework constant (object:nil,
 *       exactly playerItemDidReachEnd's registration) receives the posted
 *       notification and posts VideoCompleted (object:nil), the app's exit
 *       #4 shape.
 *
 * Every wait has its own deadline naming the stall point and a SIGALRM
 * watchdog backstops the run, so a dead chain FAILS instead of hanging CI.
 * MRC + blocks, modeled on dispatch_main_queue.m and kvo_bridge.m.
 */

static int failures, checks;

static void check(const char *name, BOOL passed) {
    printf("%s: %s\n", name, passed ? "PASS" : "FAIL");
    ++checks;
    failures += !passed;
}

static void watchdog(int sig) {
    (void)sig;
    const char message[] = "avfoundation-kvo-chain-watchdog: FAIL\n";
    (void)write(STDERR_FILENO, message, sizeof(message) - 1);
    _exit(2);
}

static pthread_t mainThread;
static pthread_mutex_t stateLock = PTHREAD_MUTEX_INITIALIZER;

/* T-1 state. */
static unsigned assetCompletions;
static BOOL assetCompletionOffMain;
static BOOL mainHopFired, exitOnePosted;
static BOOL tracksFailed, playableFailed;
/* T-2 state. */
typedef struct {
    unsigned count;
    BOOL wrongThread;
    BOOL contextMatched;
    BOOL hasNew;
    long newInteger; /* -1 when the New value is not an NSNumber */
} KVORecord;
static KVORecord statusRecord, rateRecord, itemRecord;
static BOOL statusFailedDelivered;
static BOOL currentItemNewIsNSNull;
/* T-3 state. */
static BOOL endNotificationFired, endWrongThread;
/* Convergence counter: every VideoCompleted post lands here. */
static unsigned videoCompletedDeliveries;

/*
 * The app's KVO contexts are self-referential __data globals
 * (off_23E558 / off_23E55C / off_23E560 each contain their own address);
 * reproduce that shape and compare by pointer identity.
 */
static void *statusContextSlot;
static void *currentItemContextSlot;
static void *rateContextSlot;

static BOOL pumpFlag(volatile BOOL *flag, double seconds,
                     const char *stallPoint) {
    const CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + seconds;
    while(!*flag && CFAbsoluteTimeGetCurrent() < deadline) {
        @autoreleasepool {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, false);
        }
    }
    if(!*flag) {
        fprintf(stderr, "avfoundation-kvo-chain: STALL: %s\n", stallPoint);
        return NO;
    }
    return YES;
}

static KVORecord snapshotRecord(KVORecord *record) {
    pthread_mutex_lock(&stateLock);
    const KVORecord result = *record;
    pthread_mutex_unlock(&stateLock);
    return result;
}

@interface LC32AVChainObserver : NSObject
@end

@implementation LC32AVChainObserver

/* 0x116a54: -[VideoPlayerViewController observeValueForKeyPath:...] */
- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
    (void)keyPath;
    (void)object;
    if(context != statusContextSlot && context != rateContextSlot &&
       context != currentItemContextSlot) {
        return; /* foreign context: the app forwards to super; nothing to do */
    }
    const BOOL onMain = pthread_equal(pthread_self(), mainThread) &&
        [NSThread isMainThread];
    id newValue = [change objectForKey:NSKeyValueChangeNewKey];
    const long newInteger = [newValue respondsToSelector:
        @selector(integerValue)] ? [newValue integerValue] : -1;
    pthread_mutex_lock(&stateLock);
    KVORecord *record = context == statusContextSlot ? &statusRecord
        : (context == rateContextSlot ? &rateRecord : &itemRecord);
    record->count++;
    record->wrongThread |= !onMain;
    record->contextMatched = YES;
    record->hasNew = newValue != nil;
    record->newInteger = newInteger;
    if(context == statusContextSlot &&
       newInteger == AVPlayerItemStatusFailed) {
        statusFailedDelivered = YES;
    }
    if(context == currentItemContextSlot && newValue != nil) {
        currentItemNewIsNSNull = [[NSNull null] isEqual:newValue];
    }
    pthread_mutex_unlock(&stateLock);
    /* FAILURE EXIT #3: status New == 2 -> assetFailedToPrepareForPlayback:
     * -> posts VideoCompleted (object:nil). */
    if(context == statusContextSlot &&
       newInteger == AVPlayerItemStatusFailed) {
        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"VideoCompleted" object:nil];
    }
}

/* 0x1164dc: -playerItemDidReachEnd: posts VideoCompleted (object:self). */
- (void)playerItemDidReachEnd:(NSNotification *)notification {
    (void)notification;
    const BOOL onMain = pthread_equal(pthread_self(), mainThread) &&
        [NSThread isMainThread];
    pthread_mutex_lock(&stateLock);
    endNotificationFired = YES;
    endWrongThread |= !onMain;
    pthread_mutex_unlock(&stateLock);
    [[NSNotificationCenter defaultCenter]
        postNotificationName:@"VideoCompleted" object:nil];
}

/* AppDelegate.onVideoCompleted (0xe7fc): the convergence point. */
- (void)onVideoCompleted:(NSNotification *)notification {
    (void)notification;
    pthread_mutex_lock(&stateLock);
    ++videoCompletedDeliveries;
    pthread_mutex_unlock(&stateLock);
}

@end

static void snapshotT1(unsigned *completions, BOOL *offMain, BOOL *exitOne,
                       BOOL *tracks, BOOL *playable) {
    pthread_mutex_lock(&stateLock);
    *completions = assetCompletions;
    *offMain = assetCompletionOffMain;
    *exitOne = exitOnePosted;
    *tracks = tracksFailed;
    *playable = playableFailed;
    pthread_mutex_unlock(&stateLock);
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    signal(SIGALRM, watchdog);
    alarm(60);
    mainThread = pthread_self();
    statusContextSlot = &statusContextSlot;
    currentItemContextSlot = &currentItemContextSlot;
    rateContextSlot = &rateContextSlot;

    NSAutoreleasePool *pool = [NSAutoreleasePool new];

    /* ---- T-0: CMTime ABI values ---- */
    check("cmtime-abi-layout",
        sizeof(CMTime) == 24 &&
        offsetof(CMTime, value) == 0 &&
        offsetof(CMTime, timescale) == 8 &&
        offsetof(CMTime, flags) == 12 &&
        offsetof(CMTime, epoch) == 16);
    const CMTime threeHalves = CMTimeMake(3, 2);
    check("cmtime-make-bits",
        threeHalves.value == 3 && threeHalves.timescale == 2 &&
        threeHalves.flags == kCMTimeFlags_Valid && threeHalves.epoch == 0);
    check("cmtime-get-seconds", CMTimeGetSeconds(threeHalves) == 1.5);
    check("cmtime-get-seconds-negative",
        CMTimeGetSeconds(CMTimeMake(-5, 4)) == -1.25);
    const double third = CMTimeGetSeconds(CMTimeMake(1, 3));
    check("cmtime-get-seconds-rational",
        third > 0.333333333333 && third < 0.333333333334);
    /* The app's ducking timestamp (onVideoReadyToPlay). */
    const CMTime duckZero = CMTimeMakeWithSeconds(0.0, 1);
    check("cmtime-make-with-seconds-zero",
        duckZero.value == 0 && duckZero.timescale == 1 &&
        duckZero.flags == kCMTimeFlags_Valid && duckZero.epoch == 0);
    check("cmtime-invalid-zero-bits",
        kCMTimeInvalid.value == 0 && kCMTimeInvalid.timescale == 0 &&
        kCMTimeInvalid.flags == 0 && kCMTimeInvalid.epoch == 0);
    check("cmtime-get-seconds-invalid-is-nan",
        isnan(CMTimeGetSeconds(kCMTimeInvalid)));
    check("cmtime-get-seconds-positive-infinity",
        CMTimeGetSeconds(kCMTimePositiveInfinity) == INFINITY);

    /* playIntroVideo registers the three app notifications before the
     * asset load starts; reproduce the VideoCompleted registration. */
    LC32AVChainObserver *observer = [[LC32AVChainObserver alloc] init];
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:observer selector:@selector(onVideoCompleted:)
        name:@"VideoCompleted" object:nil];
    [center addObserver:observer selector:@selector(playerItemDidReachEnd:)
        name:AVPlayerItemDidPlayToEndTimeNotification object:nil];

    /* ---- T-1: bogus asset URL -> loadValuesAsynchronously + Failed ---- */
    AVURLAsset *asset = [[AVURLAsset alloc] initWithURL:
        [NSURL fileURLWithPath:
            @"/dev/null/lc32-avfoundation-kvo-chain-missing.mp4"]
        options:nil];
    check("asset-created", asset != nil);
    /* setURL model: keys [tracks, playable], stack completion block that
     * only re-dispatches to the main queue (sub_1160EC). */
    NSArray *keys = [NSArray arrayWithObjects:@"tracks", @"playable", nil];
    [asset loadValuesAsynchronouslyForKeys:keys completionHandler:^{
        const BOOL offMain = ![NSThread isMainThread];
        pthread_mutex_lock(&stateLock);
        ++assetCompletions;
        assetCompletionOffMain |= offMain;
        pthread_mutex_unlock(&stateLock);
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL anyFailed = NO;
            /* prepareToPlayAsset:withKeys: enumerates the keys and gates on
             * statusOfValueForKey:error: (FAILURE EXIT #1). */
            for(NSString *key in keys) {
                NSError *keyError = nil;
                const AVKeyValueStatus status =
                    [asset statusOfValueForKey:key error:&keyError];
                const BOOL failedWith =
                    status == AVKeyValueStatusFailed && keyError != nil;
                pthread_mutex_lock(&stateLock);
                if([key isEqualToString:@"tracks"]) {
                    tracksFailed = failedWith;
                } else {
                    playableFailed = failedWith;
                }
                pthread_mutex_unlock(&stateLock);
                if(status == AVKeyValueStatusFailed) anyFailed = YES;
            }
            if(anyFailed) {
                /* assetFailedToPrepareForPlayback: -> VideoCompleted. */
                [[NSNotificationCenter defaultCenter]
                    postNotificationName:@"VideoCompleted" object:nil];
                pthread_mutex_lock(&stateLock);
                exitOnePosted = YES;
                pthread_mutex_unlock(&stateLock);
            }
            pthread_mutex_lock(&stateLock);
            mainHopFired = YES;
            pthread_mutex_unlock(&stateLock);
        });
    }];
    check("asset-load-main-hop",
        pumpFlag(&mainHopFired, 15.0,
                 "asset load completion block never delivered"));
    unsigned completions;
    BOOL offMain, exitOne, tracksOK, playableOK;
    snapshotT1(&completions, &offMain, &exitOne, &tracksOK, &playableOK);
    check("asset-completion-once", completions == 1);
    check("asset-tracks-failed-with-error", tracksOK);
    check("asset-playable-failed-with-error", playableOK);
    check("failure-exit-one-posted", exitOne);
    check("video-completed-after-exit-one",
        videoCompletedDeliveries >= 1);
    printf("asset-completion-off-main: %s\n", offMain ? "YES" : "NO");

    /* ---- T-2: AVPlayerItem + AVPlayer + guest-side status KVO ---- */
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
    check("item-created", item != nil);
    [item addObserver:observer forKeyPath:@"status"
            options:(NSKeyValueObservingOptionNew |
                     NSKeyValueObservingOptionInitial)
               context:statusContextSlot];
    BOOL statusInitial = NO;
    {
        const CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 5.0;
        while(CFAbsoluteTimeGetCurrent() < deadline &&
              snapshotRecord(&statusRecord).count == 0) {
            @autoreleasepool {
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, false);
            }
        }
        statusInitial = snapshotRecord(&statusRecord).count >= 1;
    }
    check("status-kvo-initial-delivered", statusInitial);
    const KVORecord statusInitialRecord = snapshotRecord(&statusRecord);
    check("status-kvo-context-identity", statusInitialRecord.contextMatched);
    check("status-kvo-change-new-present", statusInitialRecord.hasNew);
    check("status-kvo-valid-enum",
        statusInitialRecord.newInteger >= AVPlayerItemStatusUnknown &&
        statusInitialRecord.newInteger <= AVPlayerItemStatusFailed);

    AVPlayer *player = [AVPlayer playerWithPlayerItem:item];
    check("player-created", player != nil);
    check("player-current-item-matches",
        player.currentItem != nil &&
        (player.currentItem == item || [player.currentItem isEqual:item]));
    [player addObserver:observer forKeyPath:@"currentItem"
            options:(NSKeyValueObservingOptionNew |
                     NSKeyValueObservingOptionInitial)
               context:currentItemContextSlot];
    [player addObserver:observer forKeyPath:@"rate"
            options:(NSKeyValueObservingOptionNew |
                     NSKeyValueObservingOptionInitial)
               context:rateContextSlot];
    BOOL itemInitial = NO, rateInitial = NO;
    {
        const CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 5.0;
        while(CFAbsoluteTimeGetCurrent() < deadline &&
              (!itemInitial || !rateInitial)) {
            @autoreleasepool {
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, false);
            }
            itemInitial = snapshotRecord(&itemRecord).count >= 1;
            rateInitial = snapshotRecord(&rateRecord).count >= 1;
        }
    }
    check("current-item-kvo-initial", itemInitial);
    const KVORecord itemInitialRecord = snapshotRecord(&itemRecord);
    /* The app's gate: new != [NSNull null] wires the playback view. */
    check("current-item-new-not-nsnull",
        itemInitialRecord.hasNew && !currentItemNewIsNSNull);
    check("rate-kvo-initial", rateInitial);

    /* A failed asset must drive the item to Failed: the KVO update the
     * app turns into FAILURE EXIT #3. */
    BOOL statusFailed = NO;
    {
        const CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 15.0;
        while(CFAbsoluteTimeGetCurrent() < deadline && !statusFailed) {
            @autoreleasepool {
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
            }
            pthread_mutex_lock(&stateLock);
            statusFailed = statusFailedDelivered;
            pthread_mutex_unlock(&stateLock);
        }
    }
    check("status-kvo-failed-delivered", statusFailed);
    check("item-status-failed",
        [item status] == AVPlayerItemStatusFailed);
    check("item-error-nonnil", [item error] != nil);
    {
        const KVORecord statusFinal = snapshotRecord(&statusRecord);
        const KVORecord rateFinal = snapshotRecord(&rateRecord);
        const KVORecord itemFinal = snapshotRecord(&itemRecord);
        check("kvo-delivery-thread",
            !statusFinal.wrongThread && !rateFinal.wrongThread &&
            !itemFinal.wrongThread);
    }

    /* ---- T-3: end-notification round trip ---- */
    [[NSNotificationCenter defaultCenter]
        postNotificationName:AVPlayerItemDidPlayToEndTimeNotification
        object:item];
    check("end-notification-round-trip",
        pumpFlag(&endNotificationFired, 5.0,
                 "AVPlayerItemDidPlayToEndTimeNotification never reached "
                 "the guest observer"));
    check("end-notification-on-main", !endWrongThread);
    /* Exit #1 post + exit #3 post + the end-notification post all converge
     * on the app's VideoCompleted handler. */
    check("video-completed-converge", videoCompletedDeliveries >= 3);

    /* ---- cleanup: dealloc model (0x115c74), MRC releases ---- */
    [player removeObserver:observer forKeyPath:@"rate"];
    [player removeObserver:observer forKeyPath:@"currentItem"];
    [item removeObserver:observer forKeyPath:@"status"];
    [[NSNotificationCenter defaultCenter] removeObserver:observer];
    [player pause];
    [player release];
    [item release];
    [asset cancelLoading];
    [asset release];
    [observer release];
    [pool drain];
    alarm(0);
    printf("avfoundation-kvo-chain: %d checks, %d failures\n",
           checks, failures);
    return failures != 0;
}
