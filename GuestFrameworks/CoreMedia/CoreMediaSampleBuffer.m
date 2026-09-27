#import <CoreMedia/CoreMedia.h>
#import <LC32/LC32.h>
#import "LC32CoreMediaBridge.h"

#include <pthread.h>
#include <string.h>

static pthread_once_t dispatcherOnce = PTHREAD_ONCE_INIT;
static uint64_t dispatcherAddress;

static void ResolveDispatcher(void) {
    dispatcherAddress = LC32Dlsym("LC32_CoreMedia_Dispatch", YES);
}

static uint32_t Dispatch(LC32CoreMediaOpcode opcode,
                         const uint64_t *slots, uint32_t count) {
    pthread_once(&dispatcherOnce, ResolveDispatcher);
    if(!dispatcherAddress || count > LC32CoreMediaMaxSlots) return 0;
    LC32CoreMediaCall call = { .version = LC32CoreMediaABIVersion,
                              .slotCount = count };
    if(count) memcpy(call.slots, slots, count * sizeof(*slots));
    return LC32InvokeHostCRet32(dispatcherAddress, (uint32_t)opcode,
                              (uint32_t)(uintptr_t)&call);
}

static uint64_t Host(CMSampleBufferRef sampleBuffer) {
    return sampleBuffer ? [(id)sampleBuffer host_self] : 0;
}

CFTypeID CMSampleBufferGetTypeID(void) {
    return (CFTypeID)Dispatch(LC32CMSampleBufferGetTypeID, NULL, 0);
}

Boolean CMSampleBufferIsValid(CMSampleBufferRef sampleBuffer) {
    const uint64_t slots[] = {Host(sampleBuffer)};
    return Dispatch(LC32CMSampleBufferIsValid, slots, 1) != 0;
}

CVImageBufferRef CMSampleBufferGetImageBuffer(CMSampleBufferRef sampleBuffer) {
    const uint64_t slots[] = {Host(sampleBuffer)};
    // A Get result remains borrowed from its sample buffer. Do not retain it
    // or apply the owned Create/Copy conversion on either side of the bridge.
    return (CVImageBufferRef)(uintptr_t)Dispatch(
        LC32CMSampleBufferGetImageBuffer, slots, 1);
}

CMTime CMSampleBufferGetPresentationTimeStamp(CMSampleBufferRef sampleBuffer) {
    LC32CoreMediaTime time = {0};
    const uint64_t slots[] = {
        Host(sampleBuffer), (uint32_t)(uintptr_t)&time,
    };
    if(!Dispatch(LC32CMSampleBufferGetPresentationTimeStamp, slots, 2))
        return kCMTimeInvalid;
    return (CMTime){time.value, time.timescale, time.flags, time.epoch};
}
