#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include <math.h>
#include <stdio.h>
#include <string.h>

@interface NSObject (LC32GuestFPReturnTest)
- (uint64_t)host_self;
@end

extern uint64_t LC32GetHostSelector(SEL selector);
extern uint64_t LC32InvokeHostSelector(uint64_t object,
                                       uint64_t selector, ...);
extern id LC32HostToGuestObject(uint64_t hostObject);

static id LC32HostValueForKey(id object, NSString *key) {
    const uint64_t hostResult = LC32InvokeHostSelector(
        [object host_self],
        LC32GetHostSelector(@selector(valueForKey:)),
        [key host_self], (uint64_t)0);
    return LC32HostToGuestObject(hostResult);
}

static void LC32HostSetValueForKey(id object, NSNumber *value, NSString *key) {
    LC32InvokeHostSelector([object host_self],
        LC32GetHostSelector(@selector(setValue:forKey:)),
        [value host_self], [key host_self], (uint64_t)0);
}

static NSInvocation *LC32HostInvocation(id object, SEL selector) {
    // Ask the native mirror, not the guest NSObject compatibility method,
    // for the signature which native NSInvocation/KVC actually observes.
    const uint64_t signature = LC32InvokeHostSelector([object host_self],
        LC32GetHostSelector(@selector(methodSignatureForSelector:)),
        LC32GetHostSelector(selector), (uint64_t)0);
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:
        LC32HostToGuestObject(signature)];
    [invocation setTarget:object];
    [invocation setSelector:selector];
    return invocation;
}

/*
 * KVC runs on the ARM64 host mirror and invokes these guest implementations.
 * That exercises the host-to-guest Objective-C callback path instead of a
 * direct ARM32 objc_msgSend between guest objects.
 */
@interface LC32GuestFloatProbe : NSObject {
    uint32_t receivedFloatBits;
    uint64_t receivedDoubleBits;
    NSUInteger callbackCount;
    NSCondition *callbackCondition;
}
- (float)lc32FloatValue;
- (double)lc32DoubleValue;
- (void)setFloatArgument:(float)value;
- (void)setDoubleArgument:(double)value;
- (uint32_t)receivedFloatBits;
- (uint64_t)receivedDoubleBits;
- (NSUInteger)callbackCount;
- (BOOL)waitForCallbackCount:(NSUInteger)count;
@end

@implementation LC32GuestFloatProbe
- (id)init {
    self = [super init];
    if(self) callbackCondition = [NSCondition new];
    return self;
}

- (void)dealloc {
    [callbackCondition release];
    [super dealloc];
}

- (float)lc32FloatValue {
    return 19.75f;
}

- (double)lc32DoubleValue {
    return 1234.125;
}

- (void)setFloatArgument:(float)value {
    [callbackCondition lock];
    memcpy(&receivedFloatBits, &value, sizeof(value));
    callbackCount++;
    [callbackCondition signal];
    [callbackCondition unlock];
}

- (void)setDoubleArgument:(double)value {
    [callbackCondition lock];
    memcpy(&receivedDoubleBits, &value, sizeof(value));
    callbackCount++;
    [callbackCondition signal];
    [callbackCondition unlock];
}

- (uint32_t)receivedFloatBits { return receivedFloatBits; }
- (uint64_t)receivedDoubleBits { return receivedDoubleBits; }
- (NSUInteger)callbackCount { return callbackCount; }

- (BOOL)waitForCallbackCount:(NSUInteger)count {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    [callbackCondition lock];
    while(callbackCount < count) {
        if(![callbackCondition waitUntilDate:deadline]) break;
    }
    const BOOL complete = callbackCount == count;
    [callbackCondition unlock];
    return complete;
}
@end

@interface LC32GuestCGFloatView : UIView {
    CGFloat receivedAlpha;
}
- (CGFloat)receivedAlpha;
@end

@implementation LC32GuestCGFloatView
- (CGFloat)alpha {
    return 0.625f;
}
- (void)setAlpha:(CGFloat)value {
    receivedAlpha = value;
}
- (CGFloat)receivedAlpha { return receivedAlpha; }
@end

