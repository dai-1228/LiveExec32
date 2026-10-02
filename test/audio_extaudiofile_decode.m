/*
 * audio_extaudiofile_decode.m — mfm (Mutant Fridge Mayhem 4.1.1) guest test.
 *
 * Exercises the CocosDenshion one-shot effect decoder contract
 * (sub_A9880 @0xa9880 in mfm.i64), the path every non-.wav effect takes
 * (all 168 .caf effects plus music_intro.mp3 / sfx_ending.mp3):
 *
 *   ExtAudioFileOpenURL(url, &ref)
 *   ExtAudioFileGetProperty(ref, 'ffmt', &sourceASBD)   — channels <= 2
 *   client ASBD built on the stack: mSampleRate copied verbatim from the
 *       source, mFormatID='lpcm', mFormatFlags=12 (IsAligned|IsPacked,
 *       verbatim from the binary), 16-bit, per-channel byte math — and
 *       mReserved left as whatever stack garbage was there, exactly like
 *       the game (the host bridge must zero it before the native
 *       converter setup, per HostFrameworks/AudioToolbox/AudioToolbox.mm)
 *   ExtAudioFileSetProperty(ref, 'cfmt', 40, &clientASBD)
 *   ExtAudioFileGetProperty(ref, '#frm', &frames64)
 *   one-shot ExtAudioFileRead of the whole file into 16-bit PCM
 *   ExtAudioFileDispose(ref)
 *
 * The .caf under test is synthesized with AudioFileCreateWithURL (the
 * same synthesis the ext_audio_file_wrap fixture uses), so the fixture is
 * self-contained: no bundled asset needed.
 */

#include <AudioToolbox/AudioToolbox.h>
#include <CoreFoundation/CoreFoundation.h>

#include <limits.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int failures;

static int check(const char *name, int condition) {
    printf("%s: %s\n", name, condition ? "PASS" : "FAIL");
    failures += !condition;
    return condition;
}

static int statusOK(const char *name, OSStatus status) {
    printf("%s: %s (%d)\n", name, status == noErr ? "PASS" : "FAIL", (int)status);
    failures += status != noErr;
    return status == noErr;
}

typedef struct {
    uint32_t before;
    ExtAudioFileRef file;
    uint32_t after;
} GuardedRef;
_Static_assert(offsetof(GuardedRef, after) ==
    offsetof(GuardedRef, file) + sizeof(ExtAudioFileRef), "open output canary");

static int canariesIntact(const GuardedRef *guard) {
    return guard->before == 0x13579bdf && guard->after == 0xfedcba98;
}

/*
 * Builds the client ASBD exactly the way sub_A9880 does: a stack struct
 * whose fields are all assigned except mReserved, which keeps the
 * scribbled stack bytes. Callers scribble first (the game relies on
 * whatever was already on the stack; any non-zero pattern exercises the
 * host-side reserved-field sanitization).
 */
static AudioStreamBasicDescription gameClientFormat(
        const AudioStreamBasicDescription *source) {
    AudioStreamBasicDescription client;
    memset(&client, 0xCC, sizeof(client));
    const UInt32 channels = source->mChannelsPerFrame;
    client.mSampleRate = source->mSampleRate;
    client.mFormatID = kAudioFormatLinearPCM;
    client.mFormatFlags = 12; /* IsAligned|IsPacked, verbatim from sub_A9880 */
    client.mBytesPerPacket = 2 * channels;
    client.mFramesPerPacket = 1;
    client.mBytesPerFrame = 2 * channels;
    client.mChannelsPerFrame = channels;
    client.mBitsPerChannel = 16;
    return client;
}

static AudioStreamBasicDescription pcmFormat(double rate, UInt32 channels,
                                             UInt32 flags) {
    AudioStreamBasicDescription format = {0};
    format.mSampleRate = rate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = flags;
    format.mBytesPerPacket = 2 * channels;
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = 2 * channels;
    format.mChannelsPerFrame = channels;
    format.mBitsPerChannel = 16;
    return format;
}

