/*
 * LC32GuestSysctlValues.m
 *
 * Data definitions ONLY — no runtime hook, no interpose, no behavior
 * visible to mfm until the host NEEDS-OWNER ticket (see
 * /tmp/mfm100/gaps/spec-crittercism.md sections 1.1/1.2) consumes them.
 * The two-level namespace routes the app's libSystem.B bind entries to
 * the ramdisk libSystem; an LC32 export cannot shadow them (M1).
 */
#import "LC32GuestSysctlValues.h"

/*
 * Canonical sysctlbyname answers for the names mfm's launch-time SDKs
 * probe.  Table order is irrelevant; termination is a NULL name.
 */
const struct LC32GuestSysctlAnswer LC32GuestSysctlAnswers[] = {
    { "hw.machine", LC32GuestSysctlKindStr,
        { .str = LC32_GUEST_HW_MACHINE } },
    { "hw.cputype", LC32GuestSysctlKindU32,
        { .u32 = (uint32_t)LC32_GUEST_CPU_TYPE } },
    { "hw.cpusubtype", LC32GuestSysctlKindU32,
        { .u32 = (uint32_t)LC32_GUEST_CPU_SUBTYPE } },
    { "hw.physicalcpu_max", LC32GuestSysctlKindU32,
        { .u32 = LC32_GUEST_PHYSICAL_CPU_MAX } },
    { "hw.logicalcpu_max", LC32GuestSysctlKindU32,
        { .u32 = LC32_GUEST_LOGICAL_CPU_MAX } },
    { "hw.memsize", LC32GuestSysctlKindU64,
        { .u64 = LC32_GUEST_HW_MEMSIZE } },
    { "kern.ostype", LC32GuestSysctlKindStr,
        { .str = LC32_GUEST_KERN_OSTYPE } },
    { "kern.osrelease", LC32GuestSysctlKindStr,
        { .str = LC32_GUEST_KERN_OSRELEASE } },
    { "kern.osversion", LC32GuestSysctlKindStr,
        { .str = LC32_GUEST_KERN_OSVERSION } },
    /* sysctl.proc_native: 0 — the 32-bit guest process is not native. */
    { "sysctl.proc_native", LC32GuestSysctlKindU32,
        { .u32 = LC32_GUEST_PROC_NATIVE } },
    { NULL, (LC32GuestSysctlKind)0, { .u32 = 0 } }
};

/* Canonical utsname answers; machine shares LC32_GUEST_HW_MACHINE. */
const LC32GuestUTSName LC32GuestUTSNameValues = {
    LC32_GUEST_UTS_SYSNAME,
    LC32_GUEST_UTS_NODENAME,
    LC32_GUEST_UTS_RELEASE,
    LC32_GUEST_UTS_VERSION,
    LC32_GUEST_HW_MACHINE
};

/* Compile-time guarantees the host ticket can rely on. */
#include <sys/utsname.h>
_Static_assert(CPU_TYPE_ARM == 12,
    "guest CPU_TYPE_ARM must be 12 per the armv7 ABI");
_Static_assert(CPU_SUBTYPE_ARM_V7S == 11,
    "guest CPU_SUBTYPE_ARM_V7S must be 11 per the armv7 ABI");
_Static_assert(sizeof(struct utsname) == 5 * 256,
    "guest struct utsname must be five 256-byte fields (1280 bytes)");
