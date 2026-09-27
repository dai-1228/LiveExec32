# Zenonia 1.0 SDK-less status-bar compatibility — 27 September 2026

## Status

Source-level compatibility pass for **Zenonia 1.0** (com.gamevil.Zenonia, 2009).
The implementation is complete in the `zenonia-compat` branch: legacy
status-bar orientation support for SDK-less 32-bit games
(`f41c4fd`), the upstream merge with the `CFURLCreatePropertyFromResource`
re-port (`6ef95d1`), and the merge-audit fixes that followed
(`1e5a06a`, `a951a14`, `0ab6a65`, `3b746a3`). CI at the branch tip is green:
the full macOS build passed
([Build LiveExec32 run 36312713886](https://github.com/dai-1228/LiveExec32/actions/runs/36312713886),
7m29s — guest shims, guest frameworks, ramdisk, rootless deb, IPA) and the
macOS host unit test passed
([Zenonia compat host tests run 36312711990](https://github.com/dai-1228/LiveExec32/actions/runs/36312711990),
18/18 checks under `-Werror`); the same tree also merged into the fork's
`dev` branch and rebuilt green
([run 36312713790](https://github.com/dai-1228/LiveExec32/actions/runs/36312713790)).
Earlier failed runs at intermediate commits are superseded and are not
claimed as evidence. Nothing in this pass was simulator- or device-verified:
no launch of the game has been attempted, and there is no audio or gameplay
certification of any kind.

## App profile

From the wave-1 IDA manifest (`Zenonia.i64`, armv6, 32-bit MH_EXECUTE,
417,844 bytes of ARM code, 3,088 functions, 222 hard imports, no weak
imports):

- Bundle `com.gamevil.Zenonia`, GAMEVIL "Clet" engine ported from Korean
  WIPI phones. Software-rendered 320×240 RGB565 frame blitted through
  OpenGL ES 1.1 into a 512×512 staging texture re-uploaded every tick.
- **SDK-less Mach-O**: no `LC_VERSION_MIN_IPHONEOS` (no `LC_MAIN`, no
  `LC_DYLD_INFO`; classic two-level binding, `LC_ENCRYPTION_INFO` as load
  command 0x21 with cryptid 0). LiveContainer's fallback therefore reports
  effective SDK **2.0** (`2.0*`), which selects LiveExec32's native legacy
  rotation mode.
- **Orientation-silent Info.plist**: `NSMainNibFile=MainWindow`,
  `MinimumOSVersion=2.0`, `UIPrerenderedIcon`; no
  `UISupportedInterfaceOrientations`, no `UIInterfaceOrientation`, no
  `UIStatusBarHidden`.
- The nib instantiates `MerkavaAppDelegate` and one `UIWindow` of
  **320×480 portrait**. `UIWindow` is never referenced in code; the only
  UIKit subclass in the binary is `EAGLView : UIView` (`+layerClass` →
  `CAEAGLLayer`). No `UIViewController` exists anywhere.
- Launch sequence: `setStatusBarHidden:YES animated:YES`, then
  `initWithLandscape:` reads `[UIScreen mainScreen].bounds` (portrait),
  then calls `setStatusBarOrientation:3` (LandscapeRight)
  `animated:NO` **exactly once**, creates the framebuffer, and finally
  `addSubview:` + `makeKeyAndVisible`. Rotation is done **inside GL**
  (`glRotatef(-90)`), and touch axes are swapped by the game
  (`game_x = pt.y; game_y = pt.x`); the window/view transform is never
  touched. The delegate implements no status-bar orientation callbacks.
- Audio: all in-game sound is OpenAL (game-parsed PCM WAV,
  `alSourceQueueBuffers` streaming driven by a 1 ms main-run-loop
  `CFRunLoopTimer`); `AudioSessionInitialize`/`SetActive` for session and
  interruption rebuild; `alcGetProcAddress("alcMacOSXMixerOutputRate")`
  queried for 44.1 kHz — the call site is NULL-guarded in the binary, so a
  host that answers NULL is harmless; `AudioServicesPlaySystemSound(0xFFF)`
  for vibration.
- Engine loop: self-re-arming one-shot `CFRunLoopTimer` on the main run
  loop in `kCFRunLoopCommonModes` (interval in ms). No threading imports at
  all.
- Resources: 965 bundle files read through
  `CFBundleCopyResourceURL` (subdirectory + extension-in-name paths) and
  `CFReadStream*`; sizes via
  `CFURLCreatePropertyFromResource(kCFURLFileLength)` (bound at load time
  from the import table). Saves via
  `NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,…)` + `fopen`.
- C++: GCC SjLj exceptions (253 instrumented functions importing
  `__Unwind_SjLj_*`, `__gxx_personality_sj0`, `__cxa_guard_*` from
  libstdc++.6/libgcc_s.1) and 32 `*vfp` soft-float libgcc helpers.

## Root cause — why every orientation path was disabled

Wave-1 gap analysis, §C.3. With an SDK-less binary under the effective-SDK-2.0
native rotation mode, the app hit five disabled pathways plus a policy
mismatch:

1. **Status-bar write dead-end.** The guest's
   `setStatusBarOrientation:animated:` forwarder resolved its host entry
   only when the canvas compatibility host reported one, and the host entry
   itself returned early unless canvas mode was enabled — in native mode the
   app's landscape intent was recorded nowhere.
2. **SDK-0 UIScreen gate.** The guest `UIScreen` portrait-coordinate override
   required a nonzero executable SDK below 8; an SDK-less binary kept modern
   orientation-ordered bounds, so the engine sized its window from the wrong
   geometry.
3. **Controller-less backing skip.** Legacy window backing and the
   before/after refresh around `_updateToInterfaceOrientation` required a
   *registered guest controller*; a 2009 main-nib window with a bare
   `EAGLView` subview and no controller got neither.
4. **Keyless portrait clamp.** With no orientation keys, the host/canvas
   policy fell back to Portrait-only (while the native rotation unit's own
   plist reading fell back to AllButUpsideDown), so even the SDK-11 escape
   hatch could not honor a runtime landscape request.
5. **Missing lifecycle delivery.** The deprecated
   `application:willChangeStatusBarOrientation:duration:` /
   `…didChangeStatusBarOrientation:` delegate pair and their two
   notifications were never synthesized; 2.x apps that wait on them to lay
   out never observe a turn. (Zenonia implements neither and observes
   neither, so this item is contract completion, not a Zenonia requirement.)

Expected visible outcome before the fix, matching the documented unresolved
`2.0*` games (Angry Birds Lite, Fruit Ninja, UNO): portrait-sideways or
shrunken/displaced content with mismatched input.

## Implementation

### Orientation support (f41c4fd)

Production changes, all gated on effective SDK < iOS 8 with the existing
`LC32_DISABLE_UIKIT_COMPATIBILITY` kill switch respected:

- `HostFrameworks/UIKit/LC32LegacyRotation.h` — three new declarations:
  `LC32LegacyRequestedStatusBarOrientation` and
  `LC32NativeLegacyRotationWindowIsGuest` (supplied by the UIKit adapter;
  test stand-ins in the fixture) and the rotation unit's own
  `LC32NativeLegacyRotationRefreshRequested`.
- `HostFrameworks/UIKit/LegacyRotation.mm` — `PreferredOrientation()` now
  prefers the recorded status-bar request inside the declared mask; new
  `ControllerlessLegacyWindow`/`WindowNeedsLegacyBacking` gates extend the
  inverse root-layer backing and the before/after refresh ordering to
  controller-less guest windows (tight no-root/no-controller/no-guest
  exclusions); a `UIWindowDidBecomeVisibleNotification` observer records
  them; `UpdateControllerlessWindow` turns such a window only to its
  explicitly requested orientation (ambient device turns are ignored — no
  invented turns for a hierarchy with no policy to consult).
- `HostFrameworks/UIKit/UIKit.mm` — the SVC-1002 status-bar entry admits
  the native mode (canvas branch byte-identical; SDK-8+ and the kill
  switch keep modern behavior); new
  `LC32UIKitHandleLegacyStatusBarHidden` records runtime
  `setStatusBarHidden:`; `LC32LegacyStatusBarHidden` serves the
  status-bar-hidden adapters and the full-screen viewport;
  `LC32DeliverLegacyStatusBarOrientationChange` posts both notifications
  (name literals matching the guest constants verbatim) and invokes the
  delegate pair behind `respondsToSelector:`/guest-callback guards, with a
  launch-seeded first announcement; `LC32LegacyGuestDeclaredOrientations`
  widens the keyless-bundle declared mask to AllButUpsideDown (plus the
  requested bit) at every declared-mask consumer, resolving the
  Portrait-vs-AllButUpsideDown inconsistency; the native branch of
  `LC32UIKitGetLegacyStatusBarOrientation` pairs the getter with the
  recorded request; `LC32UIKitGetLegacyControllerOrientation` answers in
  native mode.
- `GuestFrameworks/UIKit/LC32UIKitCompatibility.h` — new
  `LC32GuestNativeLegacyRotationEnabled` declaration and the shared
  inline `LC32GuestSDKUsesLegacyGeometryContract` (single source of truth
  for the three guest gates; canvas keeps its SDK-1..7 population; native
  inherits SDK-0; SDK-8+ never).
- `GuestFrameworks/UIKit/UIKit.m` — native-mode getter resolved via
  `LC32Dlsym`; `LC32ResolveLegacyScreenCoordinates` now serves SDK-0 under
  a pre-8 effective SDK (portrait-ordered `UIScreen` coordinates).
- `GuestFrameworks/UIKit/UIApplication+LC32LegacyOrientation.m` — resolves
  all three host entries unconditionally (the host gates behavior); the
  paired `statusBarOrientation` getter installs from the setters in native
  mode; `setStatusBarHidden:animated:` is exchanged with the generated
  forwarder to record the runtime request while preserving the forward.
- `GuestFrameworks/UIKit/UIViewController+LC32LegacyOrientation.m` — the
  `interfaceOrientation` override installs for SDK-0 under native
  rotation via the shared inline.
- `test/uikit_legacy_rootless_rotation.{m,sh}` — new `controllerless` and
  `statusbar-request` cases (default matrix now 16 cases × 6 SDKs) and the
  `--keyless` 2009-plist variant; existing flags, PASS-string contract
  (`rootless-rotation-regression: PASS` per case), and cleanup flows
  unchanged.
- `test/uikit_legacy_statusbar_orientation_host.m` +
  `test/uikit-legacy-stubs/` — new macOS host test (18 checks) compiling
  the real guest categories against a deterministic bridge stub
  (`make -C test check-uikit-legacy-statusbar-orientation`).
- `docs/configuration.md` — SDK-0 inheritance, runtime requests, and the
  `--keyless` regression documented.

No game names, bundle ids, or new fixed screen sizes were introduced; the
SDK-0 gates are keyed on the missing version marker plus the effective
process SDK, and canvas/SDK-8+ behavior is untouched.

### Upstream merge and CFURL re-port (6ef95d1, then audit fixes)

The merge brought in 55 upstream commits (CoreFoundation ABI renumbering,
guest `libiconv` now built from the apple-oss-distributions tarball — the
vendored `GuestLibraries/libiconv` is gone, and no stale references
remain). Zenonia binds `_CFURLCreatePropertyFromResource` at load time
(its old opcode 82 now collides with
`LC32CoreFoundationOpBundleCopyExecutableArchitecturesForURL`), so it was
re-ported to **opcode 1007** in the URL resource family:

- Guest shim `GuestFrameworks/CoreFoundation/CoreFoundation.m` (3 slots:
  url, property, guestError) →
- enum `LC32CoreFoundationOpURLCreatePropertyFromResource = 1007`
  (`LC32CoreFoundationBridge.h`; no value collisions tree-wide) →
- host case in `HostFrameworks/CoreFoundation/CoreFoundation.mm` with the
  matching 3-slot layout, under the file-scope
  `-Wdeprecated-declarations` pragma; the prototype comes from
  `CFURLAccess.h` via the CoreFoundation umbrella module, and the host
  framework is not built with `-Werror` (only the macOS unit tests are).
- `kCFURLFileLength` and the other `kCFURL*` property-name constants are
  exported from upstream's `CFConstants+LC32Exports.m` macro table
  (values identical to the old hand-written block).

The merge audit found and removed real merge residue: a duplicate
exported symbol
`MPMediaPlaybackIsPreparedToPlayDidChangeNotification` inside the guest
MediaPlayer framework (`0ab6a65`), a duplicate
`case LC32CoreFoundationOpReadStreamCreateWithFile:` in the host
CoreFoundation dispatch — a duplicate-case compile error once both sides
shared opcode 1100 (`3b746a3`), the duplicate `= 526` guest enumerator
(`1e5a06a`), and the fork's whole hand-written
`kCFURL*`/`kCFStream*` constant block that duplicated upstream's exports
table (134 lines; 118 duplicate symbols at the guest CoreFoundation link)
(`a951a14`, `0ab6a65`). The fork's copy of
`MPMediaPlaybackIsPreparedToPlayDidChangeNotification` was kept upstream's
ABI-renamed definition, matching the merge's stated intent.

## Verification

### Verified source-level in this pass

- Every file changed by `f41c4fd` reviewed for syntax, identifier
  resolution, imports, selector syntax, and ARC/MRC consistency (host
  `UIKit.mm` is MRC and its additions do no ownership transfer;
  `LegacyRotation.mm` is ARC and uses `__weak` accordingly). Guest↔host
  contract symmetry: the guest setter, the host record, the rotation
  unit's request, and the paired getter all read the same stored value;
  notification-name literals match the guest exported constants
  verbatim; the host test's stub headers model the exact API surface the
  production categories use.
- Gating: SDK-8+ paths, canvas-mode behavior, key-declaring bundles, and
  `LC32_DISABLE_UIKIT_COMPATIBILITY` are unaffected; the mask widening
  requires an actual runtime request from a keyless pre-8 executable.
- Merge port: opcode 1007 is inside the URL family with no collision;
  guest shim and host case agree on the 3-slot layout; no dead references
  to the old opcodes (82/526) remain; no tree-wide duplicate exported
  constants or duplicate dispatch cases remain (scripted sweep over all
  bridge enums and all guest/host sources).
- Import audit: all 222 imports have a plausible provider. The 143
  framework symbols (Foundation, UIKit, CoreFoundation, CoreGraphics,
  AudioToolbox, OpenAL, OpenGLES, QuartzCore) resolve through hand-written
  guest shims plus the generated shim templates — including
  `CFRunLoopContainsTimer`/`CFRunLoopTimerIsValid` (`CFRunLoop.m`),
  `CFURLCreatePropertyFromResource`, `CFBundleCopyResourceURL` with
  subdirectory paths, `NSSearchPathForDirectoriesInDomains`,
  `AudioSession*`, the `kEAGL*` constants, and `UIGraphicsPushContext`.
  The `objc_msgSend*`/`sel_getUid`/`__objc_empty_*` runtime internals and
  the 35 libc imports come from the real 32-bit RootFS dylibs.
  `alcGetProcAddress("alcMacOSXMixerOutputRate")` answers NULL and the
  binary's call site is NULL-guarded (re-verified in the IDB at
  `audio_init` 0x25200), which the wave-1 contract explicitly allows.
- Rotation fixture: 16 case names agree exactly between the `.sh`
  enumeration and the `.m` validation array; the per-case
  `rootless-rotation-regression: PASS` requirement, exit codes, and
  uninstall flow are unchanged; the SDK-8/11 runs assert the hooks stay
  disabled (`controllerless-update-hook-matches-sdk-gate`).

### What the tip CI covers (green)

- [Build LiveExec32, run 36312713886](https://github.com/dai-1228/LiveExec32/actions/runs/36312713886):
  full macOS build on `macos-26` — generated shims, armv7s guest
  frameworks (which links the CoreFoundation/MediaPlayer changes), the
  ramdisk, the rootless deb, and the IPA; this compiles all production
  host code including `LegacyRotation.mm` and `UIKit.mm`.
- [Zenonia compat host tests, run 36312711990](https://github.com/dai-1228/LiveExec32/actions/runs/36312711990):
  `check-uikit-legacy-statusbar-orientation` (18 checks),
  `check-legacy-nib-loading`, `check-uikit-background-tasks`.
- The same tree merged into the fork's `dev` branch and rebuilt green
  ([run 36312713790](https://github.com/dai-1228/LiveExec32/actions/runs/36312713790));
  the fork's `nightly` release was republished from it.
- **None of the runs execute the extended rotation matrix** —
  `uikit_legacy_rootless_rotation.sh` needs a booted iOS simulator and is
  macOS-manual only, and neither run has launched Zenonia itself. Guest
  link-level selector collisions for the new `lc32_*` methods were checked
  against the generator templates (clean), not by a link.

### Remaining work — macOS/simulator pass checklist

```sh
# Host tests (no simulator needed):
gmake -C test check-uikit-legacy-statusbar-orientation    # 18 checks
gmake -C test check-uikit-background-tasks check-mediaplayer-stop
gmake -C test check-uikit-legacy-rootless-rotation-build  # compile gate

# Full matrix, 16 cases x 6 SDKs (2, 5, 6.1, 7, 8, 11):
sh test/uikit_legacy_rootless_rotation.sh --device UDID
# Focused new-case pass:
sh test/uikit_legacy_rootless_rotation.sh --device UDID --sdk 2 --sdk 11 \
    --case controllerless --case statusbar-request
# 2009 keyless-plist variant (the Zenonia contract):
sh test/uikit_legacy_rootless_rotation.sh --device UDID --keyless
```

Per-run expectations: `rootless-rotation-regression: PASS` in every case
log, plus `controllerless-requested-turn-delivered: PASS`,
`controllerless-backing-selected: PASS`,
`controllerless-ambient-orientation-not-turned: PASS`,
`controllerless-unmarked-window-unchanged: PASS`,
`statusbar-request-declared-mask: PASS` (AllButUpsideDown under
`--keyless`), `statusbar-request-preferred-honored: PASS`, and at SDK
8/11 `controllerless-update-hook-matches-sdk-gate` proving the hooks stay
disabled. `git diff --check` clean; fixture apps uninstalled by the script.

Full product build before any game launch: `gmake` (host), `gmake -C
GuestMakefile generate-shims`, `gmake -C GuestMakefile`, then re-run
`pack-ramdisk.sh` so the rebuilt guest frameworks land in the RootFS.

Zenonia simulator pass: LC URL launch, Classic Mode on, per-app SDK
unclamped (effective 2.0 read back via debugger), `LCOrientationLock`
**off** for the primary pass (the fix should not need it) and **on** as an
A/B diagnostic — cold launch in portrait, landscape-right, and
landscape-left, plus return rotations, with idb captures before debugger
inspection and no prompts dismissed. Expectations: status bar hidden;
`UIApplication.statusBarOrientation` reads back 3; upright content once
the scene settles; portrait-coordinate menu taps landing correctly. If the
launch turn did not fire (risk 1 below) content appears
sideways-in-portrait until the device or LC lock turns the scene — capture
that distinction explicitly. Settings audit before/after: `classicMode`,
`spoofSDKVersion` (leave at the `2.0*` fallback), `LCOrientationLock`,
`LCClassicModeCache`. RootFS presence check before the first launch:
`Resources/RootFS/usr/lib/libstdc++.6.dylib` and `libgcc_s.1.dylib`
(contingency: build from source following the `build-libiconv.sh` pattern
if the ramdisk lacks them).

## Remaining risks

1. **Controller-less window turn is unproven on current UIKit.**
   `_updateToInterfaceOrientation:duration:force:` on a window with no
   rotation client may silently no-op; the fixture asserts only the
   production unit's arguments, not compositor cooperation. Mitigation
   paths (device turn, LC orientation lock) still present the content
   correctly via the extended backing, but the automatic launch turn needs
   simulator confirmation.
2. **No fixed 320×480 canvas in native mode.** Zenonia receives
   portrait-ordered *scene-sized* bounds, so its 320×480 quad covers a
   sub-rect of a large Classic-Mode scene — expect letterboxed/undersized
   content (the top fidelity item; a canvas-classifier extension was
   deliberately out of scope). `UIScreen.bounds` can also change size
   mid-startup under Classic Mode.
3. **SjLj/C++ runtime from the RootFS is unverified.** The 253
   SjLj-instrumented functions, `__gxx_personality_sj0`, the
   `__cxa_guard_*` trio, and 32 `*vfp` libgcc helpers require
   `libstdc++.6.dylib`/`libgcc_s.1.dylib` in the iOS 10.3.3 32-bit
   ramdisk; nothing in the repo builds them. This is a hard launch
   blocker if absent. Related ABI risk: `objc_msgSend_stret` on armv6
   (struct buffer as first argument) across 31 call sites.
4. **Host→guest delegate delivery is the most speculative addition** —
   main-queue, guarded by `LC32CanQueryGuestOrientation` and
   `respondsToSelector:`. Zenonia implements neither selector and
   observes neither notification, so for this game it is provably inert;
   it is the first thing to disable if a 2.x retest regresses.
5. **`UIWindowDidBecomeVisibleNotification` posting** on iOS 26/27 is a
   discovery dependency for controller-less windows; `_configureRootLayer`
   selection is independent of it, and nib-load visibility still posts it
   today.
6. **Canvas + runtime-hidden**: pre-8 executables in canvas mode that hide
   the status bar at runtime now qualify for the full-screen viewport —
   intended, but covered only by review, not by a fixture.
7. **All evidence in this report is source-level**; the two CI runs were
   incomplete when this was written and may have been dispatched before
   the final merge-audit fixes. The simulator matrix, Zenonia launch,
   audio, and gameplay remain entirely unverified.

## Handoff

This validation pass authored no commits or pushes; its two source fixes
(the guest MediaPlayer duplicate constant and the host duplicate dispatch
case) are in the branch tip via the coordinating session's commits
(`0ab6a65`, `3b746a3`). Everything above lives on `zenonia-compat` in the
fork; nothing was merged or pushed elsewhere, and the wave-1/wave-2
reports under `/tmp/opencode/` were not modified.

## Addendum — device feedback iteration: canvas presentation (27 September 2026)

The first device run launched and played correctly upright with working
touch axes, but the canvas rendered in the screen corner instead of
filling it. A presentation fix (fixed-canvas sizing, drawable adoption,
uniform-scale fit) was added, then a follow-up device run still showed a
corner-anchored canvas. The follow-up correction is committed with the
message "Present the native legacy canvas measured to the live viewport":

- The game's window is nib-authored at exactly 320×480 and never resized
  by guest code; the window therefore did not cover the presentation, and
  the fit's canvas-inside-window-bounds gate rejected every pass (the
  transform was never applied). The host frame now grows the window to
  the live viewport first — host-only mutation; the class never reads the
  window back — with direct-subview autoresizing frozen during the fit
  and restored afterward.
- The original fit assumed an axis-aligned 320×480 canvas rect in the
  window layer's space, but the native backing rotation lives inside that
  subtree, so the sublayer transform composes outside the rotation. The
  fit now measures the canvas rect by converting each direct guest
  subview layer into the window layer's space (CoreAnimation applies the
  active rotation) and centers/uniformly scales the measured rect onto
  the viewport, per pass, self-correcting on every rotation or viewport
  event.

A second device run after that correction showed the canvas scaled up but
still pinned bottom-left. Root cause per Apple's Core Animation
Programming Guide: CoreAnimation applies `sublayerTransform` **relative to
the layer's anchor point**, not the bounds origin, so the origin-based
translation was offset by exactly `(1-scale)*anchor` — the anchor
compensation is now included (same math the canvas-mode direct compositor
already used). Status: committed and CI-verified; awaiting the next
device retest. Full analysis:
`/tmp/opencode/wave5-canvas-centering-fix.md` (session-local).
