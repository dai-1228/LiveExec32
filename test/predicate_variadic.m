#import <Foundation/Foundation.h>

#include <limits.h>
#include <stdarg.h>
#include <stdio.h>

static int check(const char *name, BOOL passed) {
    printf("%s: %s\n", name, passed ? "PASS" : "FAIL");
    return !passed;
}

static NSPredicate *predicateWithArguments(NSString *format, ...) {
    va_list list;
    va_start(list, format);
    NSPredicate *result = [NSPredicate predicateWithFormat:format arguments:list];
    va_end(list);
    return result;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    @autoreleasepool {
        int failed = 0;
        NSPredicate *order = [NSPredicate predicateWithFormat:@"order_position>=%d", 3];
        failed += check("integer-threshold", [order evaluateWithObject:@{@"order_position": @3}] &&
            ![order evaluateWithObject:@{@"order_position": @2}]);
        failed += check("signed-integers", [[NSPredicate predicateWithFormat:
            @"%d == -12 AND %i == 27", -12, 27] evaluateWithObject:nil]);
        failed += check("unsigned-integers", [[NSPredicate predicateWithFormat:
            @"%u == %@ AND %x == 42 AND %X == 42 AND %o == 42",
            UINT_MAX, @(UINT_MAX), 42u, 42u, 42u] evaluateWithObject:nil]);
        failed += check("promoted-small-integers", [[NSPredicate predicateWithFormat:
            @"%hhd == -2 AND %hhu == 250 AND %hd == -123 AND %hu == 65535",
            254, 250, -123, 65535] evaluateWithObject:nil]);
        failed += check("guest-long-width", [[NSPredicate predicateWithFormat:
            @"%ld == %@ AND %lu == %@", LONG_MIN, @(LONG_MIN), ULONG_MAX,
            @(ULONG_MAX)] evaluateWithObject:nil]);
        failed += check("wide-integers", [[NSPredicate predicateWithFormat:
            @"%lld == %@ AND %llu == %@ AND %qd == %lld",
            LLONG_MIN, @(LLONG_MIN), ULLONG_MAX, @(ULLONG_MAX),
            0x123456789abcdefLL, 0x123456789abcdefLL] evaluateWithObject:nil]);
        failed += check("legacy-integers", [[NSPredicate predicateWithFormat:
            @"%D == -23 AND %U == %@ AND %O == 27", -23, UINT_MAX,
            @(UINT_MAX), 27u] evaluateWithObject:nil]);
        failed += check("character-integers", [[NSPredicate predicateWithFormat:
            @"%c == -1 AND %C == 22136", 255, 0x12345678] evaluateWithObject:nil]);
        failed += check("floating-point", [[NSPredicate predicateWithFormat:
            @"%f == 1.25 AND %e == -2.5 AND %g == 3.75 AND %a == 0.5",
            (float)1.25, -2.5, 3.75, 0.5] evaluateWithObject:nil]);
        failed += check("floating-point-lengths", [[NSPredicate predicateWithFormat:
            @"%lf == 1.5 AND %Lf == 2.25 AND %F == %E AND %G == %A",
            1.5, (long double)2.25, 3.5, 3.5, 4.75, 4.75] evaluateWithObject:nil]);
        failed += check("mixed-argument-alignment", [[NSPredicate predicateWithFormat:
            @"%d == 7 AND %lld == %@ AND %d == 9 AND %f == 2.5 AND %@ == 'end'",
            7, 0x123456789abcdefLL, @(0x123456789abcdefLL), 9, 2.5,
            @"end"] evaluateWithObject:nil]);
        failed += check("key-path-and-object", [[NSPredicate predicateWithFormat:
            @"%K == %@ AND %K >= %d", @"name", @"player", @"score", 42]
            evaluateWithObject:@{@"name": @"player", @"score": @43}]);
        failed += check("quoted-substitutions", [[NSPredicate predicateWithFormat:
            @"'%d %@ %K' == %@ AND \"%% %lld\" == %@ AND %d == 7",
            @"%d %@ %K", @"%% %lld", 7] evaluateWithObject:nil]);
        failed += check("escaped-quote", [[NSPredicate predicateWithFormat:
            @"'a\\'%d' == %@ AND %d == 11", @"a'%d", 11] evaluateWithObject:nil]);
        failed += check("literal-percent", [[NSPredicate predicateWithFormat:
            @"%% == %@ AND %d == 9", @"%", 9] evaluateWithObject:nil]);
        failed += check("nil-object", [[NSPredicate predicateWithFormat:
            @"SELF == %@", nil] evaluateWithObject:nil]);
        failed += check("explicit-va-list", [predicateWithArguments(
            @"%d == 3 AND %lld == %@ AND %f == 1.5 AND %@ == 'ok'",
            3, 0x123456789abcdefLL, @(0x123456789abcdefLL), 1.5, @"ok")
            evaluateWithObject:nil]);

#ifdef LC32_TEST_PREDICATE_REJECTIONS
        /* Run these only in the host-native build linked with our shim. A
         * host-raised NSException cannot yet unwind into a guest @catch. */
        NSArray *unsupported = @[@"SELF == %", @"SELF == %l", @"SELF == %n",
                                  @"SELF == %2$d", @"SELF == %*d",
                                  @"SELF == %.2f", @"SELF == %L@"];
        for(NSString *format in unsupported) {
            BOOL raised = NO;
            @try {
                [NSPredicate predicateWithFormat:format];
            } @catch(NSException *exception) {
                raised = [[exception name] isEqualToString:NSInvalidArgumentException];
            }
            failed += check([format UTF8String], raised);
        }
#endif
        printf("predicate-variadic: %s (%d failures)\n", failed ? "FAIL" : "PASS", failed);
        return failed;
    }
}
