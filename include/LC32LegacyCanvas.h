#ifndef LC32_LEGACY_CANVAS_H
#define LC32_LEGACY_CANVAS_H

#import <Foundation/Foundation.h>

#include <stdint.h>

typedef enum {
    LC32LegacyIPadCanvasNone,
    LC32LegacyIPadCanvasDeclared,
    LC32LegacyIPadCanvasInferred,
} LC32LegacyIPadCanvasKind;

typedef struct {
    BOOL supportsPhone;
    BOOL supportsPad;
} LC32SupportedDeviceFamilies;

static inline LC32SupportedDeviceFamilies LC32BundleSupportedDeviceFamilies(
        NSBundle *bundle) {
    LC32SupportedDeviceFamilies result = {NO, NO};
    NSDictionary *info = [bundle infoDictionary];
    NSArray *families = [info objectForKey:@"UIDeviceFamily"];
    if(![families isKindOfClass:NSArray.class] || ![families count]) {
        /* UIDeviceFamily predates the iPad. Its absence in an early iOS
         * application therefore means the original phone family. */
        result.supportsPhone = [[info objectForKey:
            @"LSRequiresIPhoneOS"] boolValue];
        return result;
    }
    for(id family in families) {
        if(![family respondsToSelector:@selector(integerValue)]) continue;
        const NSInteger value = [family integerValue];
        result.supportsPhone |= value == 1;
        result.supportsPad |= value == 2;
    }
    return result;
}

static inline BOOL LC32BundleContainsLegacyLaunchImage(
        NSBundle *bundle, NSString *resourceName) {
    if(!bundle || ![resourceName isKindOfClass:NSString.class] ||
            [resourceName length] == 0) {
        return NO;
    }

    NSString *extension = [resourceName pathExtension];
    NSString *baseName = [extension length]
        ? [resourceName stringByDeletingPathExtension] : resourceName;
    if([extension length]) {
        return [bundle pathForResource:baseName ofType:extension] != nil;
    }
    return [bundle pathForResource:baseName ofType:@"png"] != nil ||
           [bundle pathForResource:baseName ofType:@"PNG"] != nil;
}

static inline BOOL LC32BundleContainsLaunchImageFromArray(
        NSBundle *bundle, id value) {
    if(![value isKindOfClass:NSArray.class]) return NO;
    for(id entry in (NSArray *)value) {
        if(![entry isKindOfClass:NSDictionary.class]) continue;
        if(LC32BundleContainsLegacyLaunchImage(
                bundle, [(NSDictionary *)entry objectForKey:
                    @"UILaunchImageName"])) {
            return YES;
        }
    }
    return NO;
}

static inline BOOL LC32BundleContainsPhoneLaunchArt(
        NSBundle *bundle, NSDictionary *info) {
    BOOL result =
        LC32BundleContainsLegacyLaunchImage(bundle, @"Default") ||
        LC32BundleContainsLegacyLaunchImage(bundle, @"Default@2x") ||
        LC32BundleContainsLegacyLaunchImage(bundle, @"Default-568h@2x") ||
        LC32BundleContainsLegacyLaunchImage(bundle, @"Default~iphone") ||
        LC32BundleContainsLegacyLaunchImage(bundle,
                                             @"Default@2x~iphone") ||
        LC32BundleContainsLegacyLaunchImage(bundle,
                                             @"Default-568h@2x~iphone");
    result |= LC32BundleContainsLegacyLaunchImage(
        bundle, [info objectForKey:@"UILaunchImageFile~iphone"]);
    /* A generic declaration can serve the phone half of a universal app. */
    result |= LC32BundleContainsLegacyLaunchImage(
        bundle, [info objectForKey:@"UILaunchImageFile"]);
    result |= LC32BundleContainsLaunchImageFromArray(
        bundle, [info objectForKey:@"UILaunchImages"]);
    result |= LC32BundleContainsLaunchImageFromArray(
        bundle, [info objectForKey:@"UILaunchImages~iphone"]);
    return result;
}

static inline BOOL LC32LaunchImageArrayContainsTallPhoneArt(id value) {
    if(![value isKindOfClass:NSArray.class]) return NO;
    for(id entry in (NSArray *)value) {
        if(![entry isKindOfClass:NSDictionary.class]) continue;
        NSString *name = [(NSDictionary *)entry objectForKey:
            @"UILaunchImageName"];
        NSString *size = [(NSDictionary *)entry objectForKey:
            @"UILaunchImageSize"];
        if(([name isKindOfClass:NSString.class] &&
                [name rangeOfString:@"568"
                            options:NSCaseInsensitiveSearch].location !=
                    NSNotFound) ||
                ([size isKindOfClass:NSString.class] &&
                [size rangeOfString:@"568"].location != NSNotFound)) {
            return YES;
        }
    }
    return NO;
}

