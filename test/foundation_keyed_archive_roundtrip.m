#import <Foundation/Foundation.h>

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

/*
 * Keyed-archiver / persistence regression for the 32-bit guest runtime.
 *
 * Modeled on the Mutant Fridge Mayhem save chain (manifest 11): a custom
 * NSCoding class archived through NSKeyedArchiver initForWritingWithMutableData:
 * + encodeObject:forKey: + finishEncoding, written atomically into the
 * Library directory, then re-read with NSData dataWithContentsOfFile: +
 * NSKeyedUnarchiver initForReadingWithData: + decodeObjectForKey: +
 * finishDecoding.  The custom-class decode is the load-bearing probe: the
 * guest shims forward the coder to the host NSKeyedUnarchiver, so decoding
 * '$classname LC32KeyedArchiveFixture' must resolve the guest class through
 * the bridge's class mirror and dispatch initWithCoder: back into the guest.
 *
 * Also covers the third-party convenience paths (SDCachedURLResponse /
 * CBAPIRequest use +archivedDataWithRootObject: / +unarchiveObjectWithData:),
 * the NSFileManager first-run file-copy contract, an NSOutputStream→file→
 * NSInputStream persisted roundtrip, and NSUserDefaults set/read/synchronize.
 *
 * Native check: xcrun clang -fno-objc-arc
 *   foundation_keyed_archive_roundtrip.m -framework Foundation
 * Guest: lc32_guest_test(lc32-foundation-keyed-archive-roundtrip,
 *   foundation_keyed_archive_roundtrip.m, Foundation CoreFoundation).
 */

#if __has_feature(objc_arc)
#error This regression checks the manually retained save-graph contract.
#endif

static unsigned failures;

static void check(const char *name, BOOL passed) {
    printf("keyed-archive-%s: %s\n", name, passed ? "PASS" : "FAIL");
    failures += !passed;
}

/* Save-graph fixture mirroring GameSaveState: one custom class whose keyed
 * content is a nested dictionary of property-list values plus keyed
 * scalars, matching every coder vocabulary the audited app uses. */
@interface LC32KeyedArchiveFixture : NSObject <NSCoding> {
@public
    NSMutableDictionary *gameData;
    NSString *title;
    BOOL unlocked;
    int32_t coins;
    int64_t experience;
    float tiltSensitivity;
    double progress;
}
@end

@implementation LC32KeyedArchiveFixture

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:gameData forKey:@"gameData"];
    [coder encodeObject:title forKey:@"title"];
    [coder encodeBool:unlocked forKey:@"unlocked"];
    [coder encodeInt32:coins forKey:@"coins"];
    [coder encodeInt64:experience forKey:@"experience"];
    [coder encodeFloat:tiltSensitivity forKey:@"tiltSensitivity"];
    [coder encodeDouble:progress forKey:@"progress"];
}

- (id)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if(self) {
        /* The app rebuilds its mutable container unconditionally and lets a
         * corrupt archive raise; here nil is tolerated and recorded so the
         * assertion reports the decode gap instead of crashing the probe. */
        gameData = [[coder decodeObjectForKey:@"gameData"] mutableCopy];
        title = [[coder decodeObjectForKey:@"title"] copy];
        unlocked = [coder decodeBoolForKey:@"unlocked"];
        coins = [coder decodeInt32ForKey:@"coins"];
        experience = [coder decodeInt64ForKey:@"experience"];
        tiltSensitivity = [coder decodeFloatForKey:@"tiltSensitivity"];
        progress = [coder decodeDoubleForKey:@"progress"];
    }
    return self;
}

- (void)dealloc {
    [gameData release];
    [title release];
    [super dealloc];
}

@end

static LC32KeyedArchiveFixture *makeFixture(void) {
    LC32KeyedArchiveFixture *fixture = [[LC32KeyedArchiveFixture alloc] init];
    NSMutableDictionary *levels = [NSMutableDictionary dictionary];
    [levels setObject:[NSMutableArray arrayWithObjects:
        [NSNumber numberWithInt:1], [NSNumber numberWithInt:2], nil]
        forKey:@"unlocked"];
    fixture->gameData = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithObjectsAndKeys:
            levels, @"levels",
            [NSNumber numberWithFloat:0.5f], @"joystick",
            [NSNumber numberWithBool:YES], @"sound",
            @"Mutant Fridge", @"name",
            [NSNull null], @"empty",
            nil]];
    fixture->title = @"GumballSaveState.dat";
    fixture->unlocked = YES;
    fixture->coins = -12345;
    fixture->experience = INT64_C(9007199254740993);
    fixture->tiltSensitivity = 0.25f;
    fixture->progress = 0.75;
    return fixture;
}

