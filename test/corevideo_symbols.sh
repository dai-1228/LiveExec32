#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
image=${1:-"$repo_root/GuestMakefile/.theos/obj/armv7s/CoreVideo.framework/CoreVideo"}
test -f "$image" || {
    echo "missing CoreVideo guest image: $image" >&2
    exit 1
}

# The GLES texture-cache entry points are eagerly imported by older games,
# even when their CPU pixel-buffer fallback is used on a particular host.
expected='CVPixelBufferGetBaseAddress CVPixelBufferGetBytesPerRow
CVPixelBufferGetWidth CVPixelBufferGetHeight CVPixelBufferLockBaseAddress
CVPixelBufferUnlockBaseAddress CVOpenGLESTextureCacheCreate
CVOpenGLESTextureCacheCreateTextureFromImage CVOpenGLESTextureCacheFlush
CVOpenGLESTextureGetName CVOpenGLESTextureGetTarget CVOpenGLESTextureIsFlipped
CVPixelBufferCreate CVPixelBufferGetTypeID CVPixelBufferRetain CVPixelBufferRelease
CVPixelBufferGetPixelFormatType CVPixelBufferGetDataSize CVPixelBufferIsPlanar
CVPixelBufferGetPlaneCount CVPixelBufferGetBaseAddressOfPlane
CVPixelBufferGetBytesPerRowOfPlane CVPixelBufferGetWidthOfPlane
CVPixelBufferGetHeightOfPlane CVBufferRetain CVBufferRelease
CVBufferGetAttachment CVBufferGetAttachments CVBufferSetAttachment
CVBufferSetAttachments CVBufferPropagateAttachments CVBufferRemoveAttachment
CVBufferRemoveAllAttachments CVPixelBufferPoolCreate CVPixelBufferPoolGetTypeID
CVPixelBufferPoolRetain CVPixelBufferPoolRelease CVPixelBufferPoolGetAttributes
CVPixelBufferPoolGetPixelBufferAttributes CVPixelBufferPoolCreatePixelBuffer
CVPixelBufferPoolCreatePixelBufferWithAuxAttributes CVPixelBufferPoolFlush
kCVPixelBufferWidthKey kCVPixelBufferHeightKey kCVPixelBufferPixelFormatTypeKey
kCVPixelBufferPoolMinimumBufferCountKey kCVPixelBufferIOSurfacePropertiesKey
kCVPixelBufferOpenGLESCompatibilityKey'

actual=$(nm -gU "$image" | awk '{print $NF}')
missing=0
count=0
for symbol in $expected; do
    count=$((count + 1))
    if ! printf '%s\n' "$actual" | rg -q -F -x -- "_$symbol"; then
        printf '  missing _%s\n' "$symbol"
        missing=$((missing + 1))
    fi
done
printf 'CoreVideo required symbols expected=%s missing=%s\n' "$count" "$missing"
test "$missing" -eq 0
