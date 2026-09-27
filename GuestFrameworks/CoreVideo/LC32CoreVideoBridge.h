#ifndef LC32_CORE_VIDEO_BRIDGE_H
#define LC32_CORE_VIDEO_BRIDGE_H

#include <stdint.h>
#include <stddef.h>

enum {
    LC32CoreVideoABIVersion = 1,
    LC32CoreVideoMaxSlots = 16,
    LC32CoreVideoMaxPlanes = 8,
    LC32CoreVideoMaxBytes = 256 * 1024 * 1024,
};

typedef struct {
    uint32_t version, slotCount;
    uint64_t slots[LC32CoreVideoMaxSlots];
} LC32CoreVideoCall;

// Guest storage is contiguous even when the native IOSurface planes are not.
// No native base address or native size_t is published in this wire format.
typedef struct {
    uint32_t byteCount, planeCount;
    struct { uint32_t offset, rowBytes, height; } planes[LC32CoreVideoMaxPlanes];
} LC32CoreVideoLayout;

#ifdef __cplusplus
static_assert(sizeof(LC32CoreVideoCall) == 136 &&
              offsetof(LC32CoreVideoCall, slots) == 8 &&
              sizeof(LC32CoreVideoLayout) == 104,
              "CoreVideo wire layouts must match ARM32");
#else
_Static_assert(sizeof(LC32CoreVideoCall) == 136 &&
               offsetof(LC32CoreVideoCall, slots) == 8 &&
               sizeof(LC32CoreVideoLayout) == 104,
               "CoreVideo wire layouts must match ARM64");
#endif

typedef enum : uint32_t {
    LC32CVPixelBufferCreate = 1,
    LC32CVPixelBufferGetTypeID,
    LC32CVPixelBufferGetWidth,
    LC32CVPixelBufferGetHeight,
    LC32CVPixelBufferGetPixelFormatType,
    LC32CVPixelBufferGetBytesPerRow,
    LC32CVPixelBufferGetDataSize,
    LC32CVPixelBufferIsPlanar,
    LC32CVPixelBufferGetPlaneCount,
    LC32CVPixelBufferGetWidthOfPlane,
    LC32CVPixelBufferGetHeightOfPlane,
    LC32CVPixelBufferGetBytesPerRowOfPlane,
    LC32CVPixelBufferLock,
    LC32CVPixelBufferCopyPixels,
    LC32CVPixelBufferUnlock,
    LC32CVPixelBufferCreateResolvedAttributesDictionary,
    LC32CVBufferSetAttachment,
    LC32CVBufferGetAttachment,
    LC32CVBufferRemoveAttachment,
    LC32CVBufferRemoveAllAttachments,
    LC32CVBufferGetAttachments,
    LC32CVBufferSetAttachments,
    LC32CVBufferPropagateAttachments,
    LC32CVPixelBufferPoolCreate,
    LC32CVPixelBufferPoolGetTypeID,
    LC32CVPixelBufferPoolGetAttributes,
    LC32CVPixelBufferPoolGetPixelBufferAttributes,
    LC32CVPixelBufferPoolCreatePixelBufferWithAuxAttributes,
    LC32CVPixelBufferPoolFlush,
    LC32CVOpenGLESTextureCacheCreate,
    LC32CVOpenGLESTextureCacheGetTypeID,
    LC32CVOpenGLESTextureCacheCreateTextureFromImage,
    LC32CVOpenGLESTextureCacheFlush,
    LC32CVOpenGLESTextureGetTypeID,
    LC32CVOpenGLESTextureGetName,
    LC32CVOpenGLESTextureGetTarget,
    LC32CVOpenGLESTextureIsFlipped,
    LC32CVOpenGLESTextureGetCleanTexCoords,
    LC32CVImageBufferGetEncodedSize,
    LC32CVImageBufferGetDisplaySize,
    LC32CVImageBufferGetCleanRect,
    LC32CVImageBufferIsFlipped,
    LC32CVImageBufferGetColorSpace,
} LC32CoreVideoOpcode;

#endif
