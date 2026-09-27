#import <CoreVideo/CoreVideo.h>
#import <LC32/LC32.h>
#import "LC32CoreVideoBridge.h"
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

static pthread_once_t dispatcherOnce = PTHREAD_ONCE_INIT;
static uint64_t dispatcherAddress;
static void ResolveDispatcher(void) {
    dispatcherAddress = LC32Dlsym("LC32_CoreVideo_Dispatch", YES);
}

static uint32_t Dispatch(LC32CoreVideoOpcode opcode,
                         const uint64_t *slots, uint32_t count) {
    pthread_once(&dispatcherOnce, ResolveDispatcher);
    if(!dispatcherAddress || count > LC32CoreVideoMaxSlots)
        return (uint32_t)kCVReturnUnsupported;
    LC32CoreVideoCall call = { .version = LC32CoreVideoABIVersion,
                              .slotCount = count };
    if(count) memcpy(call.slots, slots, count * sizeof(*slots));
    return LC32InvokeHostCRet32(dispatcherAddress, (uint32_t)opcode,
                              (uint32_t)(uintptr_t)&call);
}

static uint64_t Host(const void *object) {
    return object ? [(id)object host_self] : 0;
}
#define PTR(p) ((uint32_t)(uintptr_t)(p))
#define CALL(op, ...) Dispatch(LC32##op, (const uint64_t[]){__VA_ARGS__}, \
    sizeof((const uint64_t[]){__VA_ARGS__}) / sizeof(uint64_t))
#define CALL0(op) Dispatch(LC32##op, NULL, 0)

// This storage must remain guest-only: a native NSObject peer would neither
// own the ARM32 allocation nor understand its lock bookkeeping.
@interface LC32PixelBufferStorage : LC32GuestBuffer {
@public
    LC32CoreVideoLayout layout;
    uint32_t lockDepth;
    CVPixelBufferLockFlags flags;
}
@end
@implementation LC32PixelBufferStorage
@end

