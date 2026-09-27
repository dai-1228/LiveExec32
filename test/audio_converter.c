#include <AudioToolbox/AudioToolbox.h>

#include <stdint.h>
#include <stdio.h>
#include <string.h>

enum {
    kInputFrameCount = 12,
    kMaximumFramesPerCallback = 3,
};

typedef struct {
    AudioConverterRef converter;
    const SInt16 *samples;
    UInt32 sampleCount;
    UInt32 nextSample;
    UInt32 callbackCount;
    int callbackValid;
} ConverterInputState;

typedef struct {
    AudioConverterRef converter;
    SInt16 samples[2];
    UInt32 callbackCount;
    UInt32 requestedPackets;
    int callbackValid;
} RetainedConverterInputState;

static ConverterInputState *expectedInputState;
static RetainedConverterInputState *expectedRetainedInputState;

static OSStatus converter_input_callback(
        AudioConverterRef converter,
        UInt32 *ioNumberDataPackets,
        AudioBufferList *ioData,
        AudioStreamPacketDescription **outDataPacketDescription,
        void *userData) {
    ConverterInputState *state = expectedInputState;
    if(!state || userData != state || converter != state->converter ||
       !ioNumberDataPackets || !ioData) {
        if(state) state->callbackValid = 0;
        return kAudio_ParamError;
    }

    ++state->callbackCount;
    if(outDataPacketDescription) *outDataPacketDescription = NULL;

    UInt32 packetCount = *ioNumberDataPackets;
    const UInt32 remaining = state->sampleCount - state->nextSample;
    if(packetCount > remaining) packetCount = remaining;
    if(packetCount > kMaximumFramesPerCallback)
        packetCount = kMaximumFramesPerCallback;

    /* Deliberately replace the converter-provided pointer. This mirrors old
     * clients such as PvZ, whose callbacks reference guest-owned PCM rather
     * than filling storage supplied by AudioConverter. */
    ioData->mNumberBuffers = 1;
    ioData->mBuffers[0].mNumberChannels = 1;
    ioData->mBuffers[0].mDataByteSize =
        packetCount * (UInt32)sizeof(SInt16);
    ioData->mBuffers[0].mData = packetCount
        ? (void *)(state->samples + state->nextSample) : NULL;
    *ioNumberDataPackets = packetCount;
    state->nextSample += packetCount;
    return noErr;
}

static OSStatus retained_converter_input_callback(
        AudioConverterRef converter,
        UInt32 *ioNumberDataPackets,
        AudioBufferList *ioData,
        AudioStreamPacketDescription **outDataPacketDescription,
        void *userData) {
    RetainedConverterInputState *state = expectedRetainedInputState;
    if(!state || userData != state || converter != state->converter ||
       !ioNumberDataPackets || !ioData || ioData->mNumberBuffers != 1) {
        if(state) state->callbackValid = 0;
        return kAudio_ParamError;
    }

    ++state->callbackCount;
    if(outDataPacketDescription) *outDataPacketDescription = NULL;
    if(state->callbackCount != 1) {
        *ioNumberDataPackets = 0;
        return noErr;
    }

    state->requestedPackets = *ioNumberDataPackets;
    ioData->mBuffers[0].mNumberChannels = 1;
    ioData->mBuffers[0].mDataByteSize = sizeof(state->samples);
    ioData->mBuffers[0].mData = state->samples;
    /* The input count is a minimum, not a capacity. Returning more lets the
     * converter retain the second packet for the following Fill call. */
    *ioNumberDataPackets = 2;
    return noErr;
}

