#import <UIKit/UIKit.h>
#import <CoreText/CoreText.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct FontTestBuildVersion { uint32_t platform, version; };
extern uint32_t dyld_get_program_sdk_version(void);
extern bool dyld_program_sdk_at_least(struct FontTestBuildVersion version);
static unsigned failures;
static uint32_t originalSDK;
static BOOL originalAtLeast11;

static void check(NSString *name, BOOL passed) {
    printf("legacy-font-%s: %s\n", name.UTF8String, passed ? "PASS" : "FAIL");
    failures += !passed;
}

static BOOL finiteTransform(CGAffineTransform m) {
    return isfinite(m.a) && isfinite(m.b) && isfinite(m.c) &&
        isfinite(m.d) && isfinite(m.tx) && isfinite(m.ty);
}

static BOOL finiteFont(UIFont *font) {
    if(!font || !isfinite(font.pointSize) || font.pointSize <= 0 ||
            !isfinite(font.ascender) || !isfinite(font.descender) ||
            !isfinite(font.leading) || !isfinite(font.lineHeight) ||
            !isfinite(font.capHeight) || !isfinite(font.xHeight) ||
            font.lineHeight <= 0) return NO;
    if(CFGetTypeID((__bridge CFTypeRef)font) != CTFontGetTypeID()) return NO;
    CTFontRef ct = (__bridge CTFontRef)font;
    return isfinite(CTFontGetSize(ct)) && CTFontGetSize(ct) > 0 &&
        isfinite(CTFontGetAscent(ct)) && isfinite(CTFontGetDescent(ct)) &&
        isfinite(CTFontGetLeading(ct)) && CTFontGetUnitsPerEm(ct) != 0 &&
        finiteTransform(CTFontGetMatrix(ct));
}

static void describeBadFont(NSString *path, UIFont *font) {
    printf("legacy-font-invalid: %s name=%s size=%g ascent=%g descent=%g "
        "line=%g descriptor=%s\n", path.UTF8String, font.fontName.UTF8String,
        font.pointSize, font.ascender, font.descender, font.lineHeight,
        font.fontDescriptor.fontAttributes.description.UTF8String);
}

static BOOL actualBuildVersionMatches(uint32_t sdk) {
    const struct mach_header_64 *header =
        (const struct mach_header_64 *)_dyld_get_image_header(0);
    if(header->magic != MH_MAGIC_64) return NO;
    const unsigned char *cursor = (const unsigned char *)(header + 1);
    const unsigned char *end = cursor + header->sizeofcmds;
    for(uint32_t i = 0; i < header->ncmds; ++i) {
        if((size_t)(end - cursor) < sizeof(struct load_command)) return NO;
        const struct load_command *command = (const void *)cursor;
        if(command->cmdsize < sizeof(*command) ||
                command->cmdsize > (size_t)(end - cursor)) return NO;
        if(command->cmd == LC_BUILD_VERSION &&
                command->cmdsize >= sizeof(struct build_version_command)) {
            const struct build_version_command *build = (const void *)command;
            printf("legacy-font-build: platform=%u minos=0x%08x sdk=0x%08x\n",
                build->platform, build->minos, build->sdk);
            return (build->platform == PLATFORM_IOS ||
                build->platform == PLATFORM_IOSSIMULATOR) &&
                build->minos == 0x000f0000 && build->sdk == sdk;
        }
        cursor += command->cmdsize;
    }
    return NO;
}

static void checkSDKUnchanged(void) {
    check(@"process-sdk-unchanged", dyld_get_program_sdk_version() == originalSDK &&
        dyld_program_sdk_at_least((struct FontTestBuildVersion){
            PLATFORM_IOS, 0x000b0000}) == originalAtLeast11);
}

