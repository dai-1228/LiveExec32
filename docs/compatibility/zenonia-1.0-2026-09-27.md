# Zenonia 1.0 SDK-less status-bar compatibility — 27 September 2026

## Status

**Working on device.** Zenonia 1.0 (com.gamevil.Zenonia, 2009) launches
and plays under LiveExec32 installed through LiveContainer, verified on a
physical iPhone Air (iOS 26-era, Classic Mode): upright landscape
orientation, correct touch axes, and the 320×480 canvas presented centered
and filling the screen height with correct 3:2 aspect. The implementation
spans the `zenonia-compat` branch (merged into the fork's `dev`): legacy
status-bar orientation support for SDK-less 32-bit games (`f41c4fd`), the
upstream merge with the `CFURLCreatePropertyFromResource` re-port
(`6ef95d1`), the merge-audit fixes (`1e5a06a`, `a951a14`, `0ab6a65`,
`3b746a3`), the canvas presentation and its device-feedback corrections
(`c055b87`, `d6c8222`, `bf8d653`, and the final self-calibrating measured
fit `b96ed82`).

CI at the final tip is green on all three workflows: the full macOS build
([Build LiveExec32 run 36330418946](https://github.com/dai-1228/LiveExec32/actions/runs/36330418946)),
the host unit tests including the legacy status-bar and canvas-fit suites
([Zenonia compat host tests run 36330416376](https://github.com/dai-1228/LiveExec32/actions/runs/36330416376)),
and the fork `dev` build
([run 36330418950](https://github.com/dai-1228/LiveExec32/actions/runs/36330418950)).
The same tree is published as the fork's `nightly` release (IPA + rootless
DEB). Device verification covers launch, orientation, presentation, and
touch interaction; audio was exercised in gameplay but not formally
audited, and the extended simulator regression matrix
(`uikit_legacy_rootless_rotation`) remains macOS-manual.

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

### Canvas presentation (`c055b87` → `b96ed82`, device-verified)

The same keyless runtime-declared class receives the fixed 320×480
presentation: guest `UIScreen` answers the canonical canvas, the
OpenGLES adapter adopts a launch-sized drawable to that canvas before its
renderbuffer storage is allocated, the controller-less window's host
frame is grown to cover the live viewport (direct-subview autoresizing
frozen for the fit's lifetime), and a self-calibrating transform on the
window layer's `sublayerTransform` composes measured corrections until
the rendered canvas coincides with the measured screen rect. The three
device-feedback iterations that produced this architecture are documented
in the addendum below.

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

- [Build LiveExec32, run 36330418946](https://github.com/dai-1228/LiveExec32/actions/runs/36330418946):
  full macOS build on `macos-26` — generated shims, armv7s guest
  frameworks (which links the CoreFoundation/MediaPlayer changes), the
  ramdisk, the rootless deb, and the IPA; this compiles all production
  host code including `LegacyRotation.mm` and `UIKit.mm`.
- [Zenonia compat host tests, run 36330416376](https://github.com/dai-1228/LiveExec32/actions/runs/36330416376):
  `check-uikit-legacy-statusbar-orientation` (18 checks),
  `check-uikit-legacy-canvas-fit` (21 checks),
  `check-legacy-nib-loading`, `check-uikit-background-tasks`.
- The same tree merged into the fork's `dev` branch and rebuilt green
  ([run 36330418950](https://github.com/dai-1228/LiveExec32/actions/runs/36330418950));
  the fork's `nightly` release is built from it and is the artifact the
  device test installed.
- **None of the CI runs execute the extended rotation matrix** —
  `uikit_legacy_rootless_rotation.sh` needs a booted iOS simulator and is
  macOS-manual only. Guest link-level selector collisions for the new
  `lc32_*` methods were checked against the generator templates (clean),
  not by a link.

### Verified on device (iPhone Air, LiveContainer install)

- Launch through LiveContainer with LiveExec32 set as the default app:
  the game boots, reaches gameplay, and stays stable through play.
- Orientation: the single runtime `setStatusBarOrientation:3` request
  produces the correct landscape presentation — the root-cause analysis
  above is confirmed closed for the turn itself.
- Presentation: after the canvas-fit corrections below, the 320×480
  canvas renders centered, filling the screen height with 3:2 letterbox
  bars; the self-calibrating fit converges on this device's ~2.4:1
  Classic-Mode viewport.
- Touch: taps land at the correct logical points under the scaled,
  rotated presentation (menus, dialog dismissal, and movement were
  exercised during play).
- The launch also resolves two launch-blocker risks transitively: the
  C++ engine runs (253 SjLj frames through the RootFS
  `libstdc++.6.dylib`/`libgcc_s.1.dylib`), and the nib-driven
  controller-less window receives its legacy backing and
  requested-orientation turn.

### Regression checklist (macOS/simulator; device class verified separately)

The iPhone Air device run above is the functional verification for this
game; the commands below remain the reproducible regression surface for
the class, other SDK versions, and other devices:

```sh
# Host tests (no simulator needed):
gmake -C test check-uikit-legacy-statusbar-orientation    # 18 checks
gmake -C test check-uikit-legacy-canvas-fit               # 21 checks
gmake -C test check-uikit-background-tasks check-mediaplayer-stop
gmake -C test check-uikit-legacy-rootless-rotation-build  # compile gate

# Full matrix, 17 cases x 6 SDKs (2, 5, 6.1, 7, 8, 11):
sh test/uikit_legacy_rootless_rotation.sh --device UDID
# Focused new-case pass:
sh test/uikit_legacy_rootless_rotation.sh --device UDID --sdk 2 --sdk 11 \
    --case controllerless --case statusbar-request --case fixed-canvas
# 2009 keyless-plist variant (the Zenonia contract):
sh test/uikit_legacy_rootless_rotation.sh --device UDID --keyless
```

Device retest baseline (LiveContainer install): import the `nightly`
release IPA, set LiveExec32 as the default app, import the game bundle,
and verify launch → title → gameplay with upright orientation, centered
canvas, and correct touch mapping; screenshots of cold launch plus a
device rotation settle the remaining simulator-only observations.

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

Risks 1–3 and 7 as originally written are **resolved by the device run**
(noted inline); what remains:

1. ~~**Controller-less window turn is unproven on current UIKit.**~~
   Device-verified: the requested-orientation turn presents upright
   content on iOS 26 hardware. The fixture still asserts only the
   production unit's arguments, so compositor cooperation on *other*
   iOS versions remains a simulator-matrix item.
2. ~~**No fixed 320×480 canvas in native mode.**~~ Implemented and
   device-verified: fixed guest canvas, drawable adoption, window growth
   with frozen subview autoresizing, and the self-calibrating measured
   fit (`b96ed82` and predecessors). `UIScreen.bounds` can still change
   size mid-startup under Classic Mode — the fit refits, and converges
   once the viewport settles.
3. ~~**SjLj/C++ runtime from the RootFS is unverified.**~~ Resolved
   transitively: the game's 253 SjLj-instrumented frames execute on
   device, so the ramdisk ships working `libstdc++.6.dylib` and
   `libgcc_s.1.dylib`. The armv6 `objc_msgSend_stret` ABI note stands as
   review-level.
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
7. **Verification scope**: one physical device class (iPhone Air) and one
   Classic-Mode viewport has been exercised. The self-calibrating fit is
   per-pass and converges on measured geometry, but other devices/aspect
   ratios, the extended simulator matrix, accelerometer-driven 180° flips
   (the game's own GL rotation), and formal audio auditing remain
   unverified. The fit yields after 32 non-settling passes rather than
   looping; a viewport that oscillates would leave the last converged
   transform in place.

## Handoff

The original validation pass authored no commits or pushes; its two source
fixes (the guest MediaPlayer duplicate constant and the host duplicate
dispatch case) entered the branch tip via the coordinating session's
commits (`0ab6a65`, `3b746a3`). As of the final state, everything lives on
`zenonia-compat` **and** the fork's `dev` branch
(`08f8d84` merge), is built by the fork's CI (all three workflows green at
the final tip), and is published as the fork's `nightly` release — the
artifact installed on the device test. Nothing was pushed to the upstream
`LiveContainer/LiveExec32` repository; a pull request from
`dai-1228:zenonia-compat` is the natural upstreaming step. The wave-1/wave-2
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

A second device run (iPhone Air) after that correction still pinned the
canvas bottom-left: two failures of analytic placement mean the rotation's
mount point and conversion semantics on current iOS cannot be modeled
blind. The fit was then made self-calibrating (`b96ed82`): each pass
measures the screen rect and the rendered content rect through the same
CoreAnimation model-tree math, and composes a correction onto the
sublayer transform until the two coincide (converges within a quarter
point, bounded pass count). Anchor semantics, rotation placement, and
viewport churn are all absorbed by the iteration.

**Result: resolved on device.** The iPhone Air retest with the
self-calibrating fit presents the canvas centered and filling the screen
height with correct 3:2 aspect; the game is playable end to end with
correct touch mapping. Full analysis:
`/tmp/opencode/wave5-canvas-centering-fix.md` (session-local).
