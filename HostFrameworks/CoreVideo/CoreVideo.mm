@import CoreVideo;
@import OpenGLES;
#include "bridge.h"
#include "../../GuestFrameworks/CoreVideo/LC32CoreVideoBridge.h"
#include <algorithm>
#include <cstring>

namespace {

bool Range(u32 address, size_t size) {
    return address && uint64_t(address) + size <= uint64_t(UINT32_MAX) + 1;
}
template<typename T> bool Write(u32 address, const T &value) {
    return Range(address, sizeof(value)) && Dynarmic_mem_1write(address,
        sizeof(value), const_cast<char *>(reinterpret_cast<const char *>(&value))) == 0;
}
template<typename T> T Object(const LC32CoreVideoCall &call, size_t index) {
    return reinterpret_cast<T>(static_cast<uintptr_t>(call.slots[index]));
}
u32 U(const LC32CoreVideoCall &call, size_t index) { return u32(call.slots[index]); }
u32 Borrowed(CFTypeRef value) { return value ? [(id)value guest_self] : 0; }

CVReturn Created(CVReturn result, CFTypeRef object, u32 output) {
    if(result != kCVReturnSuccess) {
        if(object) CFRelease(object);
        return result;
    }
    u32 guest = LC32GuestObjectForOwnedHostObject(object);
    if(!guest) return kCVReturnAllocationFailed;
    if(Write(output, guest)) return kCVReturnSuccess;
    // The output can become unwritable while CoreVideo is allocating. Undo
    // both halves of the transferred +1 using the public guest release path.
    (void)LC32InvokeGuestC(guest_dlsym("CFRelease"), false, 1, &guest);
    return kCVReturnInvalidArgument;
}

CVReturn Layout(CVPixelBufferRef buffer, LC32CoreVideoLayout &layout) {
    layout = {};
    if(!buffer) return kCVReturnInvalidArgument;
    const size_t count = CVPixelBufferGetPlaneCount(buffer);
    if(count > LC32CoreVideoMaxPlanes) return kCVReturnUnsupported;
    size_t left = 0, right = 0, top = 0, bottom = 0;
    CVPixelBufferGetExtendedPixels(buffer, &left, &right, &top, &bottom);
    // Extended pixels precede the public base address. Until these margins
    // have their own guest layout, reject CPU mapping rather than overread
    // native storage or expose an allocation with inaccessible negative rows.
    if(left || right || top || bottom) return kCVReturnUnsupported;
    layout.planeCount = u32(count);
    uint64_t offset = count ? 64 : 0;
    for(size_t i = 0; i < std::max(count, size_t(1)); ++i) {
        const size_t rowBytes = count ? CVPixelBufferGetBytesPerRowOfPlane(buffer, i)
                                      : CVPixelBufferGetBytesPerRow(buffer);
        const size_t height = count ? CVPixelBufferGetHeightOfPlane(buffer, i)
                                    : CVPixelBufferGetHeight(buffer);
        if(!rowBytes || !height || rowBytes > LC32CoreVideoMaxBytes ||
           height > LC32CoreVideoMaxBytes / rowBytes ||
           offset + rowBytes * height > LC32CoreVideoMaxBytes)
            return kCVReturnInvalidSize;
        layout.planes[i] = {u32(offset), u32(rowBytes), u32(height)};
        offset = (offset + rowBytes * height + 63) & ~uint64_t(63);
    }
    // Keep CVPixelBufferGetDataSize consistent with the guest allocation,
    // including a guest descriptor for IOSurfaces without a native one.
    offset = std::max(offset, uint64_t(CVPixelBufferGetDataSize(buffer)));
    if(offset > LC32CoreVideoMaxBytes) return kCVReturnInvalidSize;
    layout.byteCount = u32(offset);
    return kCVReturnSuccess;
}

CVReturn CopyPixels(CVPixelBufferRef buffer, u32 address, u32 capacity,
                    bool toHost) {
    LC32CoreVideoLayout layout;
    const CVReturn result = Layout(buffer, layout);
    if(result != kCVReturnSuccess) return result;
    if(capacity < layout.byteCount || !Range(address, layout.byteCount))
        return kCVReturnInvalidArgument;
    for(u32 i = 0; i < std::max(layout.planeCount, u32(1)); ++i) {
        char *base = static_cast<char *>(layout.planeCount
            ? CVPixelBufferGetBaseAddressOfPlane(buffer, i)
            : CVPixelBufferGetBaseAddress(buffer));
        if(!base) return kCVReturnInvalidArgument;
        const auto &plane = layout.planes[i];
        const size_t size = size_t(plane.rowBytes) * plane.height;
        const int error = toHost
            ? Dynarmic_mem_1read(address + plane.offset, size, base)
            : Dynarmic_mem_1write(address + plane.offset, size, base);
        if(error) return kCVReturnInvalidArgument;
    }
    return kCVReturnSuccess;
}

bool ReadCall(u32 address, LC32CoreVideoCall &call) {
    struct { u32 version, count; } header;
    if(!Range(address, sizeof(header)) ||
       Dynarmic_mem_1read(address, sizeof(header), (char *)&header) ||
       header.version != LC32CoreVideoABIVersion ||
       header.count > LC32CoreVideoMaxSlots) return false;
    const size_t size = offsetof(LC32CoreVideoCall, slots) +
                        header.count * sizeof(call.slots[0]);
    call = {};
    return Range(address, size) &&
        Dynarmic_mem_1read(address, size, (char *)&call) == 0;
}

} // namespace