static void checkValidFonts(void) {
    for(UIFont *font in @[[UIFont systemFontOfSize:17],
            [UIFont boldSystemFontOfSize:17], [UIFont fontWithName:@"Helvetica" size:23]]) {
        UIFontDescriptor *descriptor = font.fontDescriptor;
        NSDictionary *attributes = [descriptor.fontAttributes copy];
        UIFont *roundtrip = [UIFont fontWithDescriptor:descriptor size:font.pointSize];
        check([@"valid-font-unchanged-" stringByAppendingString:font.fontName],
            finiteFont(font) && finiteFont(roundtrip) &&
            [attributes isEqual:descriptor.fontAttributes] &&
            [font.fontName isEqual:roundtrip.fontName] &&
            fabs(font.pointSize - roundtrip.pointSize) < 0.001 &&
            fabs(font.ascender - roundtrip.ascender) < 0.001 &&
            fabs(font.descender - roundtrip.descender) < 0.001 &&
            fabs(font.lineHeight - roundtrip.lineHeight) < 0.001 &&
            descriptor.symbolicTraits == roundtrip.fontDescriptor.symbolicTraits);
    }
}

static void checkFontMatrix(void) {
    /* Default APIs can follow a different path from the trait-taking forms. */
    for(UIFontTextStyle style in @[UIFontTextStyleHeadline, UIFontTextStyleBody]) {
        UIFont *direct = [UIFont preferredFontForTextStyle:style];
        UIFontDescriptor *descriptor = [UIFontDescriptor
            preferredFontDescriptorWithTextStyle:style];
        UIFont *fromDescriptor = [UIFont fontWithDescriptor:descriptor size:0];
        check([@"default-" stringByAppendingString:style],
            finiteFont(direct) && finiteFont(fromDescriptor));
        if(!finiteFont(direct)) describeBadFont(@"default-font", direct);
        if(!finiteFont(fromDescriptor)) describeBadFont(@"default-descriptor", fromDescriptor);
    }
    NSMutableArray<UIFontTextStyle> *styles = [@[
        UIFontTextStyleLargeTitle, UIFontTextStyleTitle1, UIFontTextStyleTitle2,
        UIFontTextStyleTitle3, UIFontTextStyleHeadline, UIFontTextStyleSubheadline,
        UIFontTextStyleBody, UIFontTextStyleCallout, UIFontTextStyleFootnote,
        UIFontTextStyleCaption1, UIFontTextStyleCaption2
    ] mutableCopy];
    if(@available(iOS 17.0, *)) {
        [styles addObjectsFromArray:@[UIFontTextStyleExtraLargeTitle,
            UIFontTextStyleExtraLargeTitle2]];
    }
    NSArray<UIContentSizeCategory> *categories = @[
        UIContentSizeCategoryUnspecified, UIContentSizeCategoryExtraSmall,
        UIContentSizeCategorySmall, UIContentSizeCategoryMedium,
        UIContentSizeCategoryLarge, UIContentSizeCategoryExtraLarge,
        UIContentSizeCategoryExtraExtraLarge, UIContentSizeCategoryExtraExtraExtraLarge,
        UIContentSizeCategoryAccessibilityMedium, UIContentSizeCategoryAccessibilityLarge,
        UIContentSizeCategoryAccessibilityExtraLarge,
        UIContentSizeCategoryAccessibilityExtraExtraLarge,
        UIContentSizeCategoryAccessibilityExtraExtraExtraLarge
    ];
    unsigned total = 0, invalid = 0;
    for(UIFontTextStyle style in styles) {
        unsigned styleInvalid = 0;
        for(UIContentSizeCategory category in categories) {
            ++total;
            @try {
                UITraitCollection *traits = [UITraitCollection
                    traitCollectionWithPreferredContentSizeCategory:category];
                UIFont *direct = [UIFont preferredFontForTextStyle:style
                    compatibleWithTraitCollection:traits];
                UIFontDescriptor *descriptor = [UIFontDescriptor
                    preferredFontDescriptorWithTextStyle:style
                    compatibleWithTraitCollection:traits];
                UIFont *fromDescriptor = [UIFont fontWithDescriptor:descriptor size:0];
                if(!finiteFont(direct) || !finiteFont(fromDescriptor)) {
                    ++invalid; ++styleInvalid;
                    NSString *path = [NSString stringWithFormat:@"%@/%@", style, category];
                    if(!finiteFont(direct)) describeBadFont([path stringByAppendingString:@"/font"], direct);
                    if(!finiteFont(fromDescriptor)) describeBadFont([path stringByAppendingString:@"/descriptor"], fromDescriptor);
                }
            } @catch(NSException *exception) {
                ++invalid; ++styleInvalid;
                printf("legacy-font-exception: %s/%s %s: %s\n", style.UTF8String,
                    category.UTF8String, exception.name.UTF8String, exception.reason.UTF8String);
            }
        }
        check([@"matrix-" stringByAppendingString:style], styleInvalid == 0);
    }
    printf("legacy-font-matrix: styles=%lu categories=%lu pairs=%u paths=2 invalid=%u\n",
        (unsigned long)styles.count, (unsigned long)categories.count, total, invalid);
}

