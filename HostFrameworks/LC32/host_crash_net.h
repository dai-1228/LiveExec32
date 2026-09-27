#pragma once

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Installs the process-wide diagnostics net for host-side failures which no
 * bridge dispatch shield observes: an uncaught Objective-C exception handler
 * which records the exception on stderr and preserves it as the process
 * abort reason, and async-signal-safe SIGSEGV/SIGBUS/SIGABRT handlers which
 * record the native backtrace for host-code faults outside the JIT.
 *
 * The LiveExec32Shared framework constructor installs this exactly once, at
 * the same point the emulator installs its other process-wide machinery.
 * The call is idempotent and safe from any thread.
 */
void LC32InstallHostCrashNet(void);

#ifdef __cplusplus
}
#endif
