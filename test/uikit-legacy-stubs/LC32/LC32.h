#import <Foundation/Foundation.h>
#include <stdint.h>
@interface NSObject (LC32StatusBarTestBridge)
@property(readonly) uint64_t host_self;
@end
uint64_t LC32Dlsym(const char *name, BOOL isFunction);
uint32_t LC32InvokeHostCRet32(uint64_t hostPtr, ...);
uint64_t LC32CachedHostSelector(uint64_t *cache, SEL selector, BOOL superCall);
uint64_t LC32InvokeHostSelector(uint64_t receiver, uint64_t command, ...);
