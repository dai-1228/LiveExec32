#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#define GLES_SILENCE_DEPRECATION 1
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES2/gl.h>
#endif

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int checks;
static int failures;

static int report(const char *name, int passed) {
    ++checks;
    if(!passed) ++failures;
    printf("corevideo-%s: %s\n", name, passed ? "PASS" : "FAIL");
    return passed;
}

static CVPixelBufferRef createBuffer(size_t width, size_t height, OSType format) {
    CVPixelBufferRef buffer = NULL;
    CVReturn result = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
        format, NULL, &buffer);
    if(result != kCVReturnSuccess) {
        printf("corevideo-create-result: %d\n", (int)result);
    }
    return result == kCVReturnSuccess ? buffer : NULL;
}

static unsigned char pattern(size_t index, unsigned seed) {
    return (unsigned char)((index * 37u + (index >> 8) + seed) & 255u);
}

static int checkPattern(const unsigned char *bytes, size_t count,
                        unsigned seed) {
    if(!bytes) return 0;
    for(size_t index = 0; index < count; ++index)
        if(bytes[index] != pattern(index, seed)) return 0;
    return 1;
}

static void testChunkyBuffer(void) {
    /* An odd width exercises row padding; the image crosses several guest
     * pages so a translated pointer to its first page is insufficient. */
    CVPixelBufferRef buffer = createBuffer(37, 73, kCVPixelFormatType_32BGRA);
    if(!report("chunky-create", buffer != NULL)) return;
    const size_t rowBytes = CVPixelBufferGetBytesPerRow(buffer);
    const size_t byteCount = rowBytes * 73;
    if(!report("chunky-layout", CVPixelBufferGetWidth(buffer) == 37 &&
        CVPixelBufferGetHeight(buffer) == 73 && rowBytes >= 37 * 4 &&
        rowBytes < 4096 && byteCount > 4096 &&
        CVPixelBufferGetDataSize(buffer) >= byteCount &&
        CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA &&
        !CVPixelBufferIsPlanar(buffer) && CVPixelBufferGetPlaneCount(buffer) == 0)) {
        CVPixelBufferRelease(buffer);
        return;
    }
    report("pixel-type-id", CFGetTypeID(buffer) == CVPixelBufferGetTypeID());
    report("pixel-retain-identity", CVPixelBufferRetain(buffer) == buffer);
    CVPixelBufferRelease(buffer);

    if(!report("chunky-lock", CVPixelBufferLockBaseAddress(buffer, 0) ==
            kCVReturnSuccess)) {
        CVPixelBufferRelease(buffer);
        return;
    }
    unsigned char *bytes = CVPixelBufferGetBaseAddress(buffer);
    if(report("chunky-base-address", bytes != NULL)) {
        for(size_t index = 0; index < byteCount; ++index)
            bytes[index] = pattern(index, 19);
    }

    CVReturn nested = CVPixelBufferLockBaseAddress(buffer, 0);
    report("nested-lock", nested == kCVReturnSuccess);
    if(nested == kCVReturnSuccess) {
        unsigned char *nestedBytes = CVPixelBufferGetBaseAddress(buffer);
        report("nested-keeps-pointer-and-writes", nestedBytes == bytes &&
            checkPattern(nestedBytes, byteCount, 19));
        report("nested-unlock", CVPixelBufferUnlockBaseAddress(buffer, 0) ==
            kCVReturnSuccess);
        report("outer-lock-remains-valid", CVPixelBufferGetBaseAddress(buffer) ==
            bytes && checkPattern(bytes, byteCount, 19));
    }
    report("chunky-unlock", CVPixelBufferUnlockBaseAddress(buffer, 0) ==
        kCVReturnSuccess);

    for(unsigned cycle = 0; cycle < 3; ++cycle) {
        CVReturn locked = CVPixelBufferLockBaseAddress(buffer,
            kCVPixelBufferLock_ReadOnly);
        report("readonly-lock", locked == kCVReturnSuccess);
        if(locked != kCVReturnSuccess) break;
        report("readonly-relock-sees-written-data", checkPattern(
            CVPixelBufferGetBaseAddress(buffer), byteCount, 19));
        report("readonly-unlock", CVPixelBufferUnlockBaseAddress(buffer,
            kCVPixelBufferLock_ReadOnly) == kCVReturnSuccess);
    }
    CVPixelBufferRelease(buffer);
}

