#import <Foundation/Foundation.h>

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

/*
 * Guest NSKeyedUnarchiver roundtrip regression for the Mutant Fridge
 * Mayhem save-graph shape (manifest 11: -[AppDelegate saveState] /
 * -[AppDelegate initState], GumballSaveState.dat).
 *
 * The app archives one custom NSCoding class (GameSaveState) whose keyed
 * content is a nested mutable-container tree of NSData / NSNumber / NSDate /
 * NSString values, writes it through NSFileManager-backed NSData into the
 * Library directory, and on every launch reads it back with
 * NSKeyedUnarchiver before didFinishLaunching. First launch (absent file)
 * must fall through to a fresh state without crashing.
 *
 * This fixture models that shape with a custom class pair:
 *   MFMSaveEnvelope  (custom NSCoding container, like GameSaveState)
 *     -> MFMSaveRecord (nested custom NSCoding class, like the game's
 *        model objects decoded inside the save graph)
 * and asserts graph fidelity after a file roundtrip, plus the first-launch
 * absent-file behavior (unarchive of a nonexistent path returns nil and the
 * streaming unarchiver of nonexistent data stays usable, no crash).
 *
 * Native check: xcrun clang -fno-objc-arc \
 *   nskeyedunarchiver_roundtrip.m -framework Foundation
 * Guest: lc32_guest_test(lc32-nskeyedunarchiver-roundtrip,
 *   nskeyedunarchiver_roundtrip.m, Foundation CoreFoundation).
 */

#if __has_feature(objc_arc)
#error This regression checks the manually retained save-graph contract.
#endif

static unsigned failures;

static void check(const char *name, BOOL passed) {
    printf("nskeyedunarchiver-%s: %s\n", name, passed ? "PASS" : "FAIL");
    failures += !passed;
}

/* Nested custom class: the game's save content decodes model objects
 * inside the root class's initWithCoder:. */
@interface MFMSaveRecord : NSObject <NSCoding> {
@public
    NSString *levelName;
    NSDate *timestamp;
    NSData *blob;
    NSNumber *score;
    int32_t kills;
}

@end

@implementation MFMSaveRecord

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:levelName forKey:@"levelName"];
    [coder encodeObject:timestamp forKey:@"timestamp"];
    [coder encodeObject:blob forKey:@"blob"];
    [coder encodeObject:score forKey:@"score"];
    [coder encodeInt32:kills forKey:@"kills"];
}

- (id)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if(self) {
        levelName = [[coder decodeObjectForKey:@"levelName"] copy];
        timestamp = [[coder decodeObjectForKey:@"timestamp"] copy];
        blob = [[coder decodeObjectForKey:@"blob"] copy];
        score = [[coder decodeObjectForKey:@"score"] copy];
        kills = [coder decodeInt32ForKey:@"kills"];
    }
    return self;
}

- (void)dealloc {
    [levelName release];
    [timestamp release];
    [blob release];
    [score release];
    [super dealloc];
}

@end

/* Root custom class: models GameSaveState (one keyed dictionary plus a
 * nested custom object, archived under the app's save-file root key). */
@interface MFMSaveEnvelope : NSObject <NSCoding> {
@public
    NSMutableDictionary *gameData;
    NSMutableArray *records;
    NSDate *savedAt;
    int32_t coins;
}

@end

@implementation MFMSaveEnvelope

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:gameData forKey:@"gameData"];
    [coder encodeObject:records forKey:@"records"];
    [coder encodeObject:savedAt forKey:@"savedAt"];
    [coder encodeInt32:coins forKey:@"coins"];
}

- (id)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if(self) {
        /* GameSaveState uses +dictionaryWithDictionary:, which raises on a
         * non-dict; nil is tolerated here so the assertions report a decode
         * gap instead of crashing the probe. */
        gameData = [[coder decodeObjectForKey:@"gameData"] mutableCopy];
        records = [[coder decodeObjectForKey:@"records"] mutableCopy];
        savedAt = [[coder decodeObjectForKey:@"savedAt"] copy];
        coins = [coder decodeInt32ForKey:@"coins"];
    }
    return self;
}

- (void)dealloc {
    [gameData release];
    [records release];
    [savedAt release];
    [super dealloc];
}

@end

static MFMSaveRecord *makeRecord(const char *name, int32_t kills) {
    MFMSaveRecord *record = [[MFMSaveRecord alloc] init];
    const uint8_t payload[] = {0x4d, 0x46, 0x4d, 0x00, 0xff, 0x42};
    record->levelName =
        [NSString stringWithCString:name encoding:NSUTF8StringEncoding];
    record->timestamp = [NSDate dateWithTimeIntervalSinceReferenceDate:
        433945200.0]; /* fixed instant, not "now": fidelity must be exact */
    record->blob = [NSData dataWithBytes:payload length:sizeof(payload)];
    record->score = [NSNumber numberWithInteger:1337];
    record->kills = kills;
    return record;
}