static inline BOOL LC32BundleContainsTallVariantOfLaunchImage(
        NSBundle *bundle, id value) {
    if(![value isKindOfClass:NSString.class] || ![(NSString *)value length]) {
        return NO;
    }
    NSString *name = (NSString *)value;
    if([name rangeOfString:@"568"
                   options:NSCaseInsensitiveSearch].location != NSNotFound) {
        return YES;
    }
    NSString *extension = [name pathExtension];
    NSString *baseName = [extension length]
        ? [name stringByDeletingPathExtension] : name;
    return LC32BundleContainsLegacyLaunchImage(
               bundle, [baseName stringByAppendingString:@"-568h@2x"]) ||
           LC32BundleContainsLegacyLaunchImage(
               bundle, [baseName stringByAppendingString:
                   @"-568h@2x~iphone"]);
}

static inline BOOL LC32BundleContainsTallPhoneLaunchArt(
        NSBundle *bundle, NSDictionary *info) {
    if(LC32BundleContainsLegacyLaunchImage(
            bundle, @"Default-568h@2x") ||
            LC32BundleContainsLegacyLaunchImage(
                bundle, @"Default-568h@2x~iphone") ||
            LC32BundleContainsTallVariantOfLaunchImage(
                bundle, [info objectForKey:@"UILaunchImageFile"]) ||
            LC32BundleContainsTallVariantOfLaunchImage(
                bundle, [info objectForKey:
                    @"UILaunchImageFile~iphone"])) {
        return YES;
    }
    return LC32LaunchImageArrayContainsTallPhoneArt(
               [info objectForKey:@"UILaunchImages"]) ||
           LC32LaunchImageArrayContainsTallPhoneArt(
               [info objectForKey:@"UILaunchImages~iphone"]);
}

/* Some early App Store binaries advertise both device families even though
 * their bundle contains only an iPad UI.  On a phone-sized modern scene they
 * still require the old 768x1024 compatibility canvas.  Restrict this
 * inference to pre-iOS-8 binaries with exclusively iPad launch art so real
 * universal applications retain the phone path. */
static inline LC32LegacyIPadCanvasKind LC32BundleLegacyIPadCanvasKind(
        NSBundle *bundle, uint32_t sdkVersion) {
    NSDictionary *info = [bundle infoDictionary];
    const LC32SupportedDeviceFamilies families =
        LC32BundleSupportedDeviceFamilies(bundle);

    if(families.supportsPad && !families.supportsPhone) {
        return LC32LegacyIPadCanvasDeclared;
    }
    if(!families.supportsPad || !families.supportsPhone || sdkVersion == 0 ||
            sdkVersion >= 0x00080000) {
        return LC32LegacyIPadCanvasNone;
    }

    BOOL hasIPadLaunchArt =
        LC32BundleContainsLegacyLaunchImage(bundle, @"Default-Portrait") ||
        LC32BundleContainsLegacyLaunchImage(bundle,
                                             @"Default-Portrait@2x") ||
        LC32BundleContainsLegacyLaunchImage(bundle,
                                             @"Default-Portrait~ipad") ||
        LC32BundleContainsLegacyLaunchImage(bundle,
                                             @"Default-Portrait@2x~ipad") ||
        LC32BundleContainsLegacyLaunchImage(bundle, @"Default-Landscape") ||
        LC32BundleContainsLegacyLaunchImage(bundle,
                                             @"Default-Landscape@2x") ||
        LC32BundleContainsLegacyLaunchImage(bundle,
                                             @"Default-Landscape~ipad") ||
        LC32BundleContainsLegacyLaunchImage(bundle,
                                             @"Default-Landscape@2x~ipad");
    NSString *explicitIPadImage =
        [info objectForKey:@"UILaunchImageFile~ipad"];
    hasIPadLaunchArt |= LC32BundleContainsLegacyLaunchImage(
        bundle, explicitIPadImage);

    const BOOL hasPhoneLaunchArt =
        LC32BundleContainsPhoneLaunchArt(bundle, info);

    return hasIPadLaunchArt && !hasPhoneLaunchArt
        ? LC32LegacyIPadCanvasInferred : LC32LegacyIPadCanvasNone;
}

static inline BOOL LC32BundleNeedsLegacyIPadCanvas(
        NSBundle *bundle, uint32_t sdkVersion) {
    return LC32BundleLegacyIPadCanvasKind(bundle, sdkVersion) !=
        LC32LegacyIPadCanvasNone;
}

