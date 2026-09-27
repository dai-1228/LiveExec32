// Guest-native public CoreVideo constants.
// Values were read from the iOS 10.3.3 (14G60) armv7s CoreVideo image;
// only public SDK declarations actually exported by that image are included.
// Keep attachment, pixel-buffer, pool, and format-description keys in guest
// memory so they retain ordinary CFString equality and dictionary semantics.

#import <CoreVideo/CoreVideo.h>

#define LC32_CV_STRING(name, value) \
    const CFStringRef name = CFSTR(value)

// Buffer attachments.
LC32_CV_STRING(kCVBufferMovieTimeKey, "QTMovieTime");
LC32_CV_STRING(kCVBufferNonPropagatedAttachmentsKey, "NonPropagatedAttachments");
LC32_CV_STRING(kCVBufferPropagatedAttachmentsKey, "PropagatedAttachments");
LC32_CV_STRING(kCVBufferTimeScaleKey, "TimeScale");
LC32_CV_STRING(kCVBufferTimeValueKey, "TimeValue");

// Image-buffer attachments and values.
LC32_CV_STRING(kCVImageBufferAlphaChannelIsOpaque, "AlphaChannelIsOpaque");
LC32_CV_STRING(kCVImageBufferCGColorSpaceKey, "CGColorSpace");
LC32_CV_STRING(kCVImageBufferChromaLocationBottomFieldKey, "CVImageBufferChromaLocationBottomField");
LC32_CV_STRING(kCVImageBufferChromaLocationTopFieldKey, "CVImageBufferChromaLocationTopField");
LC32_CV_STRING(kCVImageBufferChromaLocation_Bottom, "Bottom");
LC32_CV_STRING(kCVImageBufferChromaLocation_BottomLeft, "BottomLeft");
LC32_CV_STRING(kCVImageBufferChromaLocation_Center, "Center");
LC32_CV_STRING(kCVImageBufferChromaLocation_DV420, "DV 4:2:0");
LC32_CV_STRING(kCVImageBufferChromaLocation_Left, "Left");
LC32_CV_STRING(kCVImageBufferChromaLocation_Top, "Top");
LC32_CV_STRING(kCVImageBufferChromaLocation_TopLeft, "TopLeft");
LC32_CV_STRING(kCVImageBufferChromaSubsamplingKey, "CVImageBufferChromaSubsampling");
LC32_CV_STRING(kCVImageBufferChromaSubsampling_411, "4:1:1");
LC32_CV_STRING(kCVImageBufferChromaSubsampling_420, "4:2:0");
LC32_CV_STRING(kCVImageBufferChromaSubsampling_422, "4:2:2");
LC32_CV_STRING(kCVImageBufferCleanApertureHeightKey, "Height");
LC32_CV_STRING(kCVImageBufferCleanApertureHorizontalOffsetKey, "HorizontalOffset");
LC32_CV_STRING(kCVImageBufferCleanApertureKey, "CVCleanAperture");
LC32_CV_STRING(kCVImageBufferCleanApertureVerticalOffsetKey, "VerticalOffset");
LC32_CV_STRING(kCVImageBufferCleanApertureWidthKey, "Width");
LC32_CV_STRING(kCVImageBufferColorPrimariesKey, "CVImageBufferColorPrimaries");
LC32_CV_STRING(kCVImageBufferColorPrimaries_DCI_P3, "DCI_P3");
LC32_CV_STRING(kCVImageBufferColorPrimaries_EBU_3213, "EBU_3213");
LC32_CV_STRING(kCVImageBufferColorPrimaries_ITU_R_2020, "ITU_R_2020");
LC32_CV_STRING(kCVImageBufferColorPrimaries_ITU_R_709_2, "ITU_R_709_2");
LC32_CV_STRING(kCVImageBufferColorPrimaries_P22, "P22");
LC32_CV_STRING(kCVImageBufferColorPrimaries_P3_D65, "P3_D65");
LC32_CV_STRING(kCVImageBufferColorPrimaries_SMPTE_C, "SMPTE_C");
LC32_CV_STRING(kCVImageBufferDisplayDimensionsKey, "CVDisplayDimensions");
LC32_CV_STRING(kCVImageBufferDisplayHeightKey, "Height");
LC32_CV_STRING(kCVImageBufferDisplayWidthKey, "Width");
LC32_CV_STRING(kCVImageBufferFieldCountKey, "CVFieldCount");
LC32_CV_STRING(kCVImageBufferFieldDetailKey, "CVFieldDetail");
LC32_CV_STRING(kCVImageBufferFieldDetailSpatialFirstLineEarly, "SpatialFirstLineEarly");
LC32_CV_STRING(kCVImageBufferFieldDetailSpatialFirstLineLate, "SpatialFirstLineLate");
LC32_CV_STRING(kCVImageBufferFieldDetailTemporalBottomFirst, "TemporalBottomFirst");
LC32_CV_STRING(kCVImageBufferFieldDetailTemporalTopFirst, "TemporalTopFirst");
LC32_CV_STRING(kCVImageBufferGammaLevelKey, "CVImageBufferGammaLevel");
LC32_CV_STRING(kCVImageBufferICCProfileKey, "CVImageBufferICCProfile");
LC32_CV_STRING(kCVImageBufferPixelAspectRatioHorizontalSpacingKey, "HorizontalSpacing");
LC32_CV_STRING(kCVImageBufferPixelAspectRatioKey, "CVPixelAspectRatio");
LC32_CV_STRING(kCVImageBufferPixelAspectRatioVerticalSpacingKey, "VerticalSpacing");
LC32_CV_STRING(kCVImageBufferPreferredCleanApertureKey, "CVPreferredCleanAperture");
LC32_CV_STRING(kCVImageBufferTransferFunctionKey, "CVImageBufferTransferFunction");
LC32_CV_STRING(kCVImageBufferTransferFunction_ITU_R_2020, "ITU_R_2020");
LC32_CV_STRING(kCVImageBufferTransferFunction_ITU_R_709_2, "ITU_R_709_2");
LC32_CV_STRING(kCVImageBufferTransferFunction_SMPTE_240M_1995, "SMPTE_240M_1995");
LC32_CV_STRING(kCVImageBufferTransferFunction_SMPTE_ST_428_1, "SMPTE_ST_428_1");
LC32_CV_STRING(kCVImageBufferTransferFunction_UseGamma, "UseGamma");
LC32_CV_STRING(kCVImageBufferYCbCrMatrixKey, "CVImageBufferYCbCrMatrix");
LC32_CV_STRING(kCVImageBufferYCbCrMatrix_DCI_P3, "DCI_P3");
LC32_CV_STRING(kCVImageBufferYCbCrMatrix_ITU_R_2020, "ITU_R_2020");
LC32_CV_STRING(kCVImageBufferYCbCrMatrix_ITU_R_601_4, "ITU_R_601_4");
LC32_CV_STRING(kCVImageBufferYCbCrMatrix_ITU_R_709_2, "ITU_R_709_2");
LC32_CV_STRING(kCVImageBufferYCbCrMatrix_P3_D65, "P3_D65");
LC32_CV_STRING(kCVImageBufferYCbCrMatrix_SMPTE_240M_1995, "SMPTE_240M_1995");