static AudioStreamBasicDescription pcm_format(void) {
    AudioStreamBasicDescription format = {0};
    format.mSampleRate = 44100.0;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsSignedInteger |
        kAudioFormatFlagIsPacked;
    format.mBytesPerPacket = sizeof(SInt16);
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = sizeof(SInt16);
    format.mChannelsPerFrame = 1;
    format.mBitsPerChannel = 16;
    return format;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    int passed = 1;
    const AudioStreamBasicDescription format = pcm_format();

    /* Call through an unannotated type so the deliberate invalid-argument
     * regression does not itself produce a compile-time nonnull warning. */
    OSStatus (*newConverter)(const AudioStreamBasicDescription *,
        const AudioStreamBasicDescription *, AudioConverterRef *) =
        AudioConverterNew;

    AudioConverterRef invalidConverter =
        (AudioConverterRef)(uintptr_t)0x12345678;
    const OSStatus invalidStatus = newConverter(
        NULL, &format, &invalidConverter);
    const int invalidNewPassed = invalidStatus != noErr &&
        invalidConverter == NULL;
    passed &= invalidNewPassed;
    printf("audio-converter-invalid-new-clears-result: %s (%d)\n",
        invalidNewPassed ? "PASS" : "FAIL", (int)invalidStatus);

    AudioConverterRef converter = NULL;
    const OSStatus newStatus = newConverter(
        &format, &format, &converter);
    const int newPassed = newStatus == noErr && converter != NULL;
    passed &= newPassed;
    printf("audio-converter-new: %s (%d)\n",
        newPassed ? "PASS" : "FAIL", (int)newStatus);
    if(!newPassed) return 1;

    static const SInt16 input[kInputFrameCount] = {
        0, 1, -1, 1234, -2345, 8192,
        -8192, 16384, -16384, 32767, -32768, 42,
    };
    SInt16 output[kInputFrameCount] = {0};
    ConverterInputState state = {
        .converter = converter,
        .samples = input,
        .sampleCount = kInputFrameCount,
        .callbackValid = 1,
    };
    expectedInputState = &state;

    UInt32 outputFrameCount = kInputFrameCount;
    AudioBufferList outputData = {
        .mNumberBuffers = 1,
        .mBuffers = {{
            .mNumberChannels = 1,
            .mDataByteSize = sizeof(output),
            .mData = output,
        }},
    };
    const OSStatus fillStatus = AudioConverterFillComplexBuffer(
        converter, converter_input_callback, &state,
        &outputFrameCount, &outputData, NULL);
    expectedInputState = NULL;

    const int fillPassed = fillStatus == noErr &&
        state.callbackValid && state.callbackCount >= 2 &&
        state.nextSample == kInputFrameCount &&
        outputFrameCount == kInputFrameCount &&
        outputData.mNumberBuffers == 1 &&
        outputData.mBuffers[0].mNumberChannels == 1 &&
        outputData.mBuffers[0].mDataByteSize == sizeof(output) &&
        outputData.mBuffers[0].mData == output &&
        memcmp(input, output, sizeof(output)) == 0;
    passed &= fillPassed;
    printf("audio-converter-fill-guest-buffer-callback: %s "
           "(status=%d callbacks=%u input=%u output=%u bytes=%u)\n",
        fillPassed ? "PASS" : "FAIL", (int)fillStatus,
        (unsigned int)state.callbackCount,
        (unsigned int)state.nextSample,
        (unsigned int)outputFrameCount,
        (unsigned int)outputData.mBuffers[0].mDataByteSize);

    AudioConverterRef retainedConverter = NULL;
    const OSStatus retainedNewStatus = newConverter(
        &format, &format, &retainedConverter);
    RetainedConverterInputState retainedState = {
        .converter = retainedConverter,
        .samples = {123, -456},
        .callbackValid = 1,
    };
    SInt16 retainedOutput[2] = {0};
    OSStatus retainedFirstStatus = kAudio_ParamError;
    OSStatus retainedSecondStatus = kAudio_ParamError;
    if(retainedNewStatus == noErr && retainedConverter) {
        expectedRetainedInputState = &retainedState;
        for(UInt32 index = 0; index < 2; ++index) {
            UInt32 frameCount = 1;
            AudioBufferList outputList = {
                .mNumberBuffers = 1,
                .mBuffers = {{
                    .mNumberChannels = 1,
                    .mDataByteSize = sizeof(retainedOutput[index]),
                    .mData = &retainedOutput[index],
                }},
            };
            OSStatus status = AudioConverterFillComplexBuffer(
                retainedConverter, retained_converter_input_callback,
                &retainedState, &frameCount, &outputList, NULL);
            if(index == 0) retainedFirstStatus = status;
            else retainedSecondStatus = status;
            if(status != noErr || frameCount != 1 ||
               outputList.mBuffers[0].mDataByteSize != sizeof(SInt16)) {
                retainedState.callbackValid = 0;
            }
        }
        expectedRetainedInputState = NULL;
    }
    const int retainedPassed = retainedNewStatus == noErr &&
        retainedState.callbackValid && retainedState.requestedPackets == 1 &&
        retainedState.callbackCount == 1 &&
        retainedFirstStatus == noErr && retainedSecondStatus == noErr &&
        memcmp(retainedState.samples, retainedOutput,
            sizeof(retainedOutput)) == 0;
    passed &= retainedPassed;
    printf("audio-converter-retains-extra-input: %s "
           "(new=%d first=%d second=%d requested=%u callbacks=%u)\n",
        retainedPassed ? "PASS" : "FAIL", (int)retainedNewStatus,
        (int)retainedFirstStatus, (int)retainedSecondStatus,
        (unsigned int)retainedState.requestedPackets,
        (unsigned int)retainedState.callbackCount);
    if(retainedConverter) {
        const OSStatus retainedDisposeStatus =
            AudioConverterDispose(retainedConverter);
        passed &= retainedDisposeStatus == noErr;
    }

    const OSStatus disposeStatus = AudioConverterDispose(converter);
    const int disposePassed = disposeStatus == noErr;
    passed &= disposePassed;
    printf("audio-converter-dispose: %s (%d)\n",
        disposePassed ? "PASS" : "FAIL", (int)disposeStatus);
    return !passed;
}