static void testPlanarBuffer(void) {
    CVPixelBufferRef buffer = createBuffer(64, 48,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    if(!report("planar-create", buffer != NULL)) return;
    if(!report("planar-layout", CVPixelBufferIsPlanar(buffer) &&
        CVPixelBufferGetPlaneCount(buffer) == 2 &&
        CVPixelBufferGetWidthOfPlane(buffer, 0) == 64 &&
        CVPixelBufferGetHeightOfPlane(buffer, 0) == 48 &&
        CVPixelBufferGetWidthOfPlane(buffer, 1) == 32 &&
        CVPixelBufferGetHeightOfPlane(buffer, 1) == 24)) {
        CVPixelBufferRelease(buffer);
        return;
    }
    if(!report("planar-lock", CVPixelBufferLockBaseAddress(buffer, 0) ==
            kCVReturnSuccess)) {
        CVPixelBufferRelease(buffer);
        return;
    }
    for(size_t plane = 0; plane < 2; ++plane) {
        const size_t rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane);
        const size_t height = CVPixelBufferGetHeightOfPlane(buffer, plane);
        unsigned char *bytes = CVPixelBufferGetBaseAddressOfPlane(buffer, plane);
        if(report("plane-address-and-stride", bytes && rowBytes >= 64 &&
                rowBytes < 4096 && height)) {
            for(size_t index = 0; index < rowBytes * height; ++index)
                bytes[index] = pattern(index, (unsigned)plane + 31);
        }
    }
    /* CoreVideo permits a NULL aggregate base for some IOSurface layouts.
     * When a descriptor exists, offsets are relative and big-endian, never
     * guest-sized casts of native plane pointers. */
    const CVPlanarPixelBufferInfo_YCbCrBiPlanar *descriptor =
        CVPixelBufferGetBaseAddress(buffer);
    if(descriptor) {
        const CVPlanarComponentInfo *components[] = {
            &descriptor->componentInfoY, &descriptor->componentInfoCbCr,
        };
        for(size_t plane = 0; plane < 2; ++plane) {
            const int32_t offset = (int32_t)CFSwapInt32BigToHost(
                (uint32_t)components[plane]->offset);
            report("planar-relative-descriptor", (const unsigned char *)descriptor +
                offset == CVPixelBufferGetBaseAddressOfPlane(buffer, plane) &&
                CFSwapInt32BigToHost(components[plane]->rowBytes) ==
                    CVPixelBufferGetBytesPerRowOfPlane(buffer, plane));
        }
    }
    report("planar-unlock", CVPixelBufferUnlockBaseAddress(buffer, 0) ==
        kCVReturnSuccess);
    if(report("planar-readonly-lock", CVPixelBufferLockBaseAddress(buffer,
            kCVPixelBufferLock_ReadOnly) == kCVReturnSuccess)) {
        for(size_t plane = 0; plane < 2; ++plane)
            report("planar-writeback", checkPattern(
                CVPixelBufferGetBaseAddressOfPlane(buffer, plane),
                CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) *
                    CVPixelBufferGetHeightOfPlane(buffer, plane),
                (unsigned)plane + 31));
        report("planar-readonly-unlock", CVPixelBufferUnlockBaseAddress(buffer,
            kCVPixelBufferLock_ReadOnly) == kCVReturnSuccess);
    }
    CVPixelBufferRelease(buffer);
}