static inline BOOL LC32BundleUsesLandscapeOnlyPolicy(
        NSBundle *bundle, NSString *deviceOrientationKey) {
    NSDictionary *info = [bundle infoDictionary];
    NSArray *orientations = [info objectForKey:deviceOrientationKey];
    if(![orientations isKindOfClass:NSArray.class]) {
        orientations = [info objectForKey:
            @"UISupportedInterfaceOrientations"];
    }
    if([orientations isKindOfClass:NSArray.class] &&
            [orientations count] != 0) {
        for(id value in orientations) {
            if(![value isKindOfClass:NSString.class] ||
                    ![value hasPrefix:@"UIInterfaceOrientationLandscape"]) {
                return NO;
            }
        }
        return YES;
    }

    NSString *orientation = [info objectForKey:@"UIInterfaceOrientation"];
    return [orientation isKindOfClass:NSString.class] &&
        [orientation hasPrefix:@"UIInterfaceOrientationLandscape"];
}

static inline BOOL LC32BundleUsesLandscapeOnlyIPadPolicy(NSBundle *bundle) {
    return LC32BundleUsesLandscapeOnlyPolicy(
        bundle, @"UISupportedInterfaceOrientations~ipad");
}

static inline BOOL LC32BundleUsesLandscapeOnlyPhonePolicy(NSBundle *bundle) {
    return LC32BundleUsesLandscapeOnlyPolicy(
        bundle, @"UISupportedInterfaceOrientations~iphone");
}

static inline BOOL LC32BundleDeclaresStableLandscapeSide(NSBundle *bundle) {
    NSDictionary *info = [bundle infoDictionary];
    NSString *initial = [info objectForKey:@"UIInterfaceOrientation"];
    if([initial isEqualToString:@"UIInterfaceOrientationLandscapeLeft"] ||
            [initial isEqualToString:
                @"UIInterfaceOrientationLandscapeRight"]) {
        return YES;
    }

    NSArray *orientations = [info objectForKey:
        @"UISupportedInterfaceOrientations~iphone"];
    if(![orientations isKindOfClass:NSArray.class]) {
        orientations = [info objectForKey:
            @"UISupportedInterfaceOrientations"];
    }
    if([orientations count] != 1) return NO;

    NSString *onlyOrientation = [orientations firstObject];
    return [onlyOrientation isEqualToString:
                @"UIInterfaceOrientationLandscapeLeft"] ||
           [onlyOrientation isEqualToString:
                @"UIInterfaceOrientationLandscapeRight"];
}

static inline BOOL LC32BundleUsesFixedLandscapeIPadCanvas(
        NSBundle *bundle, LC32LegacyIPadCanvasKind canvasKind) {
    return canvasKind == LC32LegacyIPadCanvasInferred &&
        LC32BundleUsesLandscapeOnlyIPadPolicy(bundle);
}

/* Pre-iPhone-5 phone applications without 568-point launch art were given a
 * fixed 320x480 logical screen by iOS, even on larger devices.  SDK zero is
 * intentional here: early LC_VERSION_MIN_IPHONEOS commands encode it as
 * "n/a", whereas a missing host getter is filtered by the guest caller. */
static inline BOOL LC32BundleUsesFixedLandscapePhoneCanvas(
        NSBundle *bundle, uint32_t sdkVersion) {
    const LC32SupportedDeviceFamilies families =
        LC32BundleSupportedDeviceFamilies(bundle);
    if(!families.supportsPhone || families.supportsPad ||
            sdkVersion >= 0x00080000) {
        return NO;
    }
    NSDictionary *info = [bundle infoDictionary];
    return LC32BundleContainsPhoneLaunchArt(bundle, info) &&
        !LC32BundleContainsTallPhoneLaunchArt(bundle, info) &&
        LC32BundleUsesLandscapeOnlyPhonePolicy(bundle) &&
        LC32BundleDeclaresStableLandscapeSide(bundle);
}

/* Some pre-iOS-8 phone-only games ship 568-point launch art but continue to
 * create a 480x320 drawable at runtime. Metadata alone cannot distinguish
 * them from normal 568x320 applications, so use this only as a stable gate
 * before checking the loaded controller's exact native bounds. */
static inline BOOL LC32BundleMayRetainLegacyLandscapePhoneCanvas(
        NSBundle *bundle, uint32_t sdkVersion) {
    const LC32SupportedDeviceFamilies families =
        LC32BundleSupportedDeviceFamilies(bundle);
    if(!families.supportsPhone || families.supportsPad ||
            sdkVersion >= 0x00080000) {
        return NO;
    }
    NSDictionary *info = [bundle infoDictionary];
    return LC32BundleContainsTallPhoneLaunchArt(bundle, info) &&
        LC32BundleUsesLandscapeOnlyPhonePolicy(bundle) &&
        LC32BundleDeclaresStableLandscapeSide(bundle);
}

#endif