static const char storageKey;
static LC32PixelBufferStorage *Storage(CVPixelBufferRef buffer, BOOL create) {
    LC32PixelBufferStorage *storage = objc_getAssociatedObject((id)buffer,
                                                               &storageKey);
    if(!storage && create) {
        storage = [LC32PixelBufferStorage new];
        objc_setAssociatedObject((id)buffer, &storageKey, storage,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [storage release];
    }
    return storage;
}

CVReturn CVPixelBufferLockBaseAddress(CVPixelBufferRef buffer,
                                     CVPixelBufferLockFlags flags) {
    if(!buffer) return kCVReturnInvalidArgument;
    @synchronized((id)buffer) {
        LC32PixelBufferStorage *storage = Storage(buffer, YES);
        if(!storage) return kCVReturnAllocationFailed;
        if(storage->lockDepth) {
            if(storage->flags != flags || storage->lockDepth == UINT32_MAX)
                return kCVReturnInvalidArgument;
            ++storage->lockDepth;
            return kCVReturnSuccess;
        }
        CVReturn result = (CVReturn)CALL(CVPixelBufferLock,
            Host(buffer), (uint64_t)flags, PTR(&storage->layout));
        if(result != kCVReturnSuccess) return result;
        const uint32_t size = storage->layout.byteCount;
        if(!size || size > LC32CoreVideoMaxBytes ||
           storage->layout.planeCount > LC32CoreVideoMaxPlanes) {
            result = kCVReturnInvalidSize;
        } else if(storage->_capacity < size) {
            void *bytes = realloc(storage->_bytes, size);
            if(!bytes) result = kCVReturnAllocationFailed;
            else { storage->_bytes = bytes; storage->_capacity = size; }
        }
        if(result == kCVReturnSuccess) {
            memset(storage->_bytes, 0, size);
            // The legacy planar descriptor contains big-endian offsets and
            // row strides, not pointers (and not host IOSurface metadata).
            CVPlanarComponentInfo *components = storage->_bytes;
            for(uint32_t i = 0; i < storage->layout.planeCount; ++i) {
                components[i].offset = CFSwapInt32HostToBig(
                    storage->layout.planes[i].offset);
                components[i].rowBytes = CFSwapInt32HostToBig(
                    storage->layout.planes[i].rowBytes);
            }
            result = (CVReturn)CALL(CVPixelBufferCopyPixels,
                Host(buffer), PTR(storage->_bytes), size, 0);
        }
        if(result != kCVReturnSuccess) {
            CALL(CVPixelBufferUnlock, Host(buffer), (uint64_t)flags);
            return result;
        }
        storage->flags = flags;
        storage->lockDepth = 1;
        return kCVReturnSuccess;
    }
}

CVReturn CVPixelBufferUnlockBaseAddress(CVPixelBufferRef buffer,
                                       CVPixelBufferLockFlags flags) {
    if(!buffer) return kCVReturnInvalidArgument;
    @synchronized((id)buffer) {
        LC32PixelBufferStorage *storage = Storage(buffer, NO);
        if(!storage || !storage->lockDepth || flags != storage->flags)
            return kCVReturnInvalidArgument;
        if(--storage->lockDepth) return kCVReturnSuccess;
        CVReturn result = kCVReturnSuccess;
        if(!(flags & kCVPixelBufferLock_ReadOnly)) {
            result = (CVReturn)CALL(CVPixelBufferCopyPixels,
                Host(buffer), PTR(storage->_bytes), storage->layout.byteCount, 1);
        }
        const CVReturn unlocked = (CVReturn)CALL(CVPixelBufferUnlock,
            Host(buffer), (uint64_t)flags);
        return result == kCVReturnSuccess ? unlocked : result;
    }
}

void *CVPixelBufferGetBaseAddress(CVPixelBufferRef buffer) {
    if(!buffer) return NULL;
    @synchronized((id)buffer) {
        LC32PixelBufferStorage *storage = Storage(buffer, NO);
        return storage && storage->lockDepth ? storage->_bytes : NULL;
    }
}

void *CVPixelBufferGetBaseAddressOfPlane(CVPixelBufferRef buffer, size_t plane) {
    if(!buffer) return NULL;
    @synchronized((id)buffer) {
        LC32PixelBufferStorage *storage = Storage(buffer, NO);
        if(!storage || !storage->lockDepth || plane >= storage->layout.planeCount)
            return NULL;
        return (char *)storage->_bytes + storage->layout.planes[plane].offset;
    }
}

CVBufferRef CVBufferRetain(CVBufferRef buffer) {
    return buffer ? (CVBufferRef)CFRetain(buffer) : NULL;
}
void CVBufferRelease(CVBufferRef buffer) { if(buffer) CFRelease(buffer); }
CVPixelBufferRef CVPixelBufferRetain(CVPixelBufferRef buffer) {
    return (CVPixelBufferRef)CVBufferRetain(buffer);
}
void CVPixelBufferRelease(CVPixelBufferRef buffer) { CVBufferRelease(buffer); }
CVPixelBufferPoolRef CVPixelBufferPoolRetain(CVPixelBufferPoolRef pool) {
    return pool ? (CVPixelBufferPoolRef)CFRetain(pool) : NULL;
}
void CVPixelBufferPoolRelease(CVPixelBufferPoolRef pool) { if(pool) CFRelease(pool); }

#define TYPE_ID(name) CFTypeID name(void) { return CALL0(name); }
TYPE_ID(CVPixelBufferGetTypeID)
TYPE_ID(CVPixelBufferPoolGetTypeID)
TYPE_ID(CVOpenGLESTextureGetTypeID)
TYPE_ID(CVOpenGLESTextureCacheGetTypeID)
#define GETTER(result, name, type) \
    result name(type object) { return object ? (result)CALL(name, Host(object)) : 0; }
GETTER(size_t, CVPixelBufferGetWidth, CVPixelBufferRef)
GETTER(size_t, CVPixelBufferGetHeight, CVPixelBufferRef)
GETTER(OSType, CVPixelBufferGetPixelFormatType, CVPixelBufferRef)
GETTER(size_t, CVPixelBufferGetBytesPerRow, CVPixelBufferRef)
GETTER(size_t, CVPixelBufferGetDataSize, CVPixelBufferRef)
GETTER(Boolean, CVPixelBufferIsPlanar, CVPixelBufferRef)
GETTER(size_t, CVPixelBufferGetPlaneCount, CVPixelBufferRef)
GETTER(CFDictionaryRef, CVPixelBufferPoolGetAttributes, CVPixelBufferPoolRef)
GETTER(CFDictionaryRef, CVPixelBufferPoolGetPixelBufferAttributes, CVPixelBufferPoolRef)
GETTER(GLuint, CVOpenGLESTextureGetName, CVOpenGLESTextureRef)
GETTER(GLenum, CVOpenGLESTextureGetTarget, CVOpenGLESTextureRef)
GETTER(Boolean, CVOpenGLESTextureIsFlipped, CVOpenGLESTextureRef)
GETTER(Boolean, CVImageBufferIsFlipped, CVImageBufferRef)
GETTER(CGColorSpaceRef, CVImageBufferGetColorSpace, CVImageBufferRef)
#define PLANE_GETTER(name) size_t name(CVPixelBufferRef buffer, size_t plane) { \
    return buffer ? CALL(name, Host(buffer), (uint32_t)plane) : 0; }
