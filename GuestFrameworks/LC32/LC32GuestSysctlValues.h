/*
 * LC32GuestSysctlValues.h
 *
 * Canonical guest-answer values for the sysctl(3)/sysctlbyname(3) names and
 * the uname(2) fields that Mutant Fridge Mayhem's launch-time SDK probes
 * (Crittercism / embedded PLCrashReporter, comScore) read.
 *
 * STATUS: data only. Nothing in this file hooks, interposes, or otherwise
 * changes runtime behavior. The app binds `_sysctlbyname` and `_uname`
 * against the ramdisk /usr/lib/libSystem.B.dylib via the two-level
 * namespace, so a plain LC32.framework export cannot intercept those
 * calls; the fix is a HostFrameworks/LC32 NEEDS-OWNER ticket whose
 * implementation must copy its answers from this file so sysctl, utsname,
 * and any future device-identity surface report one consistent fictional
 * device. See /tmp/mfm100/gaps/spec-crittercism.md sections 1.1-1.3.
 *
 * The model string is the iOS-10.3-era 4-inch (armv7s, Swift core) device
 * that matches the {568,320} landscape canvas the compat doc expects
 * (iPhone5,4 = iPhone 5s class artwork target; M3 in the spec requires the
 * macOS/device pass to confirm it against the host UIKit screen spoof
 * before the host ticket wires it in).
 */
#ifndef LC32_GUEST_SYSCTL_VALUES_H
#define LC32_GUEST_SYSCTL_VALUES_H

#include <stddef.h>
#include <stdint.h>
#include <mach/machine.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/* hw.machine / utsname.machine — one source of truth for both surfaces. */
#define LC32_GUEST_HW_MACHINE "iPhone5,4"

/* hw.cputype / hw.cpusubtype — the app itself is armv7s. */
#define LC32_GUEST_CPU_TYPE CPU_TYPE_ARM
#define LC32_GUEST_CPU_SUBTYPE CPU_SUBTYPE_ARM_V7S

/* hw.physicalcpu_max / hw.logicalcpu_max. */
#define LC32_GUEST_PHYSICAL_CPU_MAX 2u
#define LC32_GUEST_LOGICAL_CPU_MAX 2u

/* hw.memsize — plausible iOS-device answer (1 GiB). */
#define LC32_GUEST_HW_MEMSIZE UINT64_C(0x40000000)

/* kern.ostype / kern.osrelease / kern.osversion (iOS 10.3.3, build 14G60). */
#define LC32_GUEST_KERN_OSTYPE "Darwin"
#define LC32_GUEST_KERN_OSRELEASE "16.6.0"
#define LC32_GUEST_KERN_OSVERSION "14G60"

/* sysctl.proc_native — a 32-bit process is not native on arm64-era
 * kernels; PLCrashReporter gates its Mach exception API on this being 0. */
#define LC32_GUEST_PROC_NATIVE 0

/*
 * struct utsname answers (five 256-byte fields per the guest SDK's
 * sys/utsname.h). machdep.* are not probed by mfm; only the five POSIX
 * fields are defined. version mirrors the 10.3.3 kernel build string.
 */
#define LC32_GUEST_UTS_SYSNAME "Darwin"
#define LC32_GUEST_UTS_NODENAME "localhost"
#define LC32_GUEST_UTS_RELEASE "16.6.0"
#define LC32_GUEST_UTS_VERSION \
    "Darwin Kernel Version 16.7.0: Sun Jun 4 21:18:13 PDT 2017; " \
    "root:xnu-3789.70.16~1/RELEASE_ARM_S5L8960X"
/* machine == LC32_GUEST_HW_MACHINE; see LC32GuestUTSName below. */

/* Type tag for the answer table below. */
typedef enum LC32GuestSysctlKind {
    LC32GuestSysctlKindU32 = 1, /* natural 32-bit answer */
    LC32GuestSysctlKindU64 = 2, /* 64-bit answer (hw.memsize) */
    LC32GuestSysctlKindStr = 3  /* NUL-terminated answer (hw.machine etc.) */
} LC32GuestSysctlKind;

/* One canonical sysctlbyname answer. */
typedef struct LC32GuestSysctlAnswer {
    const char *const name;  /* sysctl name, e.g. "hw.machine" */
    const LC32GuestSysctlKind kind;
    union {
        const uint32_t u32;
        const uint64_t u64;
        const char *const str;
    } value;
} LC32GuestSysctlAnswer;

/* NUL-terminated table (terminated by a NULL name), exported so a guest
 * test can assert against it without hard-coding answers twice. */
extern const struct LC32GuestSysctlAnswer LC32GuestSysctlAnswers[];

/* Five-field utsname answers, as plain strings (the host ticket writes
 * them into the guest 5 x 256 struct). */
typedef struct LC32GuestUTSName {
    const char *const sysname;
    const char *const nodename;
    const char *const release;
    const char *const version;
    const char *const machine;
} LC32GuestUTSName;

extern const LC32GuestUTSName LC32GuestUTSNameValues;

/*
 * KERN_USRSTACK32 (kern.332 via sysctl, not sysctlbyname) is deliberately
 * NOT a constant here: its correct answer is the top of the main guest
 * stack, dyldStackGuardStart + 0x100000 + 0xff000, computed by the host
 * bridge at runtime (LiveExec32Shared.cpp writes the same values into the
 * main_stack= apple vector). The host ticket must compute it, not copy it.
 */

#ifdef __cplusplus
}
#endif

#endif /* LC32_GUEST_SYSCTL_VALUES_H */
