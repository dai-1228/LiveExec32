#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation+LC32.h>

/*
 * The generated AVFoundation shim only emits Objective-C classes.  Legacy
 * binaries also bind these framework-owned NSString constants eagerly, so
 * provide their iOS 6-compatible values in the guest image.
 */
NSString *const AVLayerVideoGravityResizeAspect =
    @"AVLayerVideoGravityResizeAspect";
NSString *const AVMediaCharacteristicLegible =
    LC32_CONST_STR_ID((&(LC32ConstantStringProxy){
        __CFConstantStringClassReference, 0x7c8, NULL, 0
    }));
NSString *const AVPlayerItemDidPlayToEndTimeNotification =
    @"AVPlayerItemDidPlayToEndTimeNotification";
NSString *const AVAudioSessionInterruptionNotification =
    @"AVAudioSessionInterruptionNotification";
NSString *const AVAudioSessionInterruptionOptionKey =
    LC32_CONST_STR_ID((&(LC32ConstantStringProxy){
        __CFConstantStringClassReference, 0x7c8, NULL, 0
    }));
NSString *const AVAudioSessionInterruptionTypeKey =
    LC32_CONST_STR_ID((&(LC32ConstantStringProxy){
        __CFConstantStringClassReference, 0x7c8, NULL, 0
    }));
NSString *const AVEncoderAudioQualityKey =
    @"AVEncoderQualityKey";
NSString *const AVFormatIDKey =
    @"AVFormatIDKey";
NSString *const AVLinearPCMBitDepthKey =
    @"AVLinearPCMBitDepthKey";
NSString *const AVLinearPCMIsBigEndianKey =
    @"AVLinearPCMIsBigEndianKey";
NSString *const AVLinearPCMIsFloatKey =
    @"AVLinearPCMIsFloatKey";
NSString *const AVNumberOfChannelsKey =
    @"AVNumberOfChannelsKey";
NSString *const AVSampleRateKey =
    @"AVSampleRateKey";

CGRect AVMakeRectWithAspectRatioInsideRect(
        CGSize aspectRatio, CGRect boundingRect) {
    const CGFloat scale = MIN(
        boundingRect.size.width / aspectRatio.width,
        boundingRect.size.height / aspectRatio.height);
    const CGSize size = CGSizeMake(
        aspectRatio.width * scale, aspectRatio.height * scale);
    return CGRectMake(
        CGRectGetMidX(boundingRect) - size.width / 2,
        CGRectGetMidY(boundingRect) - size.height / 2,
        size.width, size.height);
}

/*
 * The native runtime matches media characteristics and interruption user
 * info keys against exact string values that are not necessarily the
 * exported symbol spellings (the audio-quality key above shows the same
 * divergence).  Bind those constants to the native framework's own objects
 * at load time, like the media characteristics in the companion constants
 * unit; the binding helper falls back to the symbol spelling when a native
 * constant is unavailable.  The native-framework load also keeps the
 * generated class shims forwardable for every application that links this
 * guest framework.
 */
__attribute__((constructor))
static void LC32BindAVFoundationNativeConstants(void) {
    LC32LoadHostFramework("AVFoundation");
    LC32BindHostObjectConstant(
        (id)AVMediaCharacteristicLegible,
        "AVMediaCharacteristicLegible");
    LC32BindHostObjectConstant(
        (id)AVAudioSessionInterruptionOptionKey,
        "AVAudioSessionInterruptionOptionKey");
    LC32BindHostObjectConstant(
        (id)AVAudioSessionInterruptionTypeKey,
        "AVAudioSessionInterruptionTypeKey");
}