/* Writes a fresh PCM CAF holding `frameCount` frames of raw 16-bit words. */
static int createCAF(const char *path, const AudioStreamBasicDescription *format,
                     const int16_t *samples, UInt32 frameCount) {
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(
        kCFAllocatorDefault, (const UInt8 *)path, (CFIndex)strlen(path), false);
    if(!check("decode-create-url", url != NULL)) return 0;
    AudioFileID file = NULL;
    int success = 0;
    if(statusOK("decode-create-caf", AudioFileCreateWithURL(url,
            kAudioFileCAFType, format, kAudioFileFlags_EraseFile, &file)) &&
            file) {
        UInt32 bytes = frameCount * format->mBytesPerFrame;
        success = statusOK("decode-write-caf", AudioFileWriteBytes(
            file, false, 0, &bytes, samples));
        check("decode-written-byte-count", bytes == frameCount * format->mBytesPerFrame);
        statusOK("decode-close-caf", AudioFileClose(file));
    }
    CFRelease(url);
    return success;
}

/*
 * expectPassthrough: the source file is already in the game's client
 * format, so the decoded words must match the source words exactly.
 * Otherwise the client interprets the stream as unsigned 16-bit while the
 * source declares signed: every decoded word must be either the signed
 * word reinterpreted or its biased image (host converters may pass the
 * raw frames through or apply the sign remap).
 */
static void decodeScenario(const char *path, UInt32 channels, double rate,
                           const int16_t *samples,
                           UInt32 frameCount, int expectPassthrough,
                           const char *label) {
    GuardedRef guard = {0x13579bdf, NULL, 0xfedcba98};
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(
        kCFAllocatorDefault, (const UInt8 *)path, (CFIndex)strlen(path), false);
    if(!check("decode-open-url-alloc", url != NULL)) return;
    const int opened = statusOK("decode-open-url",
        ExtAudioFileOpenURL(url, &guard.file));
    CFRelease(url);
    if(!opened) return;
    check("decode-open-canaries", canariesIntact(&guard));
    if(!check("decode-open-token-nonnull", guard.file != NULL)) return;

    AudioStreamBasicDescription source = {0};
    UInt32 size = sizeof(source);
    if(!statusOK("decode-get-file-format", ExtAudioFileGetProperty(guard.file,
            kExtAudioFileProperty_FileDataFormat, &size, &source))) goto dispose;
    check("decode-file-format-size", size == sizeof(source));
    check("decode-file-format-channels", source.mChannelsPerFrame == channels);
    check("decode-file-channels-in-range", source.mChannelsPerFrame <= 2);
    check("decode-file-format-rate", source.mSampleRate == rate);

    /* Game contract: full ASBD size, mReserved left as stack garbage. */
    AudioStreamBasicDescription client = gameClientFormat(&source);
    check("decode-client-reserved-garbage", client.mReserved != 0);
    if(!statusOK("decode-set-client-format", ExtAudioFileSetProperty(guard.file,
            kExtAudioFileProperty_ClientDataFormat, sizeof(client), &client)))
        goto dispose;

    AudioStreamBasicDescription stored = {0};
    size = sizeof(stored);
    if(!statusOK("decode-get-client-format", ExtAudioFileGetProperty(guard.file,
            kExtAudioFileProperty_ClientDataFormat, &size, &stored))) goto dispose;
    check("decode-client-format-value", size == sizeof(stored) &&
        stored.mFormatID == kAudioFormatLinearPCM &&
        stored.mChannelsPerFrame == channels &&
        stored.mBitsPerChannel == 16 &&
        stored.mBytesPerFrame == 2 * channels &&
        stored.mFramesPerPacket == 1);

    SInt64 lengthFrames = 0;
    size = sizeof(lengthFrames);
    if(!statusOK("decode-get-length-frames", ExtAudioFileGetProperty(guard.file,
            kExtAudioFileProperty_FileLengthFrames, &size, &lengthFrames)))
        goto dispose;
    check("decode-length-size", size == sizeof(lengthFrames));
    check("decode-length-value", lengthFrames == (SInt64)frameCount);

    const UInt32 wordsPerFrame = 2 * channels;
    const size_t byteCount = (size_t)frameCount * wordsPerFrame * sizeof(int16_t);
    uint16_t *decoded = malloc(byteCount ? byteCount : 1);
    if(!check("decode-alloc-buffer", decoded != NULL)) goto dispose;
    memset(decoded, 0, byteCount);
    AudioBufferList buffers = {1, {{channels, (UInt32)byteCount, decoded}}};
    UInt32 frames = (UInt32)lengthFrames;
    if(statusOK("decode-read-frames", ExtAudioFileRead(guard.file, &frames, &buffers))) {
        check("decode-read-frame-count", frames == frameCount);
        check("decode-read-byte-count",
            buffers.mBuffers[0].mDataByteSize == byteCount);
        check("decode-read-channel-count",
            buffers.mBuffers[0].mNumberChannels == channels);
        /* PCM sanity: the decoder must have produced non-zero energy. */
        unsigned nonzero = 0, matched = 0, biased = 0;
        const uint16_t *words = (const uint16_t *)samples;
        for(UInt32 index = 0; index < frames * wordsPerFrame; ++index) {
            if(decoded[index] != 0) ++nonzero;
            if(decoded[index] == words[index]) ++matched;
            if(decoded[index] == (uint16_t)(words[index] ^ 0x8000)) ++biased;
        }
        check("decode-pcm-nonzero", nonzero > 0);
        if(expectPassthrough) {
            check("decode-pcm-exact", matched == frames * wordsPerFrame);
        } else {
            /* Every word is either the raw frame or its signed->unsigned
             * remap; together they must cover the whole buffer. */
            check("decode-pcm-converted",
                matched + biased >= frames * wordsPerFrame);
        }
        check(label, frames != 0 && buffers.mBuffers[0].mDataByteSize != 0);
    }
    free(decoded);

dispose:
    statusOK("decode-dispose", ExtAudioFileDispose(guard.file));
    /* A stale token must be rejected rather than touching freed state. */
    check("decode-disposed-token-rejected",
        ExtAudioFileDispose(guard.file) != noErr);
}

