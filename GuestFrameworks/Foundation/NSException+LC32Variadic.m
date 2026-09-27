#import <Foundation/Foundation.h>

#include <stdarg.h>

static NSException *LC32ExceptionWithFormat(Class exceptionClass,
                                            NSExceptionName name,
                                            NSString *format,
                                            va_list arguments) {
    /* Objective-C method encodings omit the variadic argument types. Use
     * NSString's format-aware bridge to widen guest scalars and translate
     * object pointers before passing the reason to native Foundation. */
    va_list argumentsCopy;
    va_copy(argumentsCopy, arguments);
    NSString *reason = [[NSString alloc]
        initWithFormat:format arguments:argumentsCopy];
    va_end(argumentsCopy);

    NSException *exception = [exceptionClass
        exceptionWithName:name reason:reason userInfo:nil];
#if !__has_feature(objc_arc)
    [reason release];
#endif
    return exception;
}

@implementation NSException (LC32Variadic)

+ (void)raise:(NSExceptionName)name format:(NSString *)format, ... {
    va_list arguments;
    va_start(arguments, format);
    NSException *exception = LC32ExceptionWithFormat(
        self, name, format, arguments);
    va_end(arguments);
    [exception raise];
}

+ (void)raise:(NSExceptionName)name
        format:(NSString *)format
     arguments:(va_list)arguments {
    [LC32ExceptionWithFormat(self, name, format, arguments) raise];
}

@end