// This bridge deliberately preserves the pre-Metal texture APIs and borrowed
// GetAttachment ownership used by ARM32 clients; Copy replacements differ.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
extern "C" u32 LC32_CoreVideo_Dispatch(u32 operation, u32 guestCall) {
    LC32CoreVideoCall call;
    if(!ReadCall(guestCall, call)) return u32(kCVReturnInvalidArgument);
#define NEED(n) if(call.slotCount != (n)) return u32(kCVReturnInvalidArgument)
#define V(i) U(call, i)
#define O(type, i) Object<type>(call, i)
#define PIXEL O(CVPixelBufferRef, 0)
#define SCALAR(name, type) case LC32##name: { NEED(1); \
    auto object = O(type, 0); return object ? u32(name(object)) : 0; }
#define TYPEID(name) case LC32##name: NEED(0); return u32(name())
    switch(operation) {
        TYPEID(CVPixelBufferGetTypeID);
        TYPEID(CVPixelBufferPoolGetTypeID);
        TYPEID(CVOpenGLESTextureGetTypeID);
        TYPEID(CVOpenGLESTextureCacheGetTypeID);
        SCALAR(CVPixelBufferGetWidth, CVPixelBufferRef)
        SCALAR(CVPixelBufferGetHeight, CVPixelBufferRef)
        SCALAR(CVPixelBufferGetPixelFormatType, CVPixelBufferRef)
        SCALAR(CVPixelBufferGetBytesPerRow, CVPixelBufferRef)
        SCALAR(CVPixelBufferIsPlanar, CVPixelBufferRef)
        SCALAR(CVPixelBufferGetPlaneCount, CVPixelBufferRef)
        SCALAR(CVOpenGLESTextureGetName, CVOpenGLESTextureRef)
        SCALAR(CVOpenGLESTextureGetTarget, CVOpenGLESTextureRef)
        SCALAR(CVOpenGLESTextureIsFlipped, CVOpenGLESTextureRef)
        SCALAR(CVImageBufferIsFlipped, CVImageBufferRef)
        case LC32CVPixelBufferGetDataSize: {
            NEED(1);
            LC32CoreVideoLayout layout;
            if(Layout(PIXEL, layout) == kCVReturnSuccess) return layout.byteCount;
            // A CPU mapping limitation must not hide an otherwise valid
            // native buffer's size (it can still be used as a GPU texture).
            const size_t size = PIXEL ? CVPixelBufferGetDataSize(PIXEL) : 0;
            return size <= UINT32_MAX ? u32(size) : 0;
        }
        case LC32CVPixelBufferGetWidthOfPlane:
        case LC32CVPixelBufferGetHeightOfPlane:
        case LC32CVPixelBufferGetBytesPerRowOfPlane: {
            NEED(2);
            auto buffer = PIXEL;
            if(!buffer || V(1) >= CVPixelBufferGetPlaneCount(buffer)) return 0;
            if(operation == LC32CVPixelBufferGetWidthOfPlane)
                return u32(CVPixelBufferGetWidthOfPlane(buffer, V(1)));
            if(operation == LC32CVPixelBufferGetHeightOfPlane)
                return u32(CVPixelBufferGetHeightOfPlane(buffer, V(1)));
            return u32(CVPixelBufferGetBytesPerRowOfPlane(buffer, V(1)));
        }
        case LC32CVPixelBufferCreate: {
            NEED(6);
            if(!Write(V(5), u32(0))) return u32(kCVReturnInvalidArgument);
            CVPixelBufferRef buffer = nullptr;
            CVReturn result = CVPixelBufferCreate(O(CFAllocatorRef, 0),
                V(1), V(2), V(3), O(CFDictionaryRef, 4), &buffer);
            return u32(Created(result, buffer, V(5)));
        }
        case LC32CVPixelBufferCreateResolvedAttributesDictionary: {
            NEED(3);
            if(!Write(V(2), u32(0))) return u32(kCVReturnInvalidArgument);
            CFDictionaryRef dictionary = nullptr;
            CVReturn result = CVPixelBufferCreateResolvedAttributesDictionary(
                O(CFAllocatorRef, 0), O(CFArrayRef, 1), &dictionary);
            return u32(Created(result, dictionary, V(2)));
        }
        case LC32CVPixelBufferLock: {
            NEED(3);
            if(!PIXEL) return u32(kCVReturnInvalidArgument);
            CVReturn result = CVPixelBufferLockBaseAddress(PIXEL, call.slots[1]);
            if(result != kCVReturnSuccess) return u32(result);
            LC32CoreVideoLayout layout;
            result = Layout(PIXEL, layout);
            if(result == kCVReturnSuccess && !Write(V(2), layout))
                result = kCVReturnInvalidArgument;
            if(result != kCVReturnSuccess) CVPixelBufferUnlockBaseAddress(PIXEL, call.slots[1]);
            return u32(result);
        }
        case LC32CVPixelBufferCopyPixels:
            NEED(4); return u32(CopyPixels(PIXEL, V(1), V(2), V(3) != 0));
        case LC32CVPixelBufferUnlock:
            NEED(2); return u32(PIXEL ? CVPixelBufferUnlockBaseAddress(PIXEL, call.slots[1])
                                     : kCVReturnInvalidArgument);
        case LC32CVBufferSetAttachment:
            NEED(4);
            if(PIXEL && call.slots[1] && call.slots[2])
                CVBufferSetAttachment(PIXEL, O(CFStringRef, 1), O(CFTypeRef, 2),
                                      CVAttachmentMode(V(3)));
            return 0;
        case LC32CVBufferGetAttachment: {
            NEED(3);
            if(!PIXEL || !call.slots[1]) return 0;
            CVAttachmentMode mode = kCVAttachmentMode_ShouldNotPropagate;
            CFTypeRef value = CVBufferGetAttachment(PIXEL, O(CFStringRef, 1), &mode);
            if(V(2) && !Write(V(2), u32(mode))) return 0;
            return Borrowed(value);
        }
        case LC32CVBufferRemoveAttachment:
            NEED(2);
            if(PIXEL && call.slots[1]) CVBufferRemoveAttachment(PIXEL, O(CFStringRef, 1));
            return 0;
        case LC32CVBufferRemoveAllAttachments:
            NEED(1); if(PIXEL) CVBufferRemoveAllAttachments(PIXEL); return 0;
        case LC32CVBufferGetAttachments:
            NEED(2); return PIXEL ? Borrowed(CVBufferGetAttachments(PIXEL,
                                        CVAttachmentMode(V(1)))) : 0;
        case LC32CVBufferSetAttachments:
            NEED(3);
            if(PIXEL && call.slots[1]) CVBufferSetAttachments(PIXEL,
                O(CFDictionaryRef, 1), CVAttachmentMode(V(2)));
            return 0;
        case LC32CVBufferPropagateAttachments:
            NEED(2);
            if(PIXEL && call.slots[1]) CVBufferPropagateAttachments(PIXEL, O(CVBufferRef, 1));
            return 0;
        case LC32CVPixelBufferPoolCreate: {
            NEED(4);
            if(!Write(V(3), u32(0))) return u32(kCVReturnInvalidArgument);
            CVPixelBufferPoolRef pool = nullptr;
            CVReturn result = CVPixelBufferPoolCreate(O(CFAllocatorRef, 0),
                O(CFDictionaryRef, 1), O(CFDictionaryRef, 2), &pool);
            return u32(Created(result, pool, V(3)));
        }
        case LC32CVPixelBufferPoolGetAttributes:
            NEED(1); return call.slots[0] ? Borrowed(
                CVPixelBufferPoolGetAttributes(O(CVPixelBufferPoolRef, 0))) : 0;
        case LC32CVPixelBufferPoolGetPixelBufferAttributes:
            NEED(1); return call.slots[0] ? Borrowed(
                CVPixelBufferPoolGetPixelBufferAttributes(O(CVPixelBufferPoolRef, 0))) : 0;
        case LC32CVPixelBufferPoolCreatePixelBufferWithAuxAttributes: {
            NEED(4);
            if(!Write(V(3), u32(0)) || !call.slots[1]) return u32(kCVReturnInvalidArgument);
            CVPixelBufferRef buffer = nullptr;
            CVReturn result = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
                O(CFAllocatorRef, 0), O(CVPixelBufferPoolRef, 1),
                O(CFDictionaryRef, 2), &buffer);
            return u32(Created(result, buffer, V(3)));
        }
        case LC32CVPixelBufferPoolFlush:
            NEED(2);
            if(call.slots[0]) CVPixelBufferPoolFlush(O(CVPixelBufferPoolRef, 0),
                                                    CVPixelBufferPoolFlushFlags(call.slots[1]));
            return 0;
        case LC32CVOpenGLESTextureCacheCreate: {
            NEED(5);
            if(!Write(V(4), u32(0)) || !call.slots[2]) return u32(kCVReturnInvalidArgument);
            CVOpenGLESTextureCacheRef cache = nullptr;
            CVReturn result = CVOpenGLESTextureCacheCreate(O(CFAllocatorRef, 0),
                O(CFDictionaryRef, 1), O(CVEAGLContext, 2), O(CFDictionaryRef, 3), &cache);
            return u32(Created(result, cache, V(4)));
        }
        case LC32CVOpenGLESTextureCacheCreateTextureFromImage: {
            NEED(12);
            if(!Write(V(11), u32(0)) || !call.slots[1] || !call.slots[2])
                return u32(kCVReturnInvalidArgument);
            CVOpenGLESTextureRef texture = nullptr;
            CVReturn result = CVOpenGLESTextureCacheCreateTextureFromImage(
                O(CFAllocatorRef, 0), O(CVOpenGLESTextureCacheRef, 1),
                O(CVImageBufferRef, 2), O(CFDictionaryRef, 3), V(4), GLint(V(5)),
                GLsizei(V(6)), GLsizei(V(7)), V(8), V(9), V(10), &texture);
            return u32(Created(result, texture, V(11)));
        }
        case LC32CVOpenGLESTextureCacheFlush:
            NEED(2);
            if(call.slots[0]) CVOpenGLESTextureCacheFlush(O(CVOpenGLESTextureCacheRef, 0), call.slots[1]);
            return 0;
        case LC32CVOpenGLESTextureGetCleanTexCoords: {
            NEED(5);
            if(!call.slots[0]) return 0;
            GLfloat coordinates[4][2] = {};
            CVOpenGLESTextureGetCleanTexCoords(O(CVOpenGLESTextureRef, 0),
                coordinates[0], coordinates[1], coordinates[2], coordinates[3]);
            for(size_t i = 0; i < 4; ++i)
                if(V(i + 1)) Write(V(i + 1), coordinates[i]);
            return 0;
        }
        case LC32CVImageBufferGetColorSpace:
            NEED(1); return PIXEL ? Borrowed(CVImageBufferGetColorSpace(PIXEL)) : 0;
        case LC32CVImageBufferGetEncodedSize:
        case LC32CVImageBufferGetDisplaySize: {
            NEED(2);
            if(!PIXEL) return 0;
            CGSize size = operation == LC32CVImageBufferGetEncodedSize
                ? CVImageBufferGetEncodedSize(PIXEL) : CVImageBufferGetDisplaySize(PIXEL);
            const float guest[] = {float(size.width), float(size.height)};
            return Write(V(1), guest);
        }
        case LC32CVImageBufferGetCleanRect: {
            NEED(2);
            if(!PIXEL) return 0;
            CGRect rect = CVImageBufferGetCleanRect(PIXEL);
            const float guest[] = {float(rect.origin.x), float(rect.origin.y),
                                  float(rect.size.width), float(rect.size.height)};
            return Write(V(1), guest);
        }
        default: return u32(kCVReturnUnsupported);
    }
#undef NEED
#undef V
#undef O
#undef PIXEL
#undef SCALAR
#undef TYPEID
}
#pragma clang diagnostic pop
