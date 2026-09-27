#ifndef LC32_INJECTOR_LEGACY_BUNDLE_LAYOUT_H
#define LC32_INJECTOR_LEGACY_BUNDLE_LAYOUT_H

#include <stdbool.h>

/* The descriptor stays owned by the caller. A normal ARM32/ARM64 universal
 * executable is not sufficient: the ARM64 slice must contain our shim marker. */
bool LC32ExecutableNeedsLegacyBundleLayout(int executableFD);

/* Only call with the committed app data container supplied by the installer.
 * Creates HOME/LiveExec32.app -> Documents/.LiveExec32.app without replacing
 * any existing entry or claiming a pre-existing inner alias. Documents must
 * already be a real directory. An existing exact outer link is idempotent. Returns
 * zero for the desired link, or an errno value; never creates a container. */
int LC32CreateLegacyBundleOuterLink(const char *homePath);

#endif