static BOOL fixtureIntact(LC32KeyedArchiveFixture *decoded,
                          LC32KeyedArchiveFixture *original) {
    return decoded != nil &&
        [decoded isKindOfClass:[LC32KeyedArchiveFixture class]] &&
        [decoded->gameData isEqual:original->gameData] &&
        [decoded->title isEqualToString:original->title] &&
        decoded->unlocked == original->unlocked &&
        decoded->coins == original->coins &&
        decoded->experience == original->experience &&
        decoded->tiltSensitivity == original->tiltSensitivity &&
        decoded->progress == original->progress;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    NSAutoreleasePool *pool = [NSAutoreleasePool new];

    /* The save path must be a real, expanded, writable directory exactly as
     * the app constructs it (mask 1 = user domain). */
    NSArray *libraryPaths = NSSearchPathForDirectoriesInDomains(
        NSLibraryDirectory, NSUserDomainMask, YES);
    NSString *library = [libraryPaths count] ? libraryPaths[0] : nil;
    check("search-path-library",
        library != nil && [library length] > 1 &&
        ![library hasPrefix:@"~"]);
    if(!library) {
        printf("keyed-archive: no Library search path; aborting probe\n");
        [pool release];
        return failures + 1;
    }

    NSString *savePath =
        [library stringByAppendingPathComponent:
            @"lc32-keyed-archive-roundtrip.dat"];
    NSString *copyPath =
        [library stringByAppendingPathComponent:
            @"lc32-keyed-archive-roundtrip-copy.dat"];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    [fileManager removeItemAtPath:savePath error:NULL];
    [fileManager removeItemAtPath:copyPath error:NULL];

    LC32KeyedArchiveFixture *fixture = makeFixture();

    /* Exact -[AppDelegate saveState] flow: mutable data + streaming archiver
     * + encode under one root key + finishEncoding + atomic write. */
    NSMutableData *archiveData = [NSMutableData data];
    NSKeyedArchiver *archiver =
        [[NSKeyedArchiver alloc] initForWritingWithMutableData:archiveData];
    [archiver encodeObject:fixture forKey:@"GumballSaveState.dat"];
    [archiver finishEncoding];
    [archiver release];
    check("archive-nonempty",
        [archiveData length] > 8 &&
        memcmp([archiveData bytes], "bplist00", 8) == 0);
    check("archive-atomic-write",
        [archiveData writeToFile:savePath atomically:YES]);

    /* Persisted-file contract: the write is observable through NSFileManager
     * before anything reads it back. */
    check("file-exists-after-write",
        [fileManager fileExistsAtPath:savePath]);
    check("file-roundtrip-bytes",
        [[NSData dataWithContentsOfFile:savePath] isEqual:archiveData]);

    /* Exact -[AppDelegate initState] flow: dataWithContentsOfFile: +
     * streaming unarchiver + decodeObjectForKey: with default class
     * resolution (no delegate), then finishDecoding. */
    NSData *readBack = [NSData dataWithContentsOfFile:savePath];
    NSKeyedUnarchiver *unarchiver =
        [[NSKeyedUnarchiver alloc] initForReadingWithData:readBack];
    LC32KeyedArchiveFixture *decoded =
        [unarchiver decodeObjectForKey:@"GumballSaveState.dat"];
    check("custom-class-mirror-decode",
        fixtureIntact(decoded, fixture) &&
        [decoded->gameData isKindOfClass:[NSDictionary class]] &&
        [[decoded->gameData objectForKey:@"levels"]
            isKindOfClass:[NSArray class]]);
    check("decoded-class-name",
        [NSStringFromClass([decoded class])
            isEqualToString:@"LC32KeyedArchiveFixture"]);
    check("absent-key-nil",
        [unarchiver decodeObjectForKey:@"lc32.absent.key"] == nil);
    [unarchiver finishDecoding];
    [unarchiver release];
    [decoded release];

    /* Convenience coders used by SDURLCache and Chartboost retry queues. */
    NSData *convenience = [NSKeyedArchiver archivedDataWithRootObject:fixture];
    LC32KeyedArchiveFixture *convenient =
        [NSKeyedUnarchiver unarchiveObjectWithData:convenience];
    check("convenience-root-roundtrip", fixtureIntact(convenient, fixture));
    [convenient release];

    /* First-run database-copy contract: copyItemAtPath:toPath:error: then
     * verify the copy through fileExistsAtPath: and byte equality. */
    NSError *copyError = nil;
    BOOL copied = [fileManager copyItemAtPath:savePath toPath:copyPath
        error:&copyError];
    check("file-manager-copy",
        copied && [fileManager fileExistsAtPath:copyPath] &&
        [[NSData dataWithContentsOfFile:copyPath] isEqual:archiveData] &&
        copyError == nil);

    /* NSStream persistence: the same Library directory must carry an
     * NSOutputStream-written file that an NSInputStream reads back. */
    const uint8_t streamPayload[] = {0, 0xff, 0x41, 0, 0x80, 0x42};
    NSString *streamPath =
        [library stringByAppendingPathComponent:
            @"lc32-keyed-archive-roundtrip.stream"];
    [fileManager removeItemAtPath:streamPath error:NULL];
    NSOutputStream *output =
        [[NSOutputStream alloc] initToFileAtPath:streamPath append:NO];
    [output open];
    check("stream-write-open",
        [output streamStatus] == NSStreamStatusOpen &&
        [output write:streamPayload maxLength:sizeof(streamPayload)] ==
            (NSInteger)sizeof(streamPayload));
    [output close];
    [output release];
    check("stream-write-persisted",
        [fileManager fileExistsAtPath:streamPath] &&
        [[NSData dataWithContentsOfFile:streamPath]
            isEqual:[NSData dataWithBytes:streamPayload
                length:sizeof(streamPayload)]]);
    NSInputStream *input =
        [[NSInputStream alloc] initWithFileAtPath:streamPath];
    uint8_t streamBuffer[sizeof(streamPayload) + 2];
    memset(streamBuffer, 0xa5, sizeof(streamBuffer));
    [input open];
    const NSInteger streamRead =
        [input read:streamBuffer maxLength:sizeof(streamBuffer)];
    [input close];
    [input release];
    check("stream-read-persisted",
        streamRead == (NSInteger)sizeof(streamPayload) &&
        memcmp(streamBuffer, streamPayload, sizeof(streamPayload)) == 0 &&
        streamBuffer[sizeof(streamPayload)] == 0xa5);
    [fileManager removeItemAtPath:streamPath error:NULL];

    /* NSUserDefaults persistence: the app's firstRun/firstRunCoins gates and
     * preference keys ride setBool:/setFloat:/setObject: + synchronize. */
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *gateKey = @"lc32.keyedArchive.firstRun";
    NSString *coinKey = @"lc32.keyedArchive.coins";
    NSString *labelKey = @"lc32.keyedArchive.label";
    [defaults setBool:YES forKey:gateKey];
    [defaults setFloat:0.5f forKey:coinKey];
    [defaults setObject:@"roundtrip" forKey:labelKey];
    check("defaults-synchronize", [defaults synchronize]);
    check("defaults-roundtrip",
        [defaults boolForKey:gateKey] == YES &&
        [defaults floatForKey:coinKey] == 0.5f &&
        [[defaults objectForKey:labelKey] isEqualToString:@"roundtrip"]);
    [defaults removeObjectForKey:gateKey];
    [defaults removeObjectForKey:coinKey];
    [defaults removeObjectForKey:labelKey];
    [defaults synchronize];

    [fixture release];
    [fileManager removeItemAtPath:savePath error:NULL];
    [fileManager removeItemAtPath:copyPath error:NULL];
    [pool release];

    printf("keyed-archive: %s (%u failure%s)\n",
        failures ? "FAILED" : "all checks passed",
        failures, failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}