// Pixel-buffer attributes.
LC32_CV_STRING(kCVPixelBufferBytesPerRowAlignmentKey, "BytesPerRowAlignment");
LC32_CV_STRING(kCVPixelBufferCGBitmapContextCompatibilityKey, "CGBitmapContextCompatibility");
LC32_CV_STRING(kCVPixelBufferCGImageCompatibilityKey, "CGImageCompatibility");
LC32_CV_STRING(kCVPixelBufferExtendedPixelsBottomKey, "ExtendedPixelsBottom");
LC32_CV_STRING(kCVPixelBufferExtendedPixelsLeftKey, "ExtendedPixelsLeft");
LC32_CV_STRING(kCVPixelBufferExtendedPixelsRightKey, "ExtendedPixelsRight");
LC32_CV_STRING(kCVPixelBufferExtendedPixelsTopKey, "ExtendedPixelsTop");
LC32_CV_STRING(kCVPixelBufferHeightKey, "Height");
LC32_CV_STRING(kCVPixelBufferIOSurfacePropertiesKey, "IOSurfaceProperties");
LC32_CV_STRING(kCVPixelBufferMemoryAllocatorKey, "MemoryAllocator");
LC32_CV_STRING(kCVPixelBufferMetalCompatibilityKey, "MetalCompatibility");
LC32_CV_STRING(kCVPixelBufferOpenGLCompatibilityKey, "OpenGLCompatibility");
LC32_CV_STRING(kCVPixelBufferOpenGLESCompatibilityKey, "OpenGLESCompatibility");
LC32_CV_STRING(kCVPixelBufferOpenGLESTextureCacheCompatibilityKey, "OpenGLESTextureCacheCompatibility");
LC32_CV_STRING(kCVPixelBufferPixelFormatTypeKey, "PixelFormatType");
LC32_CV_STRING(kCVPixelBufferPlaneAlignmentKey, "PlaneAlignment");
LC32_CV_STRING(kCVPixelBufferWidthKey, "Width");

