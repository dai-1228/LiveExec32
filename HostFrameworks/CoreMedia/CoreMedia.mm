@import CoreMedia;

#include "bridge.h"
#include "../../GuestFrameworks/CoreMedia/LC32CoreMediaBridge.h"

namespace {

bool Range(u32 address, size_t size) {
    return address && uint64_t(address) + size <= uint64_t(UINT32_MAX) + 1;
}

bool ReadCall(u32 address, LC32CoreMediaCall &call) {
    return Range(address, sizeof(call)) &&
        Dynarmic_mem_1read(address, sizeof(call), (char *)&call) == 0 &&
        call.version == LC32CoreMediaABIVersion &&
        call.slotCount <= LC32CoreMediaMaxSlots;
}

CMSampleBufferRef SampleBuffer(const LC32CoreMediaCall &call) {
    return reinterpret_cast<CMSampleBufferRef>(
        static_cast<uintptr_t>(call.slots[0]));
}

} // namespace

extern "C" u32 LC32_CoreMedia_Dispatch(u32 operation, u32 guestCall) {
    LC32CoreMediaCall call;
    if(!ReadCall(guestCall, call)) return 0;
    switch(operation) {
        case LC32CMSampleBufferGetTypeID:
            if(call.slotCount != 0) return 0;
            return u32(CMSampleBufferGetTypeID());
        case LC32CMSampleBufferIsValid: {
            if(call.slotCount != 1) return 0;
            auto sampleBuffer = SampleBuffer(call);
            return sampleBuffer && CMSampleBufferIsValid(sampleBuffer);
        }
        case LC32CMSampleBufferGetImageBuffer: {
            if(call.slotCount != 1) return 0;
            auto sampleBuffer = SampleBuffer(call);
            CVImageBufferRef image = sampleBuffer
                ? CMSampleBufferGetImageBuffer(sampleBuffer) : nullptr;
            return image ? [(id)image guest_self] : 0;
        }
        case LC32CMSampleBufferGetPresentationTimeStamp: {
            if(call.slotCount != 2 || call.slots[1] > UINT32_MAX) return 0;
            const u32 output = u32(call.slots[1]);
            if(!Range(output, sizeof(LC32CoreMediaTime))) return 0;
            auto sampleBuffer = SampleBuffer(call);
            const CMTime time = sampleBuffer
                ? CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                : kCMTimeInvalid;
            LC32CoreMediaTime wire = {
                time.value, time.timescale, time.flags, time.epoch,
            };
            return Dynarmic_mem_1write(output, sizeof(wire), (char *)&wire) == 0;
        }
        default:
            return 0;
    }
}
