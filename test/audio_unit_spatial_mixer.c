#include <AudioToolbox/AudioToolbox.h>

#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

typedef struct {
    AudioUnit mixer;
    UInt32 bus;
    _Atomic(uint32_t) callbackCount;
    _Atomic(uint32_t) callbackValid;
    _Atomic(uint32_t) postCount;
    _Atomic(uint32_t) notifyValid;
    _Atomic(uint32_t) scaledOutputValid;
    _Atomic(uint32_t) disconnectRequested;
    _Atomic(uint32_t) disconnectAttempted;
    _Atomic(int32_t) disconnectStatus;
} MixerState;

static OSStatus mixer_input_callback(
        void *refCon, AudioUnitRenderActionFlags *actionFlags,
        const AudioTimeStamp *timeStamp, UInt32 bus, UInt32 frameCount,
        AudioBufferList *buffers) {
    MixerState *state = refCon;
    const UInt32 requiredBytes = frameCount * sizeof(Float32);
    if(!state || !actionFlags || !timeStamp || bus != state->bus ||
       !frameCount || frameCount > 4096 || !buffers ||
       buffers->mNumberBuffers != 1 ||
       buffers->mBuffers[0].mNumberChannels != 1 ||
       buffers->mBuffers[0].mDataByteSize != requiredBytes ||
       !buffers->mBuffers[0].mData) {
        if(state) atomic_store_explicit(
            &state->callbackValid, 0, memory_order_release);
        return kAudio_ParamError;
    }
    Float32 *samples = buffers->mBuffers[0].mData;
    for(UInt32 frame = 0; frame < frameCount; ++frame)
        samples[frame] = 0.5f;
    const uint32_t callbackCount = atomic_load_explicit(
        &state->callbackCount, memory_order_relaxed);
    atomic_store_explicit(
        &state->callbackCount, callbackCount + 1, memory_order_release);
    return noErr;
}

static OSStatus render_notify_callback(
        void *refCon, AudioUnitRenderActionFlags *actionFlags,
        const AudioTimeStamp *timeStamp, UInt32 bus, UInt32 frameCount,
        AudioBufferList *buffers) {
    MixerState *state = refCon;
    if(!state || !actionFlags || !timeStamp || bus != 0 ||
       !frameCount || frameCount > 4096 || !buffers ||
       buffers->mNumberBuffers != 2 ||
       buffers->mBuffers[0].mNumberChannels != 1 ||
       buffers->mBuffers[1].mNumberChannels != 1 ||
       !buffers->mBuffers[0].mData || !buffers->mBuffers[1].mData) {
        if(state) atomic_store_explicit(
            &state->notifyValid, 0, memory_order_release);
        return kAudio_ParamError;
    }
    if((*actionFlags & kAudioUnitRenderAction_PostRender) == 0)
        return noErr;
    const uint32_t postCount = atomic_load_explicit(
        &state->postCount, memory_order_relaxed);
    atomic_store_explicit(
        &state->postCount, postCount + 1, memory_order_release);
    if((*actionFlags & (kAudioUnitRenderAction_OutputIsSilence |
            kAudioUnitRenderAction_PostRenderError)) == 0) {
        const Float32 left =
            ((const Float32 *)buffers->mBuffers[0].mData)[0];
        const Float32 right =
            ((const Float32 *)buffers->mBuffers[1].mData)[0];
        if(left < 0.124f || left > 0.126f ||
           right < 0.124f || right > 0.126f) {
            atomic_store_explicit(
                &state->scaledOutputValid, 0, memory_order_release);
        }
    }
    if(atomic_load_explicit(
            &state->disconnectRequested, memory_order_acquire) &&
       !atomic_load_explicit(
            &state->disconnectAttempted, memory_order_relaxed)) {
        atomic_store_explicit(
            &state->disconnectAttempted, 1, memory_order_release);
        const AURenderCallbackStruct disconnected = {0};
        const OSStatus status = AudioUnitSetProperty(state->mixer,
            kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input,
            state->bus, &disconnected, sizeof(disconnected));
        atomic_store_explicit(
            &state->disconnectStatus, status, memory_order_release);
    }
    return noErr;
}

static int format_is(const AudioStreamBasicDescription *format,
                     UInt32 channels) {
    return format->mSampleRate == 44100.0 &&
        format->mFormatID == kAudioFormatLinearPCM &&
        format->mFormatFlags == (kAudioFormatFlagIsFloat |
            kAudioFormatFlagIsPacked |
            kAudioFormatFlagIsNonInterleaved) &&
        format->mBytesPerPacket == sizeof(Float32) &&
        format->mFramesPerPacket == 1 &&
        format->mBytesPerFrame == sizeof(Float32) &&
        format->mChannelsPerFrame == channels &&
        format->mBitsPerChannel == 8 * sizeof(Float32) &&
        format->mReserved == 0;
}

