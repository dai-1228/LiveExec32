#import <CoreMedia/CMTime.h>

/*
 * CMTime crosses the bridge without any field widening: every field is
 * fixed-width, so the guest ARM32 and host ARM64 layouts are identical and
 * the aggregate transport copies the value verbatim.  The runtime type
 * encoding is anonymous ({?=qiIq}), so the shim generator maps that exact
 * encoding to this known struct; the guest CMTime type itself comes from
 * the CoreMedia headers the guest builds already use, exactly like the
 * CoreGraphics families below it on the search path.
 */

typedef struct {
    int64_t value;
    int32_t timescale;
    uint32_t flags;
    int64_t epoch;
} CMTime_64;

static inline CMTime_64 LC32HostCMTime(CMTime guest) {
    CMTime_64 result = {guest.value, guest.timescale, guest.flags, guest.epoch};
    return result;
}

static inline CMTime LC32GuestCMTime(CMTime_64 host) {
    CMTime result = {host.value, host.timescale, host.flags, host.epoch};
    return result;
}
