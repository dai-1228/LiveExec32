#ifndef LC32_LEGACY_BUNDLE_LAYOUT_H
#define LC32_LEGACY_BUNDLE_LAYOUT_H

/* The installer owns the outer link. Its exact relative target establishes
 * that the reserved inner symlink is runtime-managed as the bundle moves. */
#define LC32_LEGACY_BUNDLE_ALIAS_NAME "LiveExec32.app"
#define LC32_LEGACY_BUNDLE_MANAGED_TARGET "Documents/.LiveExec32.app"
#define LC32_LEGACY_BUNDLE_INNER_ALIAS_NAME ".LiveExec32.app"

#endif