PLANE_GETTER(CVPixelBufferGetWidthOfPlane)
PLANE_GETTER(CVPixelBufferGetHeightOfPlane)
PLANE_GETTER(CVPixelBufferGetBytesPerRowOfPlane)

CVReturn CVPixelBufferCreate(CFAllocatorRef allocator, size_t width,
        size_t height, OSType format, CFDictionaryRef attributes,
        CVPixelBufferRef *output) {
    if(!output) return kCVReturnInvalidArgument;
    *output = NULL;
    return (CVReturn)CALL(CVPixelBufferCreate, Host(allocator),
        (uint32_t)width, (uint32_t)height, (uint32_t)format,
        Host(attributes), PTR(output));
}
CVReturn CVPixelBufferCreateResolvedAttributesDictionary(CFAllocatorRef allocator,
        CFArrayRef attributes, CFDictionaryRef *output) {
    if(!output) return kCVReturnInvalidArgument;
    *output = NULL;
    return (CVReturn)CALL(CVPixelBufferCreateResolvedAttributesDictionary,
        Host(allocator), Host(attributes), PTR(output));
}
CVReturn CVPixelBufferPoolCreate(CFAllocatorRef allocator,
        CFDictionaryRef poolAttributes, CFDictionaryRef pixelAttributes,
        CVPixelBufferPoolRef *output) {
    if(!output) return kCVReturnInvalidArgument;
    *output = NULL;
    return (CVReturn)CALL(CVPixelBufferPoolCreate, Host(allocator),
        Host(poolAttributes), Host(pixelAttributes), PTR(output));
}
CVReturn CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
        CFAllocatorRef allocator, CVPixelBufferPoolRef pool,
        CFDictionaryRef attributes, CVPixelBufferRef *output) {
    if(!output) return kCVReturnInvalidArgument;
    *output = NULL;
    return (CVReturn)CALL(CVPixelBufferPoolCreatePixelBufferWithAuxAttributes,
        Host(allocator), Host(pool), Host(attributes), PTR(output));
}
CVReturn CVPixelBufferPoolCreatePixelBuffer(CFAllocatorRef allocator,
        CVPixelBufferPoolRef pool, CVPixelBufferRef *output) {
    return CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
        allocator, pool, NULL, output);
}
void CVPixelBufferPoolFlush(CVPixelBufferPoolRef pool, CVPixelBufferPoolFlushFlags flags) {
    if(pool) CALL(CVPixelBufferPoolFlush, Host(pool), (uint64_t)flags);
}