static BOOL LC32TestScalarArguments(LC32GuestFloatProbe *probe,
                                   LC32GuestCGFloatView *view) {
    // Preserve exact bits, including signed zero, a NaN payload, subnormal
    // float, and double precision which cannot survive a float round trip.
    const uint32_t floatBits[] = {
        UINT32_C(0xc19e0000), UINT32_C(0x80000000),
        UINT32_C(0x7fc01234), UINT32_C(0x00000001),
    };
    const uint64_t doubleBits[] = {
        UINT64_C(0xc093488000000000), UINT64_C(0x8000000000000000),
        UINT64_C(0x7ff800000000cafe), UINT64_C(0x3ff0000000000001),
    };
    BOOL floatPassed = YES;
    BOOL doublePassed = YES;
    NSInvocation *floatInvocation = [LC32HostInvocation(
        probe, @selector(setFloatArgument:)) retain];
    NSInvocation *doubleInvocation = [LC32HostInvocation(
        probe, @selector(setDoubleArgument:)) retain];
    for(unsigned index = 0; index < sizeof(floatBits) / sizeof(*floatBits);
            index++) {
        float value;
        memcpy(&value, &floatBits[index], sizeof(value));
        [floatInvocation setArgument:&value atIndex:2];
        [floatInvocation invoke];
        floatPassed &= [probe receivedFloatBits] == floatBits[index];
    }
    for(unsigned index = 0; index < sizeof(doubleBits) / sizeof(*doubleBits);
            index++) {
        double value;
        memcpy(&value, &doubleBits[index], sizeof(value));
        [doubleInvocation setArgument:&value atIndex:2];
        [doubleInvocation invoke];
        doublePassed &= [probe receivedDoubleBits] == doubleBits[index];
    }
    printf("host-invocation-float-argument-bits: %s\n",
        floatPassed ? "PASS" : "FAIL");
    printf("host-invocation-double-argument-bits: %s\n",
        doublePassed ? "PASS" : "FAIL");

    const float kvcFloat = 19.125f;
    const double kvcDouble = 123456.875;
    uint32_t kvcFloatBits;
    uint64_t kvcDoubleBits;
    memcpy(&kvcFloatBits, &kvcFloat, sizeof(kvcFloat));
    memcpy(&kvcDoubleBits, &kvcDouble, sizeof(kvcDouble));
    LC32HostSetValueForKey(probe, [NSNumber numberWithFloat:kvcFloat],
        @"floatArgument");
    LC32HostSetValueForKey(probe, [NSNumber numberWithDouble:kvcDouble],
        @"doubleArgument");
    const BOOL kvcPassed = [probe receivedFloatBits] == kvcFloatBits &&
        [probe receivedDoubleBits] == kvcDoubleBits;
    printf("host-kvc-floating-arguments: %s\n", kvcPassed ? "PASS" : "FAIL");

    LC32HostSetValueForKey(view, [NSNumber numberWithDouble:0.3125], @"alpha");
    const BOOL cgFloatPassed = [view receivedAlpha] == 0.3125f;
    printf("host-kvc-cgfloat-argument-width: %s\n",
        cgFloatPassed ? "PASS" : "FAIL");

    // NSInvocation is native, so NSThread's invokeWithTarget: calls the
    // mirror from an unregistered host thread. The callback executor must
    // preserve the same payloads before this bounded wait completes.
    float foreignFloat = -0.75f;
    double foreignDouble = 1.0000000000000002;
    uint32_t foreignFloatBits;
    uint64_t foreignDoubleBits;
    memcpy(&foreignFloatBits, &foreignFloat, sizeof(foreignFloat));
    memcpy(&foreignDoubleBits, &foreignDouble, sizeof(foreignDouble));
    [floatInvocation setArgument:&foreignFloat atIndex:2];
    [floatInvocation retainArguments];
    NSUInteger expected = [probe callbackCount] + 1;
    [NSThread detachNewThreadSelector:@selector(invokeWithTarget:)
        toTarget:floatInvocation withObject:probe];
    const BOOL foreignFloatPassed = [probe waitForCallbackCount:expected] &&
        [probe receivedFloatBits] == foreignFloatBits;
    [doubleInvocation setArgument:&foreignDouble atIndex:2];
    [doubleInvocation retainArguments];
    expected = [probe callbackCount] + 1;
    [NSThread detachNewThreadSelector:@selector(invokeWithTarget:)
        toTarget:doubleInvocation withObject:probe];
    const BOOL foreignDoublePassed = [probe waitForCallbackCount:expected] &&
        [probe receivedDoubleBits] == foreignDoubleBits;
    printf("host-foreign-thread-float-argument: %s\n",
        foreignFloatPassed ? "PASS" : "FAIL");
    printf("host-foreign-thread-double-argument: %s\n",
        foreignDoublePassed ? "PASS" : "FAIL");
    [floatInvocation release];
    [doubleInvocation release];
    return floatPassed && doublePassed && kvcPassed && cgFloatPassed &&
        foreignFloatPassed && foreignDoublePassed;
}