int main(int argc, char **argv) {
    const char *scratch = argc > 1 ? argv[1] : getenv("TMPDIR");
    if(!scratch || !scratch[0]) scratch = "/private/tmp";
    char path[PATH_MAX];
    const int pathLength = snprintf(path, sizeof(path),
        "%s/lc32-ext-audio-decode.XXXXXX", scratch);
    if(!check("decode-temporary-path", pathLength > 0 &&
            (size_t)pathLength < sizeof(path))) return 1;
    int fd = mkstemp(path);
    if(!check("decode-create-temporary-file", fd >= 0)) { perror(path); return 1; }
    close(fd);

    /* Stereo .caf already in the game's client format (flags 12): the
     * decode must be an exact frame-for-frame passthrough. */
    static const int16_t stereo[] = {
        -32768, 1234, 0, -1234, 22222, -22222, 32767, 1, -1, 32767, -32767, 2
    };
    const AudioStreamBasicDescription stereoFormat =
        pcmFormat(44100.0, 2, 12);
    if(createCAF(path, &stereoFormat, stereo, 6)) {
        decodeScenario(path, 2, 44100.0, stereo, 6, 1,
            "decode-stereo-scenario");
    }

    /* Mono .caf authored as signed 16-bit (the usual on-disk flavor of
     * the game's .caf assets) decoded into the game's flags-12 client:
     * exercises a real converter setup, not just a passthrough. */
    static const int16_t mono[] = {-32768, -1, 0, 1, 12345, 32767};
    const AudioStreamBasicDescription monoFormat =
        pcmFormat(22050.0, 1, kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked);
    if(createCAF(path, &monoFormat, mono, 6)) {
        decodeScenario(path, 1, 22050.0, mono, 6, 0, "decode-mono-scenario");
    }

    check("decode-remove-temporary-file", unlink(path) == 0);
    printf("audio-extaudiofile-decode: %s\n", failures ? "FAIL" : "PASS");
    return failures != 0;
}