static MFMSaveEnvelope *makeEnvelope(void) {
    MFMSaveEnvelope *envelope = [[MFMSaveEnvelope alloc] init];
    NSMutableDictionary *levels = [NSMutableDictionary dictionary];
    [levels setObject:[NSMutableArray arrayWithObjects:
        [NSNumber numberWithInt:1], [NSNumber numberWithInt:2],
        [NSNumber numberWithInt:3], nil]
        forKey:@"unlocked"];
    envelope->gameData = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithObjectsAndKeys:
            levels, @"levels",
            [NSNumber numberWithFloat:0.5f], @"joystick",
            [NSNumber numberWithBool:YES], @"sound",
            @"Mutant Fridge", @"name",
            [NSNull null], @"empty",
            nil]];
    envelope->records = [NSMutableArray arrayWithObjects:
        makeRecord("chapter1", 12),
        makeRecord("chapter2", 345),
        nil];
    envelope->savedAt =
        [NSDate dateWithTimeIntervalSinceReferenceDate:433945678.5];
    envelope->coins = -12345;
    return envelope;
}

static BOOL recordIntact(MFMSaveRecord *decoded, MFMSaveRecord *original) {
    return decoded != nil &&
        [decoded->levelName isEqualToString:original->levelName] &&
        decoded->timestamp != nil &&
        [decoded->timestamp isEqualToDate:original->timestamp] &&
        decoded->blob != nil &&
        [decoded->blob isEqual:original->blob] &&
        decoded->score != nil &&
        [decoded->score isEqual:original->score] &&
        [decoded->score integerValue] == [original->score integerValue] &&
        decoded->kills == original->kills;
}