@interface LC32GuestTableDelegateBase : NSObject
    <UITableViewDelegate>
@end

@implementation LC32GuestTableDelegateBase
@end

@interface LC32GuestTableDelegate : LC32GuestTableDelegateBase
    <UITableViewDataSource> {
    NSUInteger heightCallbackCount;
}
- (NSUInteger)heightCallbackCount;
@end

@implementation LC32GuestTableDelegate
- (NSInteger)tableView:(UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    (void)indexPath;
    return [[[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleDefault
        reuseIdentifier:nil] autorelease];
}

- (CGFloat)tableView:(UITableView *)tableView
 heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    (void)indexPath;
    heightCallbackCount++;
    return 37.5f;
}

- (NSUInteger)heightCallbackCount {
    return heightCallbackCount;
}
@end

int main(void) {
    NSAutoreleasePool *pool = [NSAutoreleasePool new];

    LC32GuestFloatProbe *floatProbe = [LC32GuestFloatProbe new];
    NSNumber *boxedFloat =
        LC32HostValueForKey(floatProbe, @"lc32FloatValue");
    const BOOL floatPassed =
        fabsf(boxedFloat.floatValue - 19.75f) < 0.0001f;
    printf("host-callback-float-return: %s\n",
           floatPassed ? "PASS" : "FAIL");

    NSNumber *boxedDouble =
        LC32HostValueForKey(floatProbe, @"lc32DoubleValue");
    const BOOL doublePassed =
        fabs(boxedDouble.doubleValue - 1234.125) < 0.0001;
    printf("host-callback-double-return: %s\n",
           doublePassed ? "PASS" : "FAIL");

    /*
     * CGFloat is `f` in the ARMv7 guest but `d` in the ARM64 UIView method.
     * The native superclass encoding must therefore select a double-returning
     * host IMP while the guest r0 payload is still decoded as a float.
     */
    LC32GuestCGFloatView *view = [LC32GuestCGFloatView new];
    NSNumber *boxedCGFloat = LC32HostValueForKey(view, @"alpha");
    const BOOL cgFloatPassed =
        fabs(boxedCGFloat.doubleValue - 0.625) < 0.0001;
    printf("host-callback-cgfloat-return: %s\n",
           cgFloatPassed ? "PASS" : "FAIL");
    const BOOL scalarArgumentsPassed = LC32TestScalarArguments(floatProbe, view);

    /* UITableViewDelegate declares CGFloat on the host, but the guest class
     * has no native superclass implementation and inherits its protocol
     * adoption from LC32GuestTableDelegateBase. */
    LC32GuestTableDelegate *tableDelegate =
        [LC32GuestTableDelegate new];
    UITableView *tableView = [[UITableView alloc]
        initWithFrame:CGRectMake(0, 0, 320, 480)
        style:UITableViewStylePlain];
    tableView.dataSource = tableDelegate;
    tableView.delegate = tableDelegate;
    [tableView reloadData];
    [tableView layoutIfNeeded];
    const CGRect rowRect = [tableView rectForRowAtIndexPath:
        [NSIndexPath indexPathForRow:0 inSection:0]];
    const BOOL protocolCGFloatPassed =
        tableDelegate.heightCallbackCount > 0 &&
        fabs(rowRect.size.height - 37.5) < 0.0001;
    printf("host-protocol-cgfloat-return: %s\n",
           protocolCGFloatPassed ? "PASS" : "FAIL");

    [tableView release];
    [tableDelegate release];
    [view release];
    [floatProbe release];
    [pool drain];
    return !(floatPassed && doublePassed && cgFloatPassed &&
             protocolCGFloatPassed && scalarArgumentsPassed);
}