static void checkOptionalDescriptorOptions(void) {
    SEL selector = sel_registerName("preferredFontDescriptorWithTextStyle:addingSymbolicTraits:options:");
    Method method = class_getClassMethod(UIFontDescriptor.class, selector);
    char type[32];
    BOOL supported = method && method_getNumberOfArguments(method) == 5;
    if(supported) {
        method_getReturnType(method, type, sizeof(type));
        supported = type[0] == '@';
        const char *arguments[] = { @encode(id), @encode(UIFontDescriptorSymbolicTraits), @encode(NSUInteger) };
        for(unsigned index = 0; supported && index < 3; ++index) {
            method_getArgumentType(method, index + 2, type, sizeof(type));
            supported = !strcmp(type, arguments[index]);
        }
    }
    if(!supported) {
        puts("legacy-font-options-factory: SKIP (optional selector absent or ABI changed)");
        return;
    }
    UIFontDescriptorSymbolicTraits traits[] = {0, 2, 0x40};
    unsigned invalid = 0;
    for(UIFontTextStyle style in @[UIFontTextStyleFootnote, UIFontTextStyleHeadline]) {
        for(unsigned index = 0; index < sizeof(traits) / sizeof(traits[0]); ++index) {
            for(NSUInteger options = 0; options < 3; ++options) {
                UIFontDescriptor *descriptor = ((id (*)(id, SEL, NSString *,
                    UIFontDescriptorSymbolicTraits, NSUInteger))objc_msgSend)(
                        UIFontDescriptor.class, selector, style, traits[index], options);
                UIFont *font = [UIFont fontWithDescriptor:descriptor size:0];
                if(!finiteFont(font)) {
                    ++invalid;
                    describeBadFont([NSString stringWithFormat:@"options/%@/0x%x/%lu",
                        style, traits[index], (unsigned long)options], font);
                }
            }
        }
    }
    check(@"optional-options-factory", invalid == 0);
    printf("legacy-font-options-matrix: styles=2 traits=3 options=3 invalid=%u\n", invalid);
}

static BOOL finiteRect(CGRect rect) {
    return isfinite(rect.origin.x) && isfinite(rect.origin.y) &&
        isfinite(rect.size.width) && isfinite(rect.size.height);
}

static BOOL visibleInWindow(UIView *view) {
    UIWindow *window = view.window;
    if(!window || !finiteRect(view.bounds)) return NO;
    CGRect visible = [view convertRect:view.bounds toView:window];
    for(UIView *ancestor = view; ancestor; ancestor = ancestor.superview) {
        if(ancestor.hidden || ancestor.alpha <= 0) return NO;
        if(ancestor.clipsToBounds)
            visible = CGRectIntersection(visible,
                [ancestor convertRect:ancestor.bounds toView:window]);
    }
    visible = CGRectIntersection(visible, window.bounds);
    return finiteRect(visible) && !CGRectIsEmpty(visible) && !CGRectIsNull(visible);
}

static BOOL nativeWindowTransformPolicy(void) {
    SEL selector = sel_registerName("_transformLayerRotationsAreEnabled");
    return [UIWindow respondsToSelector:selector] &&
        ((BOOL (*)(id, SEL))objc_msgSend)(UIWindow.class, selector);
}

