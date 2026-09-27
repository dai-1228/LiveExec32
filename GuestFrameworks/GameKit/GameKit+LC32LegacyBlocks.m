#import <GameKit/GameKit.h>
#import <LC32/LC32.h>

/*
 * Some games built with early Apple LLVM versions set BLOCK_HAS_SIGNATURE on
 * these callbacks while leaving the descriptor's signature pointer null.
 * GameKit already specifies each callback ABI, so capture the legacy block in
 * a current-compiler wrapper whose descriptor the generic host bridge can
 * parse.  Invoking the captured block in guest code does not inspect its
 * descriptor, and the wrapper's copy helper preserves its normal lifetime.
 *
 * Every block-taking legacy selector that still forwards here was verified
 * against the modern host SDK headers: the host carries
 * +[GKAchievement reportAchievements:withCompletionHandler:], the
 * GKLeaderboard category/identifier properties, GKMatchmaker's
 * inviteHandler, and GKVoiceChat's playerStateUpdateHandler as deprecated
 * but implemented selectors.  They keep forwarding.  Authentication
 * completes locally instead (see GKLocalPlayer below), following the
 * local-player adapter's documented unavailable-authentication contract.
 */

@implementation GKAchievement (LC32LegacyBlockCompatibility)

- (void)reportAchievementWithCompletionHandler:
        (void (^)(NSError *error))completionHandler {
    void (^typedHandler)(NSError *) = nil;
    if(completionHandler) {
        typedHandler = ^(NSError *error) {
            completionHandler(error);
        };
    }

    /* Modern GameKit replaces the deprecated instance API with this batch
     * class method.  Preserve the legacy one-achievement behavior. */
    [GKAchievement reportAchievements:@[self]
                 withCompletionHandler:typedHandler];
}

@end

@implementation GKLeaderboard (LC32LegacyPropertyCompatibility)

- (NSString *)category {
    return self.identifier;
}

- (void)setCategory:(NSString *)category {
    self.identifier = category;
}

@end

@implementation GKLocalPlayer (LC32LegacyBlockCompatibility)

- (void)authenticateWithCompletionHandler:
        (void (^)(NSError *error))completionHandler {
    /* The guest-local-player adapter keeps the guest unauthenticated by
     * design (isAuthenticated is stubbed NO), so legacy games must not hand
     * a completion block to the native authentication machinery in the
     * container.  Finishing the block in guest code also keeps this
     * deprecated entry point independent of whether the running host still
     * carries its implementation.  Native GameKit has always finished this
     * handler with GKErrorNotAuthenticated when sign-in cannot happen, so
     * legacy callers receive the documented unavailable-authentication
     * result without crossing the bridge.  Invoking the block in guest code
     * does not inspect its descriptor, so a null-signature legacy block
     * stays safe here too. */
    NSDictionary *userInfo = @{
        NSLocalizedDescriptionKey: @"Game Center is unavailable."
    };
    NSError *error = [NSError errorWithDomain:GKErrorDomain
                                         code:GKErrorNotAuthenticated
                                     userInfo:userInfo];
    if(completionHandler) completionHandler(error);
}

@end

@implementation GKMatchmaker (LC32LegacyBlockCompatibility)

- (void)setInviteHandler:
        (void (^)(GKInvite *acceptedInvite,
                  NSArray *playerIDsToInvite))inviteHandler {
    void (^typedHandler)(GKInvite *, NSArray *) = nil;
    if(inviteHandler) {
        typedHandler = ^(GKInvite *acceptedInvite,
                         NSArray *playerIDsToInvite) {
            inviteHandler(acceptedInvite, playerIDsToInvite);
        };
    }

    static uint64_t hostCommand __attribute__((aligned(8)));
    LC32InvokeHostSelector(
        self.host_self, LC32CachedHostSelector(&hostCommand, _cmd, NO),
        [typedHandler host_self], (uint64_t)0);
}

@end

@implementation GKVoiceChat (LC32LegacyBlockCompatibility)

- (void)setPlayerStateUpdateHandler:
        (void (^)(NSString *playerID,
                  GKVoiceChatPlayerState state))playerStateUpdateHandler {
    void (^typedHandler)(NSString *, GKVoiceChatPlayerState) = nil;
    if(playerStateUpdateHandler) {
        typedHandler = ^(NSString *playerID, GKVoiceChatPlayerState state) {
            playerStateUpdateHandler(playerID, state);
        };
    }

    static uint64_t hostCommand __attribute__((aligned(8)));
    LC32InvokeHostSelector(
        self.host_self, LC32CachedHostSelector(&hostCommand, _cmd, NO),
        [typedHandler host_self], (uint64_t)0);
}

@end