static int report(const char *name, int passed) {
    printf("%s: %s\n", name, passed ? "PASS" : "FAIL");
    return passed;
}

static AudioComponent find_component(OSType type, OSType subtype) {
    AudioComponentDescription description = {
        .componentType = type,
        .componentSubType = subtype,
        .componentManufacturer = kAudioUnitManufacturer_Apple,
    };
    return AudioComponentFindNext(NULL, &description);
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    int passed = 1;

    AudioComponent remoteComponent = find_component(
        kAudioUnitType_Output, kAudioUnitSubType_RemoteIO);
    AudioComponent mixerComponent = find_component(
        kAudioUnitType_Mixer, kAudioUnitSubType_SpatialMixer);
    passed &= report("audio-unit-mixer-find-components",
        remoteComponent && mixerComponent &&
        remoteComponent != mixerComponent);
    if(!remoteComponent || !mixerComponent) return 1;

    AudioUnit remote = NULL;
    AudioUnit mixer = NULL;
    passed &= report("audio-unit-mixer-new-remote",
        AudioComponentInstanceNew(remoteComponent, &remote) == noErr &&
        remote);
    passed &= report("audio-unit-mixer-new-mixer",
        AudioComponentInstanceNew(mixerComponent, &mixer) == noErr &&
        mixer);
    if(!remote || !mixer) return 1;

    UInt32 busCount = 0;
    UInt32 size = sizeof(busCount);
    passed &= report("audio-unit-mixer-default-bus-count",
        AudioUnitGetProperty(mixer, kAudioUnitProperty_ElementCount,
            kAudioUnitScope_Input, 0, &busCount, &size) == noErr &&
        size == sizeof(busCount) && busCount == 32);

    AudioStreamBasicDescription inputFormat = {0};
    size = sizeof(inputFormat);
    passed &= report("audio-unit-mixer-input-format",
        AudioUnitGetProperty(mixer, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input, 31, &inputFormat, &size) == noErr &&
        size == sizeof(inputFormat) && format_is(&inputFormat, 1));
    AudioStreamBasicDescription outputFormat = {0};
    size = sizeof(outputFormat);
    passed &= report("audio-unit-mixer-output-format",
        AudioUnitGetProperty(mixer, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output, 0, &outputFormat, &size) == noErr &&
        size == sizeof(outputFormat) && format_is(&outputFormat, 2));

    AudioUnitConnection connection = {
        .sourceAudioUnit = mixer,
        .sourceOutputNumber = 0,
        .destInputNumber = 0,
    };
    passed &= report("audio-unit-mixer-connect",
        AudioUnitSetProperty(remote, kAudioUnitProperty_MakeConnection,
            kAudioUnitScope_Input, 0, &connection,
            sizeof(connection)) == noErr);

    AudioStreamBasicDescription connectedFormat = {0};
    size = sizeof(connectedFormat);
    passed &= report("audio-unit-mixer-connected-format",
        AudioUnitGetProperty(remote, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input, 0, &connectedFormat, &size) == noErr &&
        memcmp(&connectedFormat, &outputFormat,
            sizeof(connectedFormat)) == 0);

    MixerState state = {
        .mixer = mixer,
        .bus = 7,
        .callbackValid = 1,
        .notifyValid = 1,
        .scaledOutputValid = 1,
    };
    passed &= report("audio-unit-mixer-add-render-notify",
        AudioUnitAddRenderNotify(remote, render_notify_callback,
            &state) == noErr);
    passed &= report("audio-unit-mixer-initialize-remote-first",
        AudioUnitInitialize(remote) == noErr);
    passed &= report("audio-unit-mixer-initialize-mixer-second",
        AudioUnitInitialize(mixer) == noErr);

    AURenderCallbackStruct callback = {
        .inputProc = mixer_input_callback,
        .inputProcRefCon = &state,
    };
    passed &= report("audio-unit-mixer-set-callback-after-init",
        AudioUnitSetProperty(mixer,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input, state.bus, &callback,
            sizeof(callback)) == noErr);

    passed &= report("audio-unit-mixer-set-parameters",
        AudioUnitSetParameter(mixer, k3DMixerParam_Gain,
            kAudioUnitScope_Input, state.bus, -6.0205999f, 0) == noErr &&
        AudioUnitSetParameter(mixer, k3DMixerParam_Azimuth,
            kAudioUnitScope_Input, state.bus, 90.0f, 0) == noErr &&
        AudioUnitSetParameter(mixer, k3DMixerParam_PlaybackRate,
            kAudioUnitScope_Input, state.bus, 1.1f, 0) == noErr);
    AudioUnitParameterValue parameter = 0;
    passed &= report("audio-unit-mixer-get-parameter",
        AudioUnitGetParameter(mixer, k3DMixerParam_Gain,
            kAudioUnitScope_Input, state.bus, &parameter) == noErr &&
        parameter == -6.0205999f);
    passed &= report("audio-unit-output-volume-round-trip",
        AudioUnitSetParameter(remote, kHALOutputParam_Volume,
            kAudioUnitScope_Global, 0, 0.5f, 0) == noErr &&
        AudioUnitGetParameter(remote, kHALOutputParam_Volume,
            kAudioUnitScope_Global, 0, &parameter) == noErr &&
        parameter == 0.5f);

    UInt32 running = 1;
    size = sizeof(running);
    passed &= report("audio-unit-output-not-running-before-start",
        AudioUnitGetProperty(remote,
            kAudioOutputUnitProperty_IsRunning,
            kAudioUnitScope_Global, 0, &running, &size) == noErr &&
        running == 0);
    passed &= report("audio-unit-mixer-start",
        AudioOutputUnitStart(remote) == noErr);
    size = sizeof(running);
    passed &= report("audio-unit-output-running-after-start",
        AudioUnitGetProperty(remote,
            kAudioOutputUnitProperty_IsRunning,
            kAudioUnitScope_Global, 0, &running, &size) == noErr &&
        running == 1);

    for(unsigned attempt = 0; attempt < 100 &&
            atomic_load_explicit(
                &state.callbackCount, memory_order_acquire) < 3; ++attempt) {
        usleep(10000);
    }
    passed &= report("audio-unit-mixer-gain-and-master-volume",
        atomic_load_explicit(
            &state.scaledOutputValid, memory_order_acquire));

    passed &= report("audio-unit-mixer-disable-bus",
        AudioUnitSetParameter(mixer, k3DMixerParam_Enable,
            kAudioUnitScope_Input, state.bus, 0.0f, 0) == noErr);
    usleep(50000);
    const uint32_t disabledCount = atomic_load_explicit(
        &state.callbackCount, memory_order_acquire);
    usleep(100000);
    passed &= report("audio-unit-mixer-disabled-bus-quiescent",
        atomic_load_explicit(
            &state.callbackCount, memory_order_acquire) == disabledCount);
    passed &= report("audio-unit-mixer-reenable-bus",
        AudioUnitSetParameter(mixer, k3DMixerParam_Enable,
            kAudioUnitScope_Input, state.bus, 1.0f, 0) == noErr);
    for(unsigned attempt = 0; attempt < 100 &&
            atomic_load_explicit(
                &state.callbackCount, memory_order_acquire) ==
                    disabledCount; ++attempt) {
        usleep(10000);
    }
    atomic_store_explicit(
        &state.disconnectRequested, 1, memory_order_release);
    for(unsigned attempt = 0; attempt < 100 &&
            !atomic_load_explicit(
                &state.disconnectAttempted, memory_order_acquire);
            ++attempt) {
        usleep(10000);
    }
    const uint32_t disconnectedCount = atomic_load_explicit(
        &state.callbackCount, memory_order_acquire);
    usleep(100000);
    passed &= report("audio-unit-mixer-rendered",
        atomic_load_explicit(&state.callbackValid, memory_order_acquire) &&
        atomic_load_explicit(&state.notifyValid, memory_order_acquire) &&
        disconnectedCount > disabledCount &&
        atomic_load_explicit(&state.postCount, memory_order_acquire) >= 3);
    passed &= report("audio-unit-mixer-disconnect-from-notify",
        atomic_load_explicit(
            &state.disconnectAttempted, memory_order_acquire) &&
        atomic_load_explicit(
            &state.disconnectStatus, memory_order_acquire) == noErr &&
        atomic_load_explicit(
            &state.callbackCount, memory_order_acquire) ==
                disconnectedCount);

    passed &= report("audio-unit-mixer-dispose-connected-mixer-active",
        AudioComponentInstanceDispose(mixer) == noErr);
    mixer = NULL;
    usleep(50000);

    passed &= report("audio-unit-mixer-stop",
        AudioOutputUnitStop(remote) == noErr);
    size = sizeof(running);
    passed &= report("audio-unit-output-not-running-after-stop",
        AudioUnitGetProperty(remote,
            kAudioOutputUnitProperty_IsRunning,
            kAudioUnitScope_Global, 0, &running, &size) == noErr &&
        running == 0);

    passed &= report("audio-unit-mixer-uninitialize-remote",
        AudioUnitUninitialize(remote) == noErr);
    passed &= report("audio-unit-mixer-dispose-remote",
        AudioComponentInstanceDispose(remote) == noErr);
    return !passed;
}