static unsigned checkAlertLabels(UIView *view, NSString *name,
                                NSSet<NSString *> *actionTitles,
                                NSMutableSet<NSString *> *visibleActions) {
    unsigned labels = 0;
    if([view isKindOfClass:[UILabel class]] && ((UILabel *)view).text.length) {
        UILabel *label = (UILabel *)view;
        ++labels;
        CGRect rect = label.frame;
        printf("legacy-font-label-layout: %s text=%s frame=%s visible=%d hidden=%d alpha=%g\n",
            name.UTF8String, label.text.UTF8String, NSStringFromCGRect(rect).UTF8String,
            visibleInWindow(label), label.hidden, label.alpha);
        check([name stringByAppendingString:@"-label-finite"], finiteFont(label.font) &&
            finiteRect(rect) &&
            rect.size.width > 0 && rect.size.height > 0);
        if(!finiteFont(label.font)) describeBadFont(name, label.font);
        // A collapsed native action group can leave several eight-point-wide
        // action labels onscreen, each rendering only an ellipsis. Visibility
        // alone is not enough to prove that the menu's words are readable.
        if([actionTitles containsObject:label.text] && visibleInWindow(label) &&
                label.bounds.size.width >= 50)
            [visibleActions addObject:label.text];
    }
    for(UIView *child in view.subviews)
        labels += checkAlertLabels(child, name, actionTitles, visibleActions);
    return labels;
}

static unsigned checkEmptySheetHeaders(UIView *view) {
    unsigned headers = 0;
    if([view isKindOfClass:UIScrollView.class] &&
            [NSStringFromClass(view.class) containsString:@"InterfaceActionGroupHeaderScrollView"]) {
        UIScrollView *header = (UIScrollView *)view;
        ++headers;
        printf("legacy-font-empty-sheet-header: bounds=%s content=%s\n",
            NSStringFromCGRect(header.bounds).UTF8String,
            NSStringFromCGSize(header.contentSize).UTF8String);
        // The untitled/unmessaged sheet has no header content. Allow a little
        // native spacing, but not hundreds of empty points above its actions.
        check(@"untitled-sheet-header-content-fit", finiteRect(header.bounds) &&
            isfinite(header.contentSize.height) &&
            header.bounds.size.height <= header.contentSize.height + 20);
    }
    for(UIView *child in view.subviews) headers += checkEmptySheetHeaders(child);
    return headers;
}

@interface FontTestAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) UIViewController *presenter;
@property(nonatomic, strong) UIBarButtonItem *sheetAnchor;
@property(nonatomic, copy) NSString *language;
@property(nonatomic) BOOL repeatAlerts;
@property(nonatomic) unsigned completedPresentations;
@property(nonatomic) unsigned completedDismissals;
@property(nonatomic) BOOL originalWindowPolicy;
@end
@implementation FontTestAppDelegate
- (void)finish {
    checkSDKUnchanged();
    printf("legacy-font-regression: %s sdk=0x%08x language=%s\n",
        failures ? "FAIL" : "PASS", originalSDK, self.language.UTF8String);
    exit(failures ? 1 : 0);
}