// Pixel-buffer pools.
LC32_CV_STRING(kCVPixelBufferPoolAllocationThresholdKey, "BufferPoolAllocationThreshold");
LC32_CV_STRING(kCVPixelBufferPoolFreeBufferNotification, "BufferPoolFreeBufferNotification");
LC32_CV_STRING(kCVPixelBufferPoolMaximumBufferAgeKey, "MaximumBufferAge");
LC32_CV_STRING(kCVPixelBufferPoolMinimumBufferCountKey, "MinimumBufferCount");

// Pixel-format descriptions.
LC32_CV_STRING(kCVPixelFormatBitsPerBlock, "BitsPerBlock");
LC32_CV_STRING(kCVPixelFormatBlackBlock, "BlackBlock");
LC32_CV_STRING(kCVPixelFormatBlockHeight, "BlockHeight");
LC32_CV_STRING(kCVPixelFormatBlockHorizontalAlignment, "BlockHorizontalAlignment");
LC32_CV_STRING(kCVPixelFormatBlockVerticalAlignment, "BlockVerticalAlignment");
LC32_CV_STRING(kCVPixelFormatBlockWidth, "BlockWidth");
LC32_CV_STRING(kCVPixelFormatCGBitmapContextCompatibility, "CGBitmapContextCompatibility");
LC32_CV_STRING(kCVPixelFormatCGBitmapInfo, "CGBitmapInfo");
LC32_CV_STRING(kCVPixelFormatCGImageCompatibility, "CGImageCompatibility");
LC32_CV_STRING(kCVPixelFormatCodecType, "CodecType");
LC32_CV_STRING(kCVPixelFormatComponentRange, "ComponentRange");
LC32_CV_STRING(kCVPixelFormatComponentRange_FullRange, "FullRange");
LC32_CV_STRING(kCVPixelFormatComponentRange_VideoRange, "VideoRange");
LC32_CV_STRING(kCVPixelFormatComponentRange_WideRange, "WideRange");
LC32_CV_STRING(kCVPixelFormatConstant, "PixelFormat");
LC32_CV_STRING(kCVPixelFormatContainsAlpha, "ContainsAlpha");
LC32_CV_STRING(kCVPixelFormatContainsRGB, "ContainsRGB");
LC32_CV_STRING(kCVPixelFormatContainsYCbCr, "ContainsYCbCr");
LC32_CV_STRING(kCVPixelFormatFillExtendedPixelsCallback, "FillExtendedPixelsCallback");
LC32_CV_STRING(kCVPixelFormatFourCC, "FourCC");
LC32_CV_STRING(kCVPixelFormatHorizontalSubsampling, "HorizontalSubsampling");
LC32_CV_STRING(kCVPixelFormatName, "Name");
LC32_CV_STRING(kCVPixelFormatOpenGLCompatibility, "OpenGLCompatibility");
LC32_CV_STRING(kCVPixelFormatOpenGLESCompatibility, "OpenGLESCompatibility");
LC32_CV_STRING(kCVPixelFormatOpenGLFormat, "OpenGLFormat");
LC32_CV_STRING(kCVPixelFormatOpenGLInternalFormat, "OpenGLInternalFormat");
LC32_CV_STRING(kCVPixelFormatOpenGLType, "OpenGLType");
LC32_CV_STRING(kCVPixelFormatPlanes, "Planes");
LC32_CV_STRING(kCVPixelFormatQDCompatibility, "QDCompatibility");
LC32_CV_STRING(kCVPixelFormatVerticalSubsampling, "VerticalSubsampling");

// Texture-cache attributes.
LC32_CV_STRING(kCVMetalTextureCacheMaximumTextureAgeKey, "MaximumMetalTextureAge");
LC32_CV_STRING(kCVOpenGLESTextureCacheMaximumTextureAgeKey, "MaximumTextureAge");

#undef LC32_CV_STRING

// Preserve the ARM32 CVTime payloads from the same image, including zero scale.
const CVTime kCVZeroTime = {0, 0, 0};
const CVTime kCVIndefiniteTime = {0, 0, 1};