static void testAttachments(void) {
    CVPixelBufferRef source = createBuffer(8, 8, kCVPixelFormatType_32BGRA);
    CVPixelBufferRef destination = createBuffer(8, 8, kCVPixelFormatType_32BGRA);
    if(!report("attachments-create", source && destination)) {
        CVPixelBufferRelease(source);
        CVPixelBufferRelease(destination);
        return;
    }
    CFStringRef propagatedKey = CFSTR("LC32Propagated");
    CFStringRef privateKey = CFSTR("LC32Private");
    CVBufferSetAttachment(source, propagatedKey, CFSTR("public-value"),
        kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(source, privateKey, CFSTR("private-value"),
        kCVAttachmentMode_ShouldNotPropagate);
    struct {
        uint32_t before;
        CVAttachmentMode mode;
        uint32_t after;
    } output = {0x12345678, kCVAttachmentMode_ShouldNotPropagate, 0x87654321};
    CFTypeRef value = CVBufferGetAttachment(source, propagatedKey, &output.mode);
    report("attachment-mode-output-width", value &&
        CFEqual(value, CFSTR("public-value")) &&
        output.mode == kCVAttachmentMode_ShouldPropagate &&
        output.before == 0x12345678 && output.after == 0x87654321);
    CFDictionaryRef attachments = CVBufferGetAttachments(source,
        kCVAttachmentMode_ShouldPropagate);
    report("attachment-dictionary", attachments &&
        CFDictionaryGetCount(attachments) == 1 &&
        CFDictionaryContainsKey(attachments, propagatedKey));
    CVBufferPropagateAttachments(source, destination);
    report("attachment-propagation", CVBufferGetAttachment(destination,
        propagatedKey, NULL) && !CVBufferGetAttachment(destination, privateKey, NULL));
    CVBufferSetAttachments(destination, (CFDictionaryRef)@{ @"LC32Bulk": @"bulk" },
        kCVAttachmentMode_ShouldNotPropagate);
    report("attachment-bulk", CVBufferGetAttachment(destination,
        CFSTR("LC32Bulk"), NULL) != NULL);
    CVBufferRemoveAttachment(destination, propagatedKey);
    report("attachment-remove", !CVBufferGetAttachment(destination, propagatedKey, NULL));
    CVBufferRemoveAllAttachments(destination);
    report("attachment-remove-all", !CVBufferGetAttachment(destination,
        CFSTR("LC32Bulk"), NULL));
    report("buffer-retain-identity", CVBufferRetain(source) == source);
    CVBufferRelease(source);
    CVPixelBufferRelease(source);
    CVPixelBufferRelease(destination);
}

static void testPool(void) {
    NSDictionary *pixelAttributes = @{
        (id)kCVPixelBufferWidthKey: @41,
        (id)kCVPixelBufferHeightKey: @29,
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
    };
    NSDictionary *poolAttributes = @{ (id)kCVPixelBufferPoolMinimumBufferCountKey: @1 };
    CVPixelBufferPoolRef pool = NULL;
    CVReturn result = CVPixelBufferPoolCreate(kCFAllocatorDefault,
        (CFDictionaryRef)poolAttributes, (CFDictionaryRef)pixelAttributes, &pool);
    if(!report("pool-create", result == kCVReturnSuccess && pool)) return;
    report("pool-type-id", CFGetTypeID(pool) == CVPixelBufferPoolGetTypeID());
    report("pool-retain-identity", CVPixelBufferPoolRetain(pool) == pool);
    CVPixelBufferPoolRelease(pool);
    CFDictionaryRef returnedAttributes = CVPixelBufferPoolGetPixelBufferAttributes(pool);
    report("pool-attributes", CVPixelBufferPoolGetAttributes(pool) &&
        returnedAttributes && CFDictionaryContainsKey(returnedAttributes,
            kCVPixelBufferWidthKey));
    CVPixelBufferRef first = NULL;
    result = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &first);
    report("pool-buffer", result == kCVReturnSuccess && first &&
        CVPixelBufferGetWidth(first) == 41 && CVPixelBufferGetHeight(first) == 29);
    CVPixelBufferRef second = NULL;
    result = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
        kCFAllocatorDefault, pool, NULL, &second);
    report("pool-buffer-with-aux", result == kCVReturnSuccess && second &&
        CVPixelBufferGetWidth(second) == 41 && CVPixelBufferGetHeight(second) == 29);
    CVPixelBufferRelease(first);
    CVPixelBufferRelease(second);
    CVPixelBufferPoolFlush(pool, kCVPixelBufferPoolFlushExcessBuffers);
    CVPixelBufferPoolRelease(pool);
}