void CVBufferSetAttachment(CVBufferRef buffer, CFStringRef key,
                          CFTypeRef value, CVAttachmentMode mode) {
    if(buffer && key && value) CALL(CVBufferSetAttachment,
        Host(buffer), Host(key), Host(value), (uint32_t)mode);
}
CFTypeRef CVBufferGetAttachment(CVBufferRef buffer, CFStringRef key,
                               CVAttachmentMode *mode) {
    return buffer && key ? (CFTypeRef)CALL(CVBufferGetAttachment,
        Host(buffer), Host(key), PTR(mode)) : NULL;
}
void CVBufferRemoveAttachment(CVBufferRef buffer, CFStringRef key) {
    if(buffer && key) CALL(CVBufferRemoveAttachment, Host(buffer), Host(key));
}
void CVBufferRemoveAllAttachments(CVBufferRef buffer) {
    if(buffer) CALL(CVBufferRemoveAllAttachments, Host(buffer));
}
CFDictionaryRef CVBufferGetAttachments(CVBufferRef buffer, CVAttachmentMode mode) {
    return buffer ? (CFDictionaryRef)CALL(CVBufferGetAttachments,
        Host(buffer), (uint32_t)mode) : NULL;
}
void CVBufferSetAttachments(CVBufferRef buffer, CFDictionaryRef attributes,
                            CVAttachmentMode mode) {
    if(buffer && attributes) CALL(CVBufferSetAttachments,
        Host(buffer), Host(attributes), (uint32_t)mode);
}
void CVBufferPropagateAttachments(CVBufferRef source, CVBufferRef destination) {
    if(source && destination) CALL(CVBufferPropagateAttachments,
        Host(source), Host(destination));
}

CVReturn CVOpenGLESTextureCacheCreate(CFAllocatorRef allocator,
        CFDictionaryRef attributes, CVEAGLContext context,
        CFDictionaryRef textureAttributes, CVOpenGLESTextureCacheRef *output) {
    if(!output) return kCVReturnInvalidArgument;
    *output = NULL;
    return (CVReturn)CALL(CVOpenGLESTextureCacheCreate, Host(allocator),
        Host(attributes), Host(context), Host(textureAttributes), PTR(output));
}
CVReturn CVOpenGLESTextureCacheCreateTextureFromImage(CFAllocatorRef allocator,
        CVOpenGLESTextureCacheRef cache, CVImageBufferRef image,
        CFDictionaryRef attributes, GLenum target, GLint internalFormat,
        GLsizei width, GLsizei height, GLenum format, GLenum type,
        size_t plane, CVOpenGLESTextureRef *output) {
    if(!output) return kCVReturnInvalidArgument;
    *output = NULL;
    return (CVReturn)CALL(CVOpenGLESTextureCacheCreateTextureFromImage,
        Host(allocator), Host(cache), Host(image), Host(attributes),
        target, (uint32_t)internalFormat, (uint32_t)width, (uint32_t)height,
        format, type, (uint32_t)plane, PTR(output));
}
void CVOpenGLESTextureCacheFlush(CVOpenGLESTextureCacheRef cache, CVOptionFlags flags) {
    if(cache) CALL(CVOpenGLESTextureCacheFlush, Host(cache), (uint64_t)flags);
}
void CVOpenGLESTextureGetCleanTexCoords(CVOpenGLESTextureRef texture,
        GLfloat lowerLeft[2], GLfloat lowerRight[2],
        GLfloat upperRight[2], GLfloat upperLeft[2]) {
    if(texture) CALL(CVOpenGLESTextureGetCleanTexCoords, Host(texture),
        PTR(lowerLeft), PTR(lowerRight), PTR(upperRight), PTR(upperLeft));
}

CGSize CVImageBufferGetEncodedSize(CVImageBufferRef buffer) {
    CGSize result = CGSizeZero;
    if(buffer) CALL(CVImageBufferGetEncodedSize, Host(buffer), PTR(&result));
    return result;
}
CGSize CVImageBufferGetDisplaySize(CVImageBufferRef buffer) {
    CGSize result = CGSizeZero;
    if(buffer) CALL(CVImageBufferGetDisplaySize, Host(buffer), PTR(&result));
    return result;
}
CGRect CVImageBufferGetCleanRect(CVImageBufferRef buffer) {
    CGRect result = CGRectZero;
    if(buffer) CALL(CVImageBufferGetCleanRect, Host(buffer), PTR(&result));
    return result;
}