- (void)finishAfterNestedModalControl {
    // The alert completion runs inside UIKit's native dismissal stack. Start
    // an unrelated modal dismissal synchronously there: an alert-only policy
    // scope must not leak into this nested, ordinary controller transition.
    UIViewController *modal = [[UIViewController alloc] init];
    modal.modalPresentationStyle = UIModalPresentationFullScreen;
    modal.view.backgroundColor = [UIColor lightGrayColor];
    __block unsigned alertCompletions = 0, modalCompletions = 0;
    BOOL ordinaryOnly = [[NSUserDefaults standardUserDefaults] boolForKey:@"LC32OrdinaryModalOnly"];
    void (^dismissOrdinaryModal)(void) = ^{
        [modal dismissViewControllerAnimated:NO completion:^{
            ++modalCompletions;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10),
                dispatch_get_main_queue(), ^{
                    check(@"nested-dismissal-completions-once",
                        alertCompletions == (ordinaryOnly ? 0 : 1) && modalCompletions == 1);
                    check(@"ordinary-modal-dismissed", self.presenter.presentedViewController == nil &&
                        modal.presentingViewController == nil &&
                        self.presenter.view.window == self.window && visibleInWindow(self.presenter.view));
                    check(@"nested-native-window-policy-unchanged",
                        nativeWindowTransformPolicy() == self.originalWindowPolicy);
                    [self finish];
                });
        }];
    };
    [self.presenter presentViewController:modal animated:NO completion:^{
        check(@"ordinary-modal-presented", modal.presentingViewController == self.presenter &&
            modal.view.window == self.window && visibleInWindow(modal.view));
        check(@"ordinary-modal-window-policy-unchanged",
            nativeWindowTransformPolicy() == self.originalWindowPolicy);
        if(ordinaryOnly) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4),
                dispatch_get_main_queue(), dismissOrdinaryModal);
            return;
        }
        void (^presentInnerAlert)(void) = ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Nested control"
            message:@"Dismissing this alert must not change the ordinary modal's policy."
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Continue"
            style:UIAlertActionStyleDefault handler:nil]];
        [modal presentViewController:alert animated:YES completion:^{
            [alert dismissViewControllerAnimated:YES completion:^{
                ++alertCompletions;
                check(@"nested-alert-dismissed", modal.presentedViewController == nil &&
                    modal.view.window == self.window && visibleInWindow(modal.view));
                dismissOrdinaryModal();
            }];
        }];
        };
        if([[NSUserDefaults standardUserDefaults] boolForKey:@"LC32SettleOrdinaryModal"])
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4),
                dispatch_get_main_queue(), presentInnerAlert);
        else presentInnerAlert();
    }];
}

