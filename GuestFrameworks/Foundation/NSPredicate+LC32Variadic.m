#import <Foundation/Foundation.h>

#include <stdarg.h>
#include <string.h>

/*
 * Objective-C method encodings do not describe the ellipsis in
 * +predicateWithFormat:.  The generated fixed-argument bridge therefore
 * cannot forward its ARMv7 va_list to arm64 Foundation.  Consume the
 * substitutions in the guest and use the fixed-argument
 * argumentArray: entry point instead.
 *
 * Foundation accepts boxed values for numeric conversions in argumentArray:.
 * Decode those values using the guest ABI (including integer promotions and
 * aligned 64-bit arguments), not the host's sizeof(long) or va_list layout.
 * Width, precision, positional arguments, and unsupported conversions are
 * deliberately rejected before reading an argument of an unknown type.
 */
typedef NS_ENUM(unsigned char, LC32PredicateLength) {
    LC32PredicateLengthDefault,
    LC32PredicateLengthChar,
    LC32PredicateLengthShort,
    LC32PredicateLengthLong,
    LC32PredicateLengthLongLong,
    LC32PredicateLengthLongDouble,
};

static id LC32PredicateArgument(const unsigned char **cursor,
                                va_list *list, BOOL *supported) {
    LC32PredicateLength length = LC32PredicateLengthDefault;
    switch(**cursor) {
        case 'h':
            length = LC32PredicateLengthShort;
            ++(*cursor);
            if(**cursor == 'h') {
                length = LC32PredicateLengthChar;
                ++(*cursor);
            }
            break;
        case 'l':
            length = LC32PredicateLengthLong;
            ++(*cursor);
            if(**cursor == 'l') {
                length = LC32PredicateLengthLongLong;
                ++(*cursor);
            }
            break;
        case 'q':
            length = LC32PredicateLengthLongLong;
            ++(*cursor);
            break;
        case 'L':
            length = LC32PredicateLengthLongDouble;
            ++(*cursor);
            break;
    }

    switch(**cursor) {
        case '@':
        case 'K':
            if(length == LC32PredicateLengthDefault)
                return va_arg(*list, id) ?: [NSNull null];
            break;
        case 'd':
        case 'i':
            switch(length) {
                case LC32PredicateLengthDefault: return @(va_arg(*list, int));
                case LC32PredicateLengthChar: return @((signed char)va_arg(*list, int));
                case LC32PredicateLengthShort: return @((short)va_arg(*list, int));
                case LC32PredicateLengthLong: return @(va_arg(*list, long));
                case LC32PredicateLengthLongLong: return @(va_arg(*list, long long));
                default: break;
            }
            break;
        case 'u':
        case 'o':
        case 'x':
        case 'X':
            switch(length) {
                case LC32PredicateLengthDefault: return @(va_arg(*list, unsigned int));
                case LC32PredicateLengthChar: return @((unsigned char)va_arg(*list, int));
                case LC32PredicateLengthShort: return @((unsigned short)va_arg(*list, int));
                case LC32PredicateLengthLong: return @(va_arg(*list, unsigned long));
                case LC32PredicateLengthLongLong: return @(va_arg(*list, unsigned long long));
                default: break;
            }
            break;
        /* Foundation's historical capital forms remain 32-bit, even on LP64. */
        case 'D':
            if(length == LC32PredicateLengthDefault) return @(va_arg(*list, int));
            break;
        case 'U':
        case 'O':
            if(length == LC32PredicateLengthDefault) return @(va_arg(*list, unsigned int));
            break;
        case 'c':
            if(length == LC32PredicateLengthDefault) return @((signed char)va_arg(*list, int));
            break;
        case 'C':
            if(length == LC32PredicateLengthDefault) return @((unsigned short)va_arg(*list, int));
            break;
        case 'f': case 'F': case 'e': case 'E': case 'g': case 'G': case 'a': case 'A':
            if(length == LC32PredicateLengthDefault ||
               length == LC32PredicateLengthLong) return @(va_arg(*list, double));
            if(length == LC32PredicateLengthLongDouble)
                return @((double)va_arg(*list, long double));
            break;
    }
    *supported = NO;
    return nil;
}

static NSPredicate *LC32PredicateWithFormat(Class predicateClass,
                                           NSString *format,
                                           va_list incomingArguments) {
    if(!format) {
        [NSException raise:NSInvalidArgumentException
                    format:@"predicate format must not be nil"];
    }

    const char *bytes = format.UTF8String;
    if(!bytes) return nil;

    NSMutableArray *arguments = [NSMutableArray arrayWithCapacity:4];
    NSMutableData *normalizedBytes = nil;
    va_list list;
    va_copy(list, incomingArguments);

    BOOL supported = YES;
    unsigned char quote = 0;
    @try {
        for(const unsigned char *cursor = (const unsigned char *)bytes;
                *cursor; cursor++) {
            if(quote) {
                if(*cursor == '\\' && cursor[1]) cursor++;
                else if(*cursor == quote) quote = 0;
                continue;
            }
            if(*cursor == '\'' || *cursor == '"') {
                quote = *cursor;
                continue;
            }
            if(*cursor != '%') continue;
            cursor++;
            if(*cursor == '%') {
                /* argumentArray: advances its array cursor for %% even though
                 * the variadic form consumes nothing. Normalize it to an
                 * explicit object substitution instead of depending on that
                 * host-parser detail. Quoted percent signs stay untouched. */
                if(!normalizedBytes)
                    normalizedBytes = [NSMutableData dataWithBytes:bytes length:strlen(bytes)];
                ((unsigned char *)normalizedBytes.mutableBytes)[cursor - (const unsigned char *)bytes] = '@';
                [arguments addObject:@"%"];
                continue;
            }
            id argument = LC32PredicateArgument(&cursor, &list, &supported);
            if(!supported) break;
            [arguments addObject:argument];
        }
    } @finally {
        va_end(list);
    }

    if(!supported) {
        [NSException raise:NSInvalidArgumentException
                    format:@"unsupported predicate substitution in %@",
                           format];
    }
    if(normalizedBytes) {
        format = [[[NSString alloc] initWithBytes:normalizedBytes.bytes
                                          length:normalizedBytes.length
                                        encoding:NSUTF8StringEncoding] autorelease];
    }
    return [predicateClass predicateWithFormat:format argumentArray:arguments];
}

@implementation NSPredicate (LC32Variadic)

+ (NSPredicate *)predicateWithFormat:(NSString *)format, ... {
    va_list list;
    va_start(list, format);
    @try {
        return LC32PredicateWithFormat(self, format, list);
    } @finally {
        va_end(list);
    }
}

+ (NSPredicate *)predicateWithFormat:(NSString *)format
                         arguments:(va_list)arguments {
    return LC32PredicateWithFormat(self, format, arguments);
}

@end