#if TARGET_OS_IPHONE
static void testTextureVisibility(void) {
    EAGLContext *previous = [[EAGLContext currentContext] retain];
    EAGLContext *context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    CVPixelBufferRef buffer = NULL;
    CVOpenGLESTextureCacheRef cache = NULL;
    CVOpenGLESTextureRef texture = NULL;
    GLuint framebuffer = 0;
    if(!report("gles-context", context && [EAGLContext setCurrentContext:context]))
        goto cleanup;
    NSDictionary *attributes = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: [NSDictionary dictionary],
        (id)kCVPixelBufferOpenGLESCompatibilityKey: @YES,
    };
    CVReturn result = CVPixelBufferCreate(kCFAllocatorDefault, 64, 64,
        kCVPixelFormatType_32BGRA, (CFDictionaryRef)attributes, &buffer);
    if(!report("gles-pixel-buffer", result == kCVReturnSuccess && buffer)) goto cleanup;
    if(!report("gles-cpu-lock", CVPixelBufferLockBaseAddress(buffer, 0) ==
            kCVReturnSuccess)) goto cleanup;
    unsigned char *base = CVPixelBufferGetBaseAddress(buffer);
    const size_t rowBytes = CVPixelBufferGetBytesPerRow(buffer);
    if(base) {
        for(size_t y = 0; y < 64; ++y) {
            for(size_t x = 0; x < 64; ++x) {
                unsigned char *pixel = base + y * rowBytes + x * 4;
                pixel[0] = 0; pixel[1] = 0x34; pixel[2] = 0x92; pixel[3] = 255;
            }
        }
    }
    report("gles-cpu-base", base != NULL);
    if(!report("gles-cpu-unlock", CVPixelBufferUnlockBaseAddress(buffer, 0) ==
            kCVReturnSuccess)) goto cleanup;
    result = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, context,
        NULL, &cache);
    if(!report("gles-cache-create", result == kCVReturnSuccess && cache)) goto cleanup;
    result = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
        cache, buffer, NULL, GL_TEXTURE_2D, GL_RGBA, 64, 64, GL_RGBA,
        GL_UNSIGNED_BYTE, 0, &texture);
    if(result != kCVReturnSuccess)
        printf("corevideo-gles-texture-create-result: %d\n", (int)result);
    if(!report("gles-texture-create", result == kCVReturnSuccess && texture)) goto cleanup;
    const GLuint name = CVOpenGLESTextureGetName(texture);
    report("gles-texture-name-and-target", name &&
        CVOpenGLESTextureGetTarget(texture) == GL_TEXTURE_2D && glIsTexture(name));
    printf("corevideo-gles-texture-flipped: %u\n",
        (unsigned)CVOpenGLESTextureIsFlipped(texture));
    glGenFramebuffers(1, &framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
        GL_TEXTURE_2D, name, 0);
    if(!report("gles-framebuffer", glCheckFramebufferStatus(GL_FRAMEBUFFER) ==
            GL_FRAMEBUFFER_COMPLETE)) goto cleanup;
    unsigned char pixel[4] = {};
    glReadPixels(16, 16, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
    report("gles-observes-cpu-writeback", glGetError() == GL_NO_ERROR &&
        pixel[0] == 0x92 && pixel[1] == 0x34 && pixel[2] == 0 && pixel[3] == 255);
    glClearColor(0.125f, 0.25f, 0.5f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    glFinish();
    if(report("gles-readback-lock", CVPixelBufferLockBaseAddress(buffer,
            kCVPixelBufferLock_ReadOnly) == kCVReturnSuccess)) {
        base = CVPixelBufferGetBaseAddress(buffer);
        report("cpu-observes-gpu-write", base && abs((int)base[0] - 128) <= 1 &&
            abs((int)base[1] - 64) <= 1 && abs((int)base[2] - 32) <= 1 &&
            base[3] == 255);
        report("gles-readback-unlock", CVPixelBufferUnlockBaseAddress(buffer,
            kCVPixelBufferLock_ReadOnly) == kCVReturnSuccess);
    }
cleanup:
    if(framebuffer) glDeleteFramebuffers(1, &framebuffer);
    if(texture) CFRelease(texture);
    if(cache) { CVOpenGLESTextureCacheFlush(cache, 0); CFRelease(cache); }
    CVPixelBufferRelease(buffer);
    [EAGLContext setCurrentContext:previous];
    [context release];
    [previous release];
}
#endif

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    @autoreleasepool {
        testChunkyBuffer();
        testPlanarBuffer();
        testAttachments();
        testPool();
#if TARGET_OS_IPHONE
        /* Native GLES/IOSurface interop is host-dependent. Opt in when a
         * working EAGL host is available; CPU/ABI coverage always runs. */
        if(getenv("LC32_COREVIDEO_TEST_GLES") ||
                (argc > 1 && strcmp(argv[1], "--gles") == 0))
            testTextureVisibility();
#else
        (void)argc;
        (void)argv;
#endif
        CVPixelBufferRelease(NULL);
        CVBufferRelease(NULL);
        CVPixelBufferPoolRelease(NULL);
        report("null-safe-retains", !CVPixelBufferRetain(NULL) &&
            !CVBufferRetain(NULL) && !CVPixelBufferPoolRetain(NULL));
    }
    printf("corevideo-buffers-regression: %s (%d/%d)\n",
        failures ? "FAIL" : "PASS", checks - failures, checks);
    return failures != 0;
}