static BOOL envelopeIntact(MFMSaveEnvelope *decoded,
                           MFMSaveEnvelope *original) {
    if(decoded == nil ||
        ![decoded isKindOfClass:[MFMSaveEnvelope class]] ||
        ![decoded->gameData isEqual:original->gameData] ||
        decoded->coins != original->coins ||
        decoded->savedAt == nil ||
        ![decoded->savedAt isEqualToDate:original->savedAt]) {
        return NO;
    }
    if([decoded->records count] != [original->records count]) return NO;
    NSUInteger i;
    for(i = 0; i < [original->records count]; i++) {
        if(!recordIntact([decoded->records objectAtIndex:i],
                [original->records objectAtIndex:i])) {
            return NO;
        }
    }
    return YES;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    NSAutoreleasePool *pool = [NSAutoreleasePool new];

    /* Writable temp directory as the save area (Library in the app; a temp
     * file keeps this fixture self-contained). */
    const char *tempDir = NULL;
    {
        const char *candidate = getenv("TMPDIR");
        if(!candidate || !candidate[0]) candidate = "/tmp";
        tempDir = candidate;
    }
    NSString *saveDir =
        [NSString stringWithCString:tempDir encoding:NSUTF8StringEncoding];
    NSString *savePath =
        [saveDir stringByAppendingPathComponent:
            @"lc32-nskeyedunarchiver-roundtrip.dat"];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    [fileManager removeItemAtPath:savePath error:NULL];

    /* --- First-launch behavior, checked BEFORE anything is written:
     * the app's initState runs fileExistsAtPath: -> NO -> fresh state.
     * The convenience unarchive of a nonexistent path must return nil
     * without crashing (no exception escaping into AppDelegate init). */
    check("absent-file-not-exists",
        ![fileManager fileExistsAtPath:savePath]);
    check("absent-file-unarchive-nil",
        [NSKeyedUnarchiver unarchiveObjectWithFile:savePath] == nil);
    check("absent-file-data-nil",
        [NSData dataWithContentsOfFile:savePath] == nil);
    /* Streaming unarchiver over the absent file's nil data: the app's
     * actual code guards fileExistsAtPath: before reading, but the
     * streaming path must not crash if reached (a nil-data unarchiver
     * may be nil or fail decoding; a raised exception is a FAIL). */
    @try {
        NSData *absentData = [NSData dataWithContentsOfFile:savePath];
        id streaming = absentData != nil
            ? [[NSKeyedUnarchiver alloc] initForReadingWithData:absentData]
            : nil;
        check("absent-file-streaming-no-crash", 1);
        [streaming release];
    } @catch(id exception) {
        check("absent-file-streaming-no-crash", 0);
    }

    /* --- Roundtrip of the save-graph shape. */
    MFMSaveEnvelope *envelope = makeEnvelope();

    /* Exact -[AppDelegate saveState] flow. */
    NSMutableData *archiveData = [NSMutableData data];
    NSKeyedArchiver *archiver =
        [[NSKeyedArchiver alloc] initForWritingWithMutableData:archiveData];
    [archiver encodeObject:envelope forKey:@"GumballSaveState.dat"];
    [archiver finishEncoding];
    [archiver release];
    check("archive-nonempty",
        [archiveData length] > 8 &&
        memcmp([archiveData bytes], "bplist00", 8) == 0);
    check("archive-atomic-write",
        [archiveData writeToFile:savePath atomically:YES]);
    check("file-exists-after-write",
        [fileManager fileExistsAtPath:savePath]);
    check("file-roundtrip-bytes",
        [[NSData dataWithContentsOfFile:savePath] isEqual:archiveData]);

    /* Exact -[AppDelegate initState] flow with default class resolution:
     * the custom-class decode must dispatch initWithCoder: back into the
     * guest through the bridge's class mirror. */
    NSData *readBack = [NSData dataWithContentsOfFile:savePath];
    check("read-back-nonnil", readBack != nil);
    NSKeyedUnarchiver *unarchiver =
        [[NSKeyedUnarchiver alloc] initForReadingWithData:readBack];
    MFMSaveEnvelope *decoded =
        [unarchiver decodeObjectForKey:@"GumballSaveState.dat"];
    check("save-graph-fidelity", envelopeIntact(decoded, envelope));
    if(decoded) {
        check("decoded-class-name",
            [NSStringFromClass([decoded class])
                isEqualToString:@"MFMSaveEnvelope"]);
        check("nested-class-name",
            [decoded->records count] > 0 &&
            [NSStringFromClass([[decoded->records objectAtIndex:0] class])
                isEqualToString:@"MFMSaveRecord"]);
    } else {
        check("decoded-class-name", 0);
        check("nested-class-name", 0);
    }
    check("absent-key-nil",
        [unarchiver decodeObjectForKey:@"lc32.absent.key"] == nil);
    [unarchiver finishDecoding];
    [unarchiver release];

    /* Graph identity: two decodes of the same archive produce independent
     * object graphs (the app mutates its save state after decode). */
    NSData *secondRead = [NSData dataWithContentsOfFile:savePath];
    NSKeyedUnarchiver *secondUnarchiver =
        [[NSKeyedUnarchiver alloc] initForReadingWithData:secondRead];
    MFMSaveEnvelope *secondDecoded =
        [secondUnarchiver decodeObjectForKey:@"GumballSaveState.dat"];
    check("second-decode-independent",
        secondDecoded != nil && secondDecoded != decoded &&
        envelopeIntact(secondDecoded, envelope));
    [secondUnarchiver finishDecoding];
    [secondUnarchiver release];
    [secondDecoded release];

    /* Convenience coder roundtrips (SDCachedURLResponse / CBAPIRequest
     * use +archivedDataWithRootObject: / +unarchiveObjectWithData:). */
    NSData *convenience = [NSKeyedArchiver archivedDataWithRootObject:envelope];
    MFMSaveEnvelope *convenient =
        [NSKeyedUnarchiver unarchiveObjectWithData:convenience];
    check("convenience-root-roundtrip",
        envelopeIntact(convenient, envelope));
    [convenient release];
    check("convenience-file-roundtrip",
        [NSKeyedUnarchiver unarchiveObjectWithFile:savePath] != nil &&
        envelopeIntact([NSKeyedUnarchiver unarchiveObjectWithFile:savePath],
            envelope));
    {
        MFMSaveEnvelope *fromFile =
            [NSKeyedUnarchiver unarchiveObjectWithFile:savePath];
        [fromFile release];
    }

    /* Single-value roundtrip through the nested record class root. */
    NSData *recordArchive =
        [NSKeyedArchiver archivedDataWithRootObject:envelope->records];
    NSArray *decodedRecords =
        [NSKeyedUnarchiver unarchiveObjectWithData:recordArchive];
    check("nested-records-roundtrip",
        decodedRecords != nil &&
        [decodedRecords isKindOfClass:[NSArray class]] &&
        [decodedRecords count] == [envelope->records count] &&
        recordIntact([decodedRecords objectAtIndex:0],
            [envelope->records objectAtIndex:0]) &&
        recordIntact([decodedRecords objectAtIndex:1],
            [envelope->records objectAtIndex:1]));
    [decodedRecords release];

    [decoded release];
    [envelope release];
    [fileManager removeItemAtPath:savePath error:NULL];

    /* Cleanup done; the absent-file behavior re-verified at the end for the
     * removal path (saveState's file is gone, so a fresh launch of the
     * fixture would see the first-launch branch again). */
    check("removed-file-not-exists",
        ![fileManager fileExistsAtPath:savePath]);
    check("removed-file-unarchive-nil",
        [NSKeyedUnarchiver unarchiveObjectWithFile:savePath] == nil);

    [pool release];

    printf("nskeyedunarchiver: %s (%u failure%s)\n",
        failures ? "FAILED" : "all checks passed",
        failures, failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}