- (void)showAlertCase:(unsigned)index {
    NSArray<NSString *> *names = @[@"alert", @"textfield-alert",
        @"untitled-sheet", @"options-sheet"];
    NSString *name = names[index];
    BOOL sheet = index >= 2;
    NSString *title = index == 2 ? nil : index == 3 ? @"Options" :
        @"Kiểm tra phông chữ / Font test";
    NSString *message = sheet ? nil :
        @"Native alert title and message must have finite baselines.";
    printf("legacy-font-create: %s\n", name.UTF8String);
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
        message:message preferredStyle:sheet ? UIAlertControllerStyleActionSheet :
            UIAlertControllerStyleAlert];
    if(index == 1) {
        // Match Address Explorer's UIKit path without requesting clipboard access.
        [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
            puts("legacy-font-textfield-configure");
            field.placeholder = @"0x00000070deadbeef";
            field.text = @"0x12345678";
        }];
        puts("legacy-font-textfield-created");
    }
    NSArray<NSString *> *actions = index == 2 ?
        @[@"Add to Bookmarks", @"Copy Description", @"Copy Address"] : index == 3 ?
        @[@"Hide Property-Backing Ivars", @"Hide Property-Backing Methods",
          @"Show Likely Private Methods", @"Show Method Overrides", @"Hide Variable Previews"] :
        @[@"Continue"];
    for(NSString *action in actions)
        [alert addAction:[UIAlertAction actionWithTitle:action
            style:UIAlertActionStyleDefault handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
        style:UIAlertActionStyleCancel handler:nil]];
    if(sheet) alert.popoverPresentationController.barButtonItem = self.sheetAnchor;
    printf("legacy-font-present: %s\n", name.UTF8String);
    [self.presenter presentViewController:alert animated:YES completion:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 3),
            dispatch_get_main_queue(), ^{
                [self.window layoutIfNeeded];
                [alert.view layoutIfNeeded];
                NSMutableSet<NSString *> *visibleActions = [NSMutableSet set];
                unsigned labels = checkAlertLabels(alert.view, name,
                    [NSSet setWithArray:actions], visibleActions);
                check([name stringByAppendingString:@"-labels-present"], labels >= 2);
                if(index == 1) {
                    UITextField *field = alert.textFields.firstObject;
                    check(@"textfield-alert-field-finite", finiteFont(field.font) &&
                        finiteRect(field.frame) && field.bounds.size.width > 0 &&
                        field.bounds.size.height > 0 && visibleInWindow(field));
                    check(@"textfield-alert-text-preserved",
                        [field.text isEqual:@"0x12345678"]);
                    if(!finiteFont(field.font)) describeBadFont(@"textfield", field.font);
                }
                if(sheet) {
                    CGRect frame = [alert.view convertRect:alert.view.bounds toView:self.window];
                    printf("legacy-font-sheet-presentation: style=%ld controller=%s preferred=%s requested-frame=%s fitting=%s\n",
                        (long)alert.modalPresentationStyle,
                        NSStringFromClass(alert.presentationController.class).UTF8String,
                        NSStringFromCGSize(alert.preferredContentSize).UTF8String,
                        NSStringFromCGRect([alert.presentationController frameOfPresentedViewInContainerView]).UTF8String,
                        NSStringFromCGSize([alert.view sizeThatFits:CGSizeMake(
                            alert.view.bounds.size.width, CGFLOAT_MAX)]).UTF8String);
                    if([[NSUserDefaults standardUserDefaults] boolForKey:@"LC32AlertDiagnostics"]) {
                        for(id object in @[alert, alert.view]) {
                            for(NSString *selectorName in @[@"_isInPopoverPresentation",
                                    @"_isPresentedAsPopover", @"_shouldSizeToFillSuperview",
                                    @"_hostsLayoutEngine", @"_forceLayoutEngineSolutionInRationalEdges",
                                    @"translatesAutoresizingMaskIntoConstraints"]) {
                                SEL selector = NSSelectorFromString(selectorName);
                                if([object respondsToSelector:selector])
                                    printf("legacy-font-sheet-policy: %s %s=%d\n",
                                        NSStringFromClass([object class]).UTF8String, selectorName.UTF8String,
                                        ((BOOL (*)(id, SEL))objc_msgSend)(object, selector));
                            }
                        }
                        printf("legacy-font-sheet-tree: %s\n", [(id)((id (*)(id, SEL))objc_msgSend)(
                            alert.view, sel_registerName("recursiveDescription")) UTF8String]);
                    }
                    printf("legacy-font-sheet-layout: %s bounds=%s window=%s visible-actions=%lu/%lu\n",
                        name.UTF8String, NSStringFromCGRect(alert.view.bounds).UTF8String,
                        NSStringFromCGRect(frame).UTF8String,
                        (unsigned long)visibleActions.count, (unsigned long)actions.count);
                    // A compact landscape sheet may scroll, but must expose real
                    // actions instead of collapsing to a tiny ellipsis popover.
                    check([name stringByAppendingString:@"-expanded-content"],
                        visibleActions.count >= 2 && finiteRect(frame) &&
                        frame.size.width >= 100 && frame.size.height >= 60 &&
                        visibleInWindow(alert.view));
                    if(index == 2 && !checkEmptySheetHeaders(alert.view))
                        puts("legacy-font-empty-sheet-header: SKIP (optional native header class absent)");
                }
                checkSDKUnchanged();
                if(!self.repeatAlerts) { [self finish]; return; }
                ++self.completedPresentations;
                // Exercise both public dismissal entry points, alternating
                // animated/nonanimated transitions through fresh alerts.
                UIViewController *dismisser = self.completedPresentations % 2 ?
                    alert : self.presenter;
                [dismisser dismissViewControllerAnimated:self.completedPresentations % 2
                    completion:^{
                    ++self.completedDismissals;
                    check(@"repeat-dismissal-completion-once",
                        self.completedDismissals == self.completedPresentations);
                    check(@"repeat-presentation-relationships-cleared",
                        self.presenter.presentedViewController == nil &&
                        alert.presentingViewController == nil);
                    printf("legacy-font-repeat-presenter: root=%d window=%s superview=%s hidden=%d alpha=%g frame=%s bounds=%s visible=%d policy=%d\n",
                        self.window.rootViewController == self.presenter,
                        self.presenter.view.window.description.UTF8String,
                        self.presenter.view.superview.description.UTF8String,
                        self.presenter.view.hidden, self.presenter.view.alpha,
                        NSStringFromCGRect(self.presenter.view.frame).UTF8String,
                        NSStringFromCGRect(self.presenter.view.bounds).UTF8String,
                        visibleInWindow(self.presenter.view), nativeWindowTransformPolicy());
                    check(@"repeat-native-window-policy-unchanged",
                        nativeWindowTransformPolicy() == self.originalWindowPolicy);
                    check(@"repeat-presenter-visible", !self.window.hidden &&
                        self.window.rootViewController == self.presenter &&
                        self.presenter.view.window == self.window &&
                        visibleInWindow(self.presenter.view));
                    if(self.completedDismissals == 8) {
                        // Optional investigation only: on some newer runtimes,
                        // unmodified pre-iOS-8 ordinary modal dismissal itself
                        // fails. It cannot be an alert-regression prerequisite.
                        if([[NSUserDefaults standardUserDefaults] boolForKey:@"LC32NestedModalControl"])
                            [self finishAfterNestedModalControl];
                        else [self finish];
                        return;
                    }
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4),
                        dispatch_get_main_queue(), ^{
                            [self showAlertCase:self.completedDismissals % 4];
                        });
                }];
            });
    }];
}

- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application; (void)options;
    NSString *expectedLanguage = [[NSUserDefaults standardUserDefaults]
        stringForKey:@"LC32ExpectedLanguage"];
    NSString *language = [[NSLocale preferredLanguages] firstObject];
    self.language = language;
    printf("legacy-font-language: %s expected=%s\n", language.UTF8String,
        expectedLanguage.UTF8String);
    check(@"requested-language", expectedLanguage.length &&
        [[[language componentsSeparatedByString:@"-"] firstObject] isEqual:expectedLanguage]);
    NSString *alertCase = [[NSUserDefaults standardUserDefaults] stringForKey:@"LC32AlertCase"] ?: @"plain";
    self.repeatAlerts = [[NSUserDefaults standardUserDefaults] boolForKey:@"LC32RepeatAlerts"];
    NSUInteger index = [@[@"plain", @"text", @"untitled", @"titled"] indexOfObject:alertCase];
    check(@"requested-alert-case", index != NSNotFound);
    if(index == NSNotFound) { [self finish]; return NO; }
    printf("legacy-font-alert-case: %s\n", alertCase.UTF8String);
    if(index == 0) {
        checkValidFonts();
        checkFontMatrix();
        checkOptionalDescriptorOptions();
    }
    checkSDKUnchanged();
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.originalWindowPolicy = nativeWindowTransformPolicy();
    UIViewController *root = [[UIViewController alloc] init];
    self.presenter = root;
    root.view.backgroundColor = [UIColor whiteColor];
    UIToolbar *toolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0,
        root.view.bounds.size.height - 44, root.view.bounds.size.width, 44)];
    toolbar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    self.sheetAnchor = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:
        UIBarButtonSystemItemAction target:nil action:nil];
    toolbar.items = @[[[UIBarButtonItem alloc] initWithBarButtonSystemItem:
        UIBarButtonSystemItemFlexibleSpace target:nil action:nil], self.sheetAnchor];
    [root.view addSubview:toolbar];
    self.window.rootViewController = root;
    [self.window makeKeyAndVisible];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4),
        dispatch_get_main_queue(), ^{
            if([[NSUserDefaults standardUserDefaults] boolForKey:@"LC32OrdinaryModalOnly"])
                [self finishAfterNestedModalControl];
            else [self showAlertCase:(unsigned)index];
        });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_SEC),
        dispatch_get_main_queue(), ^{ puts("legacy-font-regression: TIMEOUT"); exit(2); });
    return YES;
}
@end

static void uncaught(NSException *exception) {
    fprintf(stderr, "legacy-font-uncaught: %s: %s\n",
        exception.name.UTF8String, exception.reason.UTF8String);
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    @autoreleasepool {
        NSSetUncaughtExceptionHandler(uncaught);
        originalSDK = dyld_get_program_sdk_version();
        originalAtLeast11 = dyld_program_sdk_at_least(
            (struct FontTestBuildVersion){PLATFORM_IOS, 0x000b0000});
        uint32_t expectedSDK = [[[NSBundle mainBundle]
            objectForInfoDictionaryKey:@"LC32ExpectedSDK"] unsignedIntValue];
        check(@"actual-sdk", originalSDK == expectedSDK &&
            actualBuildVersionMatches(expectedSDK));
        return UIApplicationMain(argc, argv, nil,
            NSStringFromClass([FontTestAppDelegate class]));
    }
}
