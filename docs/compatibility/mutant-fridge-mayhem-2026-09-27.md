# Mutant Fridge Mayhem 4.1.1 universal declared-landscape compatibility — 27 September 2026

## Status

**Implementation complete, not device-verified.** The declared-universal
legacy phone canvas class — the fixed phone-screen presentation for a
pre-iOS-8 *universal* executable that declares a landscape-only phone
policy while executing in the phone idiom — is implemented on
`zenonia-compat` ("Add the declared-universal legacy phone canvas class"
`7a3d4c6`, with two host-build corrections that followed: `fb5bc49`,
`2ea03cf`, both about holding the drawable record weakly under manual
reference counting). The implementation is source-level verified
(independent audit of the full diff against the game's
reverse-engineered contract), host-test-verified, and build-verified
only. **No launch has been attempted**: the first device pass is
pending, and every statement below about runtime behavior —
launch, geometry, presentation, audio, video, Crittercism, GCD pacing — is
a prediction from analysis, not an observation.

CI on the branch (through `2ef53a0`): the host unit tests are green
([Zenonia compat host tests, run 36346450250](https://github.com/dai-1228/LiveExec32/actions/runs/36346450250),
38 s), covering the new classifier truth table, the tall-art canvas
selection, the strict-additivity guarantee, and the extended
geometry-contract gate, alongside the existing legacy status-bar and
canvas-fit suites. The full macOS build at the same commit is green
([Build LiveExec32, run 36346450357](https://github.com/dai-1228/LiveExec32/actions/runs/36346450357),
5m32s — generated shims, armv7s guest frameworks, ramdisk, rootless deb,
IPA). The first two build attempts failed compiling the host UIKit
adapter: clang refuses weak references of every spelling in a manual
reference counting file, so the drawable record now takes its zeroing
semantics from an NSMapTable with weak values; earlier failed runs are
superseded and are not claimed as evidence. Device verification remains
open; the guest end-to-end regression test that would make the
controller-backed fit path CI-checkable now **exists**
(`test/uikit_legacy_declared_universal_canvas.m`, delivered by the
30 September wave below) but has never executed on any runner.

## App profile

From the wave-1 IDA manifest (`mfm.i64`, IDA Pro 9.4; image base 0x4000):

- Bundle `com.turner.mfm` v4.1.1 ("Mutant Fridge Mayhem", Cartoon Network,
  2013). **armv7** (cputype 12, cpusubtype 9), PIE, two-level, MH_EXECUTE,
  `LC_DYLD_INFO_ONLY` (rebase 20 KB, bind 9.5 KB, 2-entry weak_bind,
  lazy_bind mini-streams), `LC_UNIXTHREAD` entry (no `LC_MAIN`),
  `LC_ENCRYPTION_INFO` cryptid 0, **no `LC_UUID`**.
  `LC_VERSION_MIN_IPHONEOS` carries **version 4.3.0 and sdk 7.0.0**
  (MinimumOSVersion 4.3; built with the iphoneos 7.0 SDK, Xcode 5.0.2 /
  5A3005). LiveExec32's classifiers key on the command's **sdk field**
  (0x00070000) — the built-against SDK, never a spoofed value; 4.3 is the
  deployment floor.
- **Universal**: `UIDeviceFamily` = [1, 2]. Orientation is declared in the
  plist, both idioms: `UISupportedInterfaceOrientations` (and
  `~ipad`) = `UIInterfaceOrientationLandscapeRight` +
  `UIInterfaceOrientationLandscapeLeft`. `UIStatusBarHidden` = true (both
  idioms), `UIViewControllerBasedStatusBarAppearance` = false. **No runtime
  status-bar API**: `setStatusBarOrientation:`/`setStatusBarHidden:` are
  absent from the binary; the getter is read only (Crittercism).
  Launch art: `Default.png`, `Default@2x.png`, `Default-568h@2x.png`,
  `Default-Landscape~ipad.png`, `Default-Landscape@2x~ipad.png`.
- **662 unique imports from 26 linked dylibs** (24 strong + 2 weak:
  AdSupport, Foundation), including **4 zero-import strong links** that
  must merely exist at load (libsqlite3, CoreLocation,
  MobileCoreServices, CoreData) and the real 32-bit ramdisk residents
  (libz.1, libobjc.A, libstdc++.6, libSystem.B, libgcc_s.1). All 26 have
  a provider in the guest world today (wave-1 §A.3).
- Engine: **cocos2d-iphone 2.x** (heavily customized "Universal" fork:
  `CCDirectorIOSUniversal` with `makeUniversal`/`pointScaleFactor`/
  `enableRetinaDisplay:onPad:`) + CocosBuilder (`CCBReader`) + LevelHelper
  + GBox2D/Box2D + kazmath. **OpenGL ES 2 only** (`CCES2Renderer`;
  `EAGLContext initWithAPI:2`; no ES1 path), CAEAGLLayer RGBA8, no depth
  buffer, VAO OES / discard EXT entry points must resolve,
  `glGetString(GL_EXTENSIONS)` must be a parseable space-separated list
  (CCConfiguration parses it), `CCGLProgram` `abort()`s on shader compile
  failure. PVR + PVR.CCZ textures through libz.
- UIKit shell: `main` → `UIApplicationMain` → delegate builds
  **UIWindow → RootNavigationController (UINavigationController,
  landscape-only mask 24) → CCDirectorIOSUniversal (a UIViewController)
  → CCGLView (CAEAGLLayer)**. The GL view is created with hardcoded
  portrait bounds ({0,0,320,480} iPhone / {0,0,768,1024} iPad) and UIKit's
  rotation swaps its bounds and applies the transform. All geometry derives
  from `[UIScreen mainScreen]`; `winSize = view.bounds / pointScaleFactor`.
  Frame loop is CADisplayLink in common modes, paused for the video.
- **GCD-paced launch** (numbers corrected by the 30 September analysis wave,
  see the next section): `dispatch_after` drives didFinishLaunching →
  (100 ms) initIAP + title scene → (2 s after the menu appears)
  `initGameCenter`; the **~3.5 s** delay before `playIntroVideo` is
  **cocos2d CCSequence timer pacing (`CCDelayTime`), not `dispatch_after`**
  — a hang before that point is not the video chain. Texture loading uses
  `dispatch_sync`/`dispatch_async`
  on custom queues; 309 stack-block sites with copy/dispose helpers. The
  save file (`GumballSaveState.dat`, a deep `NSKeyedUnarchiver` graph) is
  loaded in `-init`, before `didFinishLaunching`.
- **Intro video (single most delicate P0)**: `AVURLAsset`
  `loadValuesAsynchronouslyForKeys:@[@"tracks",@"playable"]` →
  `AVPlayerItem`/`AVPlayer` + KVO (`status`, `rate`, `currentItem`) →
  `AVPlayerLayer` in a modally presented `VideoPlayerView` → custom
  `VideoReadyToPlay`/`VideoBeganPlaying`/`VideoCompleted` notifications →
  `firstRealScene`. **Every failure mode is a built-in exit**: asset
  status Failed or `isPlayable` NO posts `VideoCompleted` and the game
  jumps to the menu; a raw touch anywhere also skips (`ccTouchBegan:` →
  `videoComplete`). Only a class-exists-but-nothing-fires shim hangs the
  title screen.
- Audio: **CocosDenshion** — `CDAudioManager` configures `AVAudioSession`
  (SoloAmbient/Ambient; `AudioSessionGetProperty('othr')`, never
  `AudioSessionInitialize`), **OpenAL** for all effects (44.1 kHz via
  `alcMacOSXMixerOutputRate` — NULL-tolerated, 64 buffers / up to 32
  sources), **AVAudioPlayer** (`CDLongAudioSource`) for the 8 `.mp3`
  music tracks. Effects decode: `.wav` via AudioFile*, anything else
  (including `music_intro.mp3` through the *OpenAL* path) via
  **ExtAudioFile\*** — MP3 decode is required for the menu jingle.
  `MPMusicPlayerController iPodMusicPlayer` is registered but benign if
  its notifications never arrive.
- Third-party SDKs initialized unconditionally at launch: **Crittercism**
  with embedded **PLCrashReporter** (dyld add/remove-image callbacks for
  every loaded image, `sigaltstack` 64 KB + `sigaction` ×6 signals,
  uncaught-exception handler, 3 SCNetworkReachability notifiers,
  `sysctlbyname("hw.machine")`; every internal failure is NSLog + continue
  — but each call must return sane values), **Chartboost**, **PlayHaven**,
  **Omniture** (ADMS), **comScore**. GameCenter sits behind an
  `NSClassFromString("GKLocalPlayer")` + system-version probe and
  degrades to offline leaderboards; StoreKit adds a transaction observer
  at +100 ms and only requests products when reachable.
- C++: **GCC SjLj exceptions** (`__gxx_personality_sj0`,
  `__Unwind_SjLj_*`) with Box2D/LevelHelper/kazmath — the Zenonia-proven
  libstdc++/libgcc_s chain. ObjC at scale: 615 classes, 7,398 selrefs,
  `objc_msgSend_stret` ×1,718, `NSClassFromString` load-bearing for
  CCBReader level objects; one `__mod_init_func` (Crittercism) that must
  run after class registration.

## Root cause — a universal plist-declared landscape game fit no canvas class

Wave-1 gap analysis §D.4 / P1-1. Every existing legacy-canvas classifier
excluded this app's *class* on purpose:

- `LC32BundleUsesFixedLandscapePhoneCanvas` and
  `LC32BundleMayRetainLegacyLandscapePhoneCanvas` require a **phone-only**
  bundle (`!supportsPad`; `include/LC32LegacyCanvas.h:275-306`) — a
  universal bundle answers NO.
- `LC32UsesRuntimeLandscapePhoneCanvas` (the Zenonia class) additionally
  requires **no orientation-policy keys** (`:321-330`) — a plist-declaring
  bundle answers NO twice over. This is by design: Zenonia's disease
  (keyless, runtime-only declaration) does not exist here.
- `LC32BundleLegacyIPadCanvasKind` answers None: Declared requires
  pad-only, and Inferred requires *exclusively* iPad launch art —
  `Default.png` keeps a universal bundle out.
- Host gates agreed: the scale clamp and the 320x480 bounds override are
  keyed on those classes, and `LC32NativeLegacyCanvasWindowEligible`
  required a **controller-less** window — but this engine installs its own
  `rootViewController:` (the navigation-controller shell), so the measured
  fit machinery could never engage.
- In native legacy rotation the shared geometry contract
  (`LC32GuestSDKUsesLegacyGeometryContract`) served **SDK-0 binaries
  only** — a binary with an SDK marker (this one: 7.0) kept modern
  orientation-ordered `UIScreen` bounds and no controller
  `interfaceOrientation` override.

Net effect (wave-1 §D.2/§D.3): correct *rotation* through the plist-driven
rotation unit, but **scene-sized modern bounds** (≈440x956-class on a
full-screen iPhone Air) with **unclamped scale 3**, against an engine whose
GL frames are hardcoded {0,0,320,480} and whose universal director only
understands 320x480-phone and 1024x768-pad design bands. In canvas mode
(effective SDK ≥ 8) the same class got portrait-ordered but still
scene-sized geometry. That is the playability gap this commit closes.

## Implementation (`7a3d4c6`, corrected `fb5bc49`/`2ea03cf`)

Production changes, all gated on the executable's **own** SDK (raw
`LC_VERSION_MIN_IPHONEOS`/`LC_BUILD_VERSION` sdk field, never a spoofed or
effective value):

- **Classifier** — new shared inline
  `LC32BundleUsesDeclaredLandscapePhoneCanvasInPhoneIdiom(bundle,
  sdkVersion, executingInPhoneIdiom)` in `include/LC32LegacyCanvas.h`:
  pre-iOS-8 executable SDK; **both device families required** (this is
  what makes the class strictly additive: every existing phone class
  excludes `supportsPad`, every iPad class excludes phone launch art or
  the phone family); **landscape-only phone policy** (the `~iphone` key
  with the generic fallback, or the `UIInterfaceOrientation` key);
  **phone launch art present**. Executing in the phone idiom is a runtime
  property supplied by the caller — iPad-idiom execution answers NO and
  keeps the normal universal path. The stable-side requirement of the
  phone-only classes is deliberately absent: this population declares
  both landscape sides and lets the first launch settle the side, and the
  measured fit is side-independent. Tall (4-inch) launch art selects the
  canvas *height* (568 vs 480 points), not class membership — mirroring
  the fixed/retain pair's relationship.
- **Host gate** — `LC32NativeDeclaredLandscapePhoneCanvasClassActive()`
  (`HostFrameworks/UIKit/UIKit.mm`): the static legacy-rotation load → the
  once-cached bundle predicate → the live device idiom
  (`UIDevice.currentDevice`). Because it requires native legacy rotation,
  it answers NO in canvas mode — that is the canvas-mode scope decision
  (below). The new guest-facing live answerer
  `LC32UIKitUsesNativeDeclaredLandscapePhoneCanvas` follows the
  runtime-class answerer's round-trip pattern exactly (guest `LC32Dlsym`
  → `LC32InvokeHostCRet32`; an older host answers 0 and keeps modern
  geometry).
- **Guest canvas** (`GuestFrameworks/UIKit/UIKit.m`): `UIScreen.bounds`
  → {0,0,320, 480-or-568} portrait-ordered (568 when the bundle ships
  4-inch launch art); `applicationFrame` status-bar-consistent (full
  height when the plist hides the bar, else a 20-point inset); the scale
  clamp to 2.0 extended to the class. The bundle-derived snapshot (canvas
  height + status-bar preference) resolves lazily with the first
  `UIScreen` canvas read — no new early-guest-bundle-access pattern.
- **Geometry contract** — `LC32GuestSDKUsesLegacyGeometryContract`
  (`GuestFrameworks/UIKit/LC32UIKitCompatibility.h`) gained the host's
  live class answer as a 4th parameter, ordered so every existing
  population is unchanged: SDK-8+ executables never; canvas hosts keep
  their SDK-1..7 answer; SDK-0 natives keep their inheritance; the new
  population qualifies last, only under native legacy rotation with the
  live class answer. The controller `interfaceOrientation` override
  (`UIViewController+LC32LegacyOrientation.m`) installs for SDK-1..7
  universal executables in native mode through this gate (closing the
  SDK-0-only hole from wave-1 §D.2); the +load path performs only the
  same kind of early work the baseline already did (a `LC32Dlsym` bridge
  resolve plus one live host call whose answerer touches only static
  loaders, the cached bundle policy, and `UIDevice.currentDevice` — no
  windows or views). The host's `LC32UIKitGetLegacyControllerOrientation`
  needed no changes: its existing gates (universal ⇒ not the
  phone-canvas plist class; phone launch art ⇒ not an iPad canvas) leave
  the generic legacy fallback to answer the declared landscape.
- **Controller-backed fit** — `LC32NativeLegacyCanvasWindowEligible`:
  controller-less windows keep their existing meaning for either class;
  controller-backed windows qualify exactly while the new class is active
  (the runtime-declared class keeps requiring the controller-less window,
  so Zenonia's path is byte-for-byte unchanged). The measured iterative
  fit (`LC32FitNativeLegacyCanvasWindow`) is unchanged except for the
  **content-rect source**: for a controller-backed window of the class it
  measures the rendered rect of the layer backing the adopted drawable
  (a controller-backed window's only direct subview is the root
  controller's view, which covers the window after growth — the union
  would measure the screen, not the canvas), validating that the layer is
  still mounted in this window's model tree, with the direct-subview
  union (loop body identical) as the fallback for any failure, for
  controller-less windows, and for passes before the first
  `renderbufferStorage`. The record (`LC32RecordNativeLegacyCanvasDrawable`)
  is a weak-`CALayer` state object on the owning window, written even
  when the adoption below is a no-op, and never extends a retired layer's
  lifetime.
- **Root-view freeze** — the window-growth freeze
  (`LC32FreezeNativeLegacyCanvasSubviews`) now also freezes the root
  controller's own (host-side, guest-mirror-less) view under the class,
  so the canvas keeps its authored geometry through the growth that
  covers the viewport; the rotation turn sizes that view explicitly
  rather than through autoresizing, so the freeze cannot interfere with
  the turn, and the mask restore runs only beside the fit's own teardown.
- **Drawable adoption rule** ("drawable = the view's own bounds") —
  `LC32UIKitAdoptNativeLegacyCanvasDrawable` (`UIKit.mm`, reached from the
  OpenGLES `renderbufferStorage:fromDrawable:` normalization): the
  runtime-class branch is preserved verbatim (scene-sized → 320x480
  re-fit); the declared-class branch re-fits only a launch-sized view
  that arrived **larger than the bundle's own canvas** (480/568 from tall
  art), and leaves a view authored at or below canvas size untouched —
  that era's engines hardcode the drawable to the view's frame, and iOS
  sized the renderbuffer from it, so the authored geometry is the
  contract. For this game the authored {0,0,320,480} view of a 320x568
  canvas passes through untouched.
- **Strict additivity, encoded**: universal ⇒ phone-only classes all
  excluded; phone-only ⇒ new class excluded (and the single-side
  phone-only bundle keeps the existing plist class); pad-only or
  exclusively-iPad-art ⇒ iPad classes' territory; SDK-8+ executables
  never enter any new branch (classifier first line, host cache, guest
  gate first line). Canvas mode (effective SDK ≥ 8) is **unchanged**: the
  geometry-contract gate keeps the canvas branch first, the host class
  gate answers NO there, and the canvas-mode adapters keep their existing
  population — documented explicitly in `docs/configuration.md`, which
  also states that extending the canvas-mode container to this population
  is left for a device-verified follow-up.

## Verification

### Host tests (green at the tip: [run 36346450250](https://github.com/dai-1228/LiveExec32/actions/runs/36346450250), 38 s; first passing run [36344180112](https://github.com/dai-1228/LiveExec32/actions/runs/36344180112) at `7a3d4c6`)

- `check-uikit-legacy-canvas-fit` (now 38 checks) — the runtime-class and
  fit-math checks are unchanged; the new checks run the classifier's
  truth table over **real on-disk bundle fixtures** (unique directories
  under the temporary directory, removed per case):
  universal+landscape-only+pre-8+phone-idiom ⇒ YES (including the SDK-0
  marker); pad-idiom execution ⇒ NO; SDK-8+ ⇒ NO; portrait-declaring ⇒ NO;
  missing phone launch art ⇒ NO; keyless universal ⇒ NO;
  `UIInterfaceOrientation`-key ⇒ YES; `LC32BundleLegacyIPadCanvasKind`
  stays `None` for the qualifying bundle; the strictly-additive guarantee
  from both directions (phone-only single-side ⇒ new class NO *and* the
  existing plist class YES; phone-only both-sides ⇒ both NO, i.e. still
  unclassified; pad-only ⇒ NO); and the canvas-height selection evidence
  (`LC32BundleContainsTallPhoneLaunchArt` NO without / YES with
  `Default-568h@2x.png`).
- `check-uikit-legacy-statusbar-orientation` — the 8 existing
  geometry-contract checks updated to the new arity with the class flag
  modeled as NO (their populations unchanged); 7 new checks: SDK-1/SDK-7
  + native + class ⇒ YES; native-without-class ⇒ NO;
  class-without-legacy-modes ⇒ NO; canvas+class ⇒ the canvas answer
  unchanged (positive check); SDK-8/SDK-11 + class ⇒ NO. The fixture's
  stub bridge deliberately models an **older host** for the new entry
  (dlsym ⇒ 0), so the production `+load` older-host path is exercised;
  the behavioral controller/status-bar checks are unchanged.
- `check-uikit-legacy-rootless-rotation-build` compiles the unchanged
  `LegacyRotation.mm` against the updated declarations.

### What remains unverified (device or a native simulator pass)

- **Controller-backed eligibility end-to-end**, the drawable-layer
  measurement selection, the root-view freeze through window growth, and
  the end-to-end 320x568 spoof + adopted drawable + converged fit — the
  host fixtures are pure-math/classifier tests by construction (no real
  UIKit windows); the production adapter paths need real UIKit.
- The **AVPlayer intro-video chain** (the largest genuinely-new runtime
  surface no previous title exercised): asset load → KVO →
  ReadyToPlay/play/end-of-item, or the built-in failure exit.
- **Crittercism/PLCrashReporter init** (first title with a crash reporter
  under the JIT), **GCD launch pacing**, **ExtAudioFile MP3 decode** (the
  menu jingle through OpenAL), **AVAudioPlayer music**, save-file
  unarchive at init.
- GameCenter/IAP/ads: documented dead-or-degraded features (auth stubbed
  NO, products request skipped when unreachable, ad flows never at
  launch) — expected inert, not verified.
- `gmake -C test check-symbols` runs only as a **manual** invocation on the
  macOS host; it is **not** part of the nightly CI build (corrected by the
  30 September audit of the workflows — the nightly runs generate-shims,
  guest build, pack-ramdisk, package ×2 with no `gmake -C test` step, and
  the host-test workflow runs only the four pre-existing host checks). The
  guest end-to-end regression test for this class — modeled on
  `test/uikit_legacy_native_canvas.m`, with `UIDeviceFamily [1,2]`, plist
  landscape keys, 4-inch launch art, a `rootViewController`-wrapped renderer,
  and no runtime status-bar call — **now exists**
  (`test/uikit_legacy_declared_universal_canvas.m`, registered as
  `gmake -C test uikit-legacy-declared-canvas`); see the 30 September
  section below.

## Remaining risks

Ranked; the first five are the device-pass checkpoints.

1. **Fit-on-controller-window is the new, only-source-reviewed path.**
   The controller-backed eligibility, drawable recording, and measurement
   have no fixture. Watch the cold-launch geometry (see Handoff) and the
   presented canvas; a failure here degrades to a self-consistent
   (scene-sized) presentation, not a crash.
2. **Intro-video hang** (wave-1 P0-R3): if the AVPlayer chain never
   fires, the title screen waits forever — but **a raw tap anywhere
   skips it** (`ccTouchBegan:` → `videoComplete`). If the video stalls,
   tap first, then debug AVFoundation.
3. **Root-view resize through window growth** (the freeze's assumption):
   if modern UIKit ever re-frames the root view *explicitly* despite the
   frozen autoresizing mask, the container grows to the viewport, the GL
   view is re-framed by the nav layout, and the fit converges to identity
   — the wave-1 status quo, self-consistent, not a crash. Also: the
   freeze covers a root view that is *loaded* at fit time
   (`viewIfLoaded`); for this game's timeline the view is loaded before
   the startup turn, but a late-loading root view would escape the
   freeze and fall back to the drawable-measured presentation.
4. **Audio paths**: menu loop (AVAudioPlayer) and the OpenAL/ExtAudioFile
   MP3 jingle are unexercised on device; failure modes are silent game
   (`playEffect` −1 tolerated) or missing BGM.
5. **Effective-SDK guard**: the class requires **native legacy rotation**
   (effective process SDK < 8). Under the LiveContainer flow, leave the
   per-app `spoofSDKVersion` unclamped (as in the Zenonia passes); an
   SDK-11 clamp puts the app in canvas mode where this class
   intentionally does nothing (rotation + portrait-ordered, scene-sized
   geometry — wave-1 Case 2).
6. **P0-R1 RootFS content** (CI-verify on macOS after
   `pack-ramdisk.sh`): `libz.1.dylib` and `libsqlite3.dylib` must be
   present in `Resources/RootFS/usr/lib` — absence is a dyld
   "Library not loaded" abort at launch.
7. **P0-R2 Crittercism first-exercise**: every mach/dyld/thread import it
   makes is implemented (wave-1 §C.2 table), but no title has run a crash
   reporter under the JIT yet; a hang here blocks before
   `didFinishLaunching`.
8. **Canvas-mode population left as-is** (documented): if a clamped
   runtime ever becomes the primary target, the canvas-mode container
   needs its own universal-class work.
9. **Expected first-scene `winSize` {320,480}** on the 4-inch-art canvas
   (corrected by the 30 September adjudication — see the next section for
   the full correction of this document's earlier {568,320} expectation):
   `winSize` comes from the authored `CCGLView` bounds
   (`reshapeProjection:` re-reads `view.bounds`, never `UIScreen`), and
   CCGLView is hardcoded {0,0,320,480}, so the value is 320x480 on both
   3.5- and 4-inch real hardware. The 568-tall `UIScreen.bounds` answer
   still drives the window frame, the 568h launch-art branch, and the ~40
   `bounds.height==568` HUD/menu position forks. If the device instead
   observes {568,320}, escalate through the GEO-02 contingency table in
   the 30 September runbook — do not ad-hoc patch.

## Handoff

Evidence files (session-local under `/tmp/opencode/`, not part of the
repo): `mfm-wave1-ida-manifest.md` (the behavioral contract),
`mfm-wave1-liveexec-gaps.md` (surface map + the §D.4/P1-1 gap this closes),
`mfm-wave2-implementation-log.md` (implementation rationale and its own
device-feedback list). The validation pass authored no commits or pushes;
this document and the audit findings are its only outputs.

Recommended device-install flow (LiveContainer, mirroring the Zenonia
passes): import the LiveExec32 **nightly** build, set LiveExec32 as the
default app, import the game IPA, launch — with the per-app SDK override
left unclamped so the effective process SDK stays pre-iOS-8 (native legacy
rotation). Before the first launch, on the macOS build host, run the
manual RootFS content check in the 30 September runbook below (the
phrase "the RootFS check in risk 6" below originally implied a scripted
check exists — none does; `pack-ramdisk.sh` asserts only
`System/Library`). Expected geometry on the 4-inch-art canvas
(**corrected** by the 30 September adjudication — the original
{568,320}/{1136,640} expectation printed here was wrong):
`UIScreen.bounds` {0,0,320,568} portrait-ordered, `scale` 2.0,
`applicationFrame` {0,0,320,568} (plist-hidden status bar), first-scene
`winSize` **{320,480}** / `winSizeInPixels` **{640,960}**, GL backing
**640x960** — identical to real 4-inch hardware running the game's own
320x480 world; expected presentation: the
320x568 portrait canvas turned to landscape (568x320 points, 1136x640
pixels at the clamped 2x) MIN-scaled onto the live viewport, centered
with letterbox bars — on a ~2.4:1 Classic-Mode viewport the 16:9-class
content fills the screen height with side bars, the same binding the
device-verified Zenonia canvas produced. Watch: dyld messages, Crittercism
init completing, the intro video firing (or falling back, or tap-skipped),
the first-scene `winSize` numbers, music + effect playback, and the
letterboxed centered presentation.

Follow-up list, in order: (1) the first device pass against the
expectations above, then update this document with observed results
(the 30 September section below supersedes the rest of this list);
(2) the guest end-to-end regression test modeled on
`uikit_legacy_native_canvas.m` — **delivered** as
`test/uikit_legacy_declared_universal_canvas.m`; (3) canvas-mode
wiring for the universal population only if a clamped runtime becomes a
real target; (4) the usual `check-symbols`/framework audits on the macOS
side — note these are manual invocations, not part of the nightly
(see the correction above).

## Device feedback iteration 2 — the post-intro crash and the completion wave

The first device build (the CMTime bridge at `7c4e4c6`) fixed the
intro-video gate: the video now presents and plays. The next device run
then crashed shortly after the intro ended, with **no** crash log —
the emulator's crash machinery only reports guest CPU faults, so the
silence itself identified the failure class: a host-side exception
raised during a bridged call, escaping through the unwinder with no
handler anywhere. A five-participant analysis wave located and closed
the concrete causes:

1. **The post-intro crash root cause: legacy Game Center authentication.**
   Two seconds after the menu appears (every launch), the game's menu
   scene dispatches `initGameCenter`, which reaches
   `-[GKLocalPlayer authenticateWithCompletionHandler:]`. The guest
   shim forwarded that selector to the host by name — but modern
   GameKit no longer implements the iOS-5-era method, and the resulting
   unrecognized-selector exception was exactly the silent
   host-exception death. The legacy block wrapper now completes the
   authentication block **guest-locally** with
   `GKErrorDomain`/`GKErrorNotAuthenticated`, matching the documented
   unavailable-authentication contract of the local-player adapter, so
   the game takes its designed "Leaderboards Unavailable" path
   (`GameKit+LC32LegacyBlocks.m`; the other legacy block selectors
   were each verified as still-implemented on the host and keep
   forwarding).
2. **Legacy modal presentation vocabulary restored on the host** at the
   video-completion path: `presentModalViewController:animated:` and
   `dismissModalViewControllerAnimated:` now exist as host
   `UIViewController` category methods with the documented iOS 5
   semantics (forward to the modern API; dismiss is a no-op without a
   live presentation), so the guest stubs' host lookups resolve to
   tolerant implementations instead of whatever the current host
   carries (`UIViewController+LC32LegacyModalPresentation.mm`).
3. **Guest view controllers without `loadView`** could raise "Could not
   load NIB" from the host's lazy loader, which searched the container's
   bundles for a class-name nib. A host `loadView` guard, gated on the
   bridge's guest-class mark, now resolves guest-backed controllers'
   nibs against the identity-mounted guest bundle and falls back to an
   empty programmatic view — the privacy/TOS web pages degrade to a
   dead page instead of crashing the presentation
   (`UIViewController+LC32GuestNibLoading.mm`).
4. **AVFoundation never ran natively before this wave**: the guest
   framework never loaded its host counterpart, and its
   media-characteristic constants carried symbol spellings rather than
   the host's own constant objects — the video's
   `tracksWithMediaCharacteristic:` + unchecked `objectAtIndex:0`
   pair depends on both. The framework constructor now loads host
   AVFoundation and binds the constants to the native objects
   (`AVFoundation.m`), which also un-breaks AVAudioPlayer music.
   AudioToolbox now zeroes the reserved `AudioStreamBasicDescription`
   field at the `ExtAudioFileSetProperty` client-format and
   `AudioFileCreateWithURL` boundaries, where the game's stack-built
   descriptors carry garbage that modern hosts reject
   (`AudioToolbox.mm`).
5. **The fixed-canvas fit learned about modal presentations**: while a
   host presentation container is mounted over the controller-backed
   window (the fullscreen intro video, a web view, a store sheet), the
   fit suspends — the canvas-calibrated transform would scale the
   window-sized container past the screen and crop it — and restores
   the converged transform when the overlay leaves, yielding to any
   foreign sublayer-transform takeover. Growth of a controller-backed
   window also waits for the rotation unit's turn (which sizes the
   root view explicitly), and the drawable record's first arrival
   re-arms the fit (`UIKit.mm`, `LegacyRotation.mm`).
6. **Silent host deaths are eliminated as a class**: the bridge's
   guest-to-host dispatch shield now covers the selector dispatch plus
   seven more host entry points (identity mapping, weak try-retain,
   string ranges, framework loading, host object resolution, the
   class-hook synthesis, notification aliases), converting any host
   exception during a bridged call into the reported crash channel
   with the throw-site stack; a final-net uncaught-exception handler
   covers raises outside the bridge (dispatch blocks) and writes the
   report to stderr plus the process abort reason; async-signal-safe
   SIGSEGV/SIGBUS/SIGABRT handlers record native backtraces for
   host-code faults (`bridge.mm`, new `host_crash_net` unit). Any
   future failure produces evidence.

The same wave also produced a working **non-macOS build**: the guest
side now compiles and links fully on Linux with Theos's bundled
toolchain (classic ARM32 `ld` via `LC32_GUEST_LINKER`, explicit
`-target` triples, `flock` locking), and CI publishes the generated
shim sources as an artifact because the generator itself requires the
macOS runtime. The host side cross-configures on Linux through the
same toolchain selection block, gated so macOS toolchain behavior stays
byte-identical (`build-libiconv.sh`, `HostFrameworks/LC32/Makefile`).

The next device run of that build then **froze during and right after
the intro video** instead of crashing: a hang, which produces no report
by itself. Static re-audit of every new path at the freeze point (the
game's one-shot ExtAudioFile decoders, the Game Center completion
chain — async, no retry — the presentation-suspension fit, the
eager AVFoundation constructor) cleared each candidate of an obvious
blocking bug, so the completion wave's evidence machinery gained its
missing piece: a **main-queue hang watchdog**. The guest main thread
runs on the host main thread, so a stalled guest stalls the host main
queue; a one-second heartbeat timer on that queue only fires while it
drains. When the heartbeat goes stale for forty-five seconds (re-verified
after a grace interval, standing down while the app is backgrounded),
the watchdog halts the JITs, snapshots every guest thread's registers,
registry wait state, and frame chain, symbolicates the frames, prints
the full report to stderr, and terminates with a compact description
installed as the process abort reason — so a freeze now leaves the
same evidence a crash does, and the device's crash log (Settings ->
Privacy & Security -> Analytics Data) carries the stalled PC and wait
state for exact offline symbolication. **(Two limitations found by the
30 September audit, which the runbook below restates: a pre-runloop
stall produces no watchdog report at all, and in native mode the
snapshot prints "no live JIT for this thread" for exactly the guest
main thread — the main registry entry never sets `nativeJit`, so the
main thread's register dump and compact abort line are currently
missing from the report's most important case. Both are host-side,
NEEDS-OWNER, MAC-OS-VERIFY.)**

Expected device behavior after this wave: launch → upright
letterboxed title → intro video (fullscreen, native presentation) →
menu at 2x with the 4-inch layout branch, Game Center reporting its
designed "unavailable" alert instead of crashing, music and effects
playing, touches landing on the centered canvas. If anything still
fails, the process now either shows the guest crash report (guest
faults), the host-bridge report (bridged-call exceptions), or writes
the report to stderr and the OS abort reason (everything else) —
export whichever appears and the next iteration starts from evidence.


## Port-completion wave — 30 September 2026

**Still not device-verified.** Everything in this section is analysis-,
build-, or audit-verified on the macOS-less Linux build box and by
adversarial review of the working tree; nothing has been run on a device,
and no CI workflow has executed any of the new guest tests (the nightly
build has no `gmake -C test` step of any kind — verified by walking
`.github/workflows/nightly.yml`; the host-test workflow runs only the four
pre-existing host checks). Every statement below about runtime behavior is
a prediction until the first device pass lands. The wave's changes sit
uncommitted in the working tree on `zenonia-compat` (9 modified, 17 new
files at HEAD `6692780`, +262/−9 tracked lines plus the new sources), by
design — no commit is made from this analysis pass.

### What the effort was

A five-wave, 25-implementer pass over the full wave-1 behavioral contract
(662 imports / 26 linked dylibs / 615 classes / 4,142 selectors): an
adjudicated gap register, implementer waves 01–25, an adversarial review
wave (18 area reviews), a repair pass on the review's build findings, an
independent critic pass, and this documentation. The app binary remains
untouched; "port" here means completing the guest framework surface and
host bridge behavior, and building the instruments that turn the next
device run into evidence instead of guesswork.

### Corrections to this document (all made in place above)

- **winSize**: the 27 September handoff expected first-scene
  `winSize {568,320}` / `winSizeInPixels {1136,640}`. Adversarially
  upheld analysis proves that wrong: `CCDirectorIOSUniversal
  reshapeProjection:` re-reads the authored `view.bounds` (never
  `UIScreen`), CCGLView is hardcoded {0,0,320,480}, and the
  declared-class adoption rule deliberately leaves an at-or-below-canvas
  authored view untouched. Correct expectation: `winSize {320,480}`,
  `winSizeInPixels {640,960}`, GL backing 640x960 — identical to real
  4-inch hardware. The 568-tall `UIScreen` answer still drives the window
  frame, the 568h launch-art branch, and the ~40 `bounds.height==568`
  HUD/menu position forks (authentic behavior, not a bug to chase).
- **Launch pacing**: the ~3.5 s `playIntroVideo` delay is cocos2d
  CCSequence timer pacing (`CCDelayTime`), not `dispatch_after` — a hang
  before that point is not the video chain.
- **CI claims**: `check-symbols` is a manual macOS invocation, not part of
  the nightly (the earlier text claimed it was).
- **Watchdog**: the "carries the stalled PC and wait state" promise is
  currently false for exactly the guest main thread (see risk 3 below);
  and a pre-runloop stall produces no report at all.

### What the wave verified and fixed

Verified clean (no change needed): CoreGraphics (51/51 imports, struct
ABI sound, PVR data-provider semantics), SystemConfiguration (the
always-reachable verdict is the documented design; the IAP/StoreKit gates
open correctly), CoreMedia/MediaPlayer (CMTime ABI exact; no change),
Security (SecKeyEncrypt stub unreachable via the BlockSize>3 gate),
libSystem remainder + CFNetwork (two-level binding, statfs layout,
ServerTrust chain — all re-derived from primary evidence), the GKScore
crash claim from the gap register's raw audits (REFUTED: `value`/
`setValue:` are auto-synthesized direct guest-ivar accessors —
`0001e802`/`0001e808` in the built framework — so the abort path never
fires).

Fixed (all guest-side unless marked; every fix build-verified on the box,
host units MAC-OS-VERIFY):

- **Declared-universal regression test (REGTEST-01, was P0)** —
  `test/uikit_legacy_declared_universal_canvas.m` +
  `lc32-uikit-legacy-declared-canvas` registration, with the load-bearing
  `-Wl,-sdk_version,7.0` link flag: 19 assertions pinning bounds
  {320,568}, scale 2.0, `winSize` {320,480}/{640,960}, 640x960 backing,
  touch round-trip, and the declared-class geometry gates. Builds to
  Mach-O armv7s PIE; **has never executed anywhere** (no runner exists
  for guest binaries off-device, and CI runs no guest test).
- **mfm symbol audit (ROOTFS-01 instrument half, was P0)** —
  `test/audit_mfm_symbols.sh` behind `gmake -C test check-mfm MFM=…`:
  re-export-aware resolution of all 662 imports across 87 built images
  (457 built-framework resolved, 203 ramdisk-resident across the 5
  RootFS dylibs, **0 missing framework symbols**, exit 0 on the real
  binary; negative tests all exit 1). The pack-ramdisk/CI half of
  ROOTFS-01 remains NO-OWNER: nothing anywhere asserts the packed RootFS
  `usr/lib` contents.
- **GKScore empty score reports (GKSCORE-01)** —
  `GuestFrameworks/GameKit/GKScore+LC32HostValue.m`: category overrides
  the synthesized accessors to forward the int64 (r2/r3) value to the
  host GKScore so `reportScoreWithCompletionHandler:` submits what the
  game set.
- **AVAudioSession interruption (AUD-01/03)** —
  `GuestFrameworks/AVFAudio/AVAudioSessionInterruptionAdapter.m`:
  converts the host AVAudioSessionInterruptionNotification into the
  legacy `beginInterruption`/`endInterruption` delegate calls
  (mfm's only live interruption path) plus player-level resume; swallows
  `setDelegate:` so the host-visible session delegate stays nil by design.
- **UIAlertView on scene-based hosts (UKG-01)** —
  `GuestFrameworks/UIKit/UIAlertView+LC32LegacyAlerts.m`: guest-side
  adapter to UIAlertController. **Two P1 holes survive it** (risk 6).
- **SKPayment legacy identifier vocabulary (N-G2)** —
  `GuestFrameworks/StoreKit/SKPayment+LC32LegacyPayments.m`:
  `paymentWithProductIdentifier:` rebuilt through SKMutablePayment
  guest-locally, tolerating a host without StoreKit loaded.
- **CCB struct encodings (OG-03)** — `NSValue+LC32Bytes.m`: the
  `{_ccColor3B=CCC}`/`{_ccColor4B=CCCC}`/`{_ccColor4F=ffff}`/
  `{_ccBlendFunc=II}` layout entries (NULL-converter verbatim copies), so
  CCBReader color/blend properties set instead of silently rejecting.
- **Uncaught-exception handler forward (C-G2)** — `Foundation.m`
  mirrors the stored guest handler into guest libobjc's
  `objc_setUncaughtExceptionHandler` slot so abort reports can carry the
  exception name/reason. Likely inert for mfm's bridge-raised path (the
  host unwind consults the host slot, already netted) — no regression;
  device checkpoint.
- **Guest-local defaults suite (SAVES-02 fix half)** —
  `CoreFoundation/NSUserDefaults+LC32SuiteDefaults.m`: standard defaults
  route to a per-bundle-id suite (kills cross-title key collisions). **No
  migration exists — the data-wipe half of SAVES-02 stays open** (risk 5).
- **statusBarFrame canvas pairing (UKG-02)** — `UIKit.m` swizzle returns
  the class-consistent frame (zero when hidden, {0,0,320,20} otherwise)
  so CCMenu positioning agrees with the canvas coordinate space.
- **Foreground fit re-arm (LC-01)** — `HostFrameworks/UIKit/UIKit.mm`
  (+44 lines, MAC-OS-VERIFY: never compiled — Linux cannot build the host
  side): `DidBecomeActive` schedules the fit for declared-class windows,
  so a plain resume cannot leave the letterbox mis-fitted.
- **CADisplayLink legacy pacing (LC-05)** —
  `GuestFrameworks/QuartzCore/CADisplayLink+LC32LegacyPacing.m`: caps the
  effective link rate at 60 Hz for interval-1 links on ProMotion hosts so
  fixed-step engines keep their tuning.
- **AVPlayer probe forwarding (V-G3)** —
  `GuestFrameworks/AVFoundation/AVPlayer+LC32HostProbing.m`: forwards
  `respondsToSelector:` to the host peer (so deprecated-but-dropped
  selectors answer honestly). **Over-broad — see risk 8.**
- **AspectFill gravity host bind (V-G4)** — AVFoundation constants:
  `AVLayerVideoGravityResizeAspectFill` bound to the native constant
  object (identity-safe).
- **kCFCoreFoundationVersionNumber** — 1349.7 → 1349.56 (Apple's iOS 10.3
  value; mfm's only reader compares <478.61 either way — zero behavioral
  delta).
- **Guest sysctl/utsname answer table (SYSCTL-01 guest half)** —
  `GuestFrameworks/LC32/LC32GuestSysctlValues.{h,m}`: canonical guest
  answers as data + self-checks, no hook. **The host-side consumers do
  not exist yet** (NEEDS-OWNER ticket); the uts release/version pair is
  internally inconsistent ("16.6.0" vs "…16.7.0…") — align before the
  host ticket consumes the file.

New tests beyond the regression pair (all build to Mach-O armv7s PIE on
this box; all are guest binaries needing the macOS/CI runtime to run):

- `audio_extaudiofile_decode.m` — CocosDenshion one-shot decoder chain
  against a synthesized .caf (open + garbage-reserved-field client ASBD +
  property set + whole-file read). **CAF-only — this is NOT MP3
  coverage**; the menu-jingle MP3 decode path remains device-only.
- `avfoundation_kvo_chain.m` — intro-video chain shapes: asset key load
  failure exits, status/rate/currentItem KVO, CMTime ABI,
  DidPlayToEndTime round trip (posted guest-side; the host→guest relay
  remains ungated). The positive-path fixture
  (`/tmp/mfm100/impl/avplayer_intro_chain.m`, gating `[player play]`)
  **never landed in the repo**.
- `foundation_keyed_archive_roundtrip.m` +
  `nskeyedunarchiver_roundtrip.m` — the SAVES-01 probes (custom-class
  archive→unarchive through the bridge class mirror, save-graph shape,
  first-launch absent-file contract). **These are the instruments that
  decide the crash-after-first-save verdict; both are registered but
  neither has ever executed.** Known fixture weakness: the absent-file
  streaming check self-disarms (nil guard) and no zero-length-file
  corrupt-save case exists.
- `dispatch_concurrency.m` — the launch-critical GCD topology
  (dispatch_once ×13 sites, queue-create, group, sync shapes) — source
  landed at `test/dispatch_concurrency.m` but **unregistered in the
  Makefile** (registration was outside every implementer's ownership
  anchor).
- `uikit_legacy_native_canvas.m` repaired (ES1 `_OES` enum names) — the
  pre-existing model test had never compiled at HEAD.

Test-infra repairs from the review wave: the Apple-clang-only
`-Wno-deprecated-module-dot-map` is host-guarded in `test/Makefile`
(Darwin keeps identical behavior; Linux clang-13 no longer fatal-errors
all nine -Werror guest tests); `check-mfm` added to `.PHONY`; the audit's
PASS banner now prints only on passing runs with a derived missing count
(it previously printed "PASS / missing: 0" even on failures);
`foundation-keyed-archive-roundtrip` registered.

How to run everything (macOS; on Linux only the build works — always
`gmake`, never `make`):

```
export THEOS=/home/kasm-user/theos          # box-specific; on macOS use the real Theos root
gmake -C GuestMakefile generate-shims      # stamp required before guest build
gmake -C GuestMakefile -j8
gmake -C test uikit-legacy-declared-canvas   # the 19-pin regression (REGTEST-01)
gmake -C test check-mfm MFM=/path/to/Payload/mfm.app/mfm
gmake -C test foundation-keyed-archive-roundtrip nskeyedunarchiver-roundtrip
gmake -C test avfoundation-kvo-chain audio-extaudiofile-decode
gmake -C test check-symbols                 # manual, as before
```

Three fixtures remain stranded outside `test/Makefile` or the repo:
`dispatch_concurrency.m` (present in `test/`, no registration line),
`avfaudio_interruption.m` and `avplayer_intro_chain.m` (deposited at
`/tmp/mfm100/impl/`, never landed). **Run the registered guest tests on
macOS before the device pass** — the first device run is currently also
the first-ever execution of the regression test, both persistence probes,
and the KVO chain.

### Final P0/P1/P2 state after review + repair

No P0 code defect was found in any shipped change (adversarial review of
all 25 implementer surfaces: 12 of 18 areas PASS outright, 6 ISSUES; all
fixes traced to the app's actual IDB call sites; ownership discipline
held — zero `.generated/` edits, zero Zenonia-path changes, zero build
convention changes, zero commits). What remains:

**P0-class (both are "instrument exists, verdict pending," not code
defects):**

- **SAVES-01 verdict undecided**: whether the second launch after a save
  crashes in `-[AppDelegate init]` (host NSKeyedUnarchiver resolving
  `$classname GameSaveState` through the bridge's objc_getClass hook)
  rides entirely on the two registered-but-never-executed roundtrip
  probes above.
- **ROOTFS-01 pack half unasserted**: no script or CI step asserts the
  packed RootFS `usr/lib` set (`libz.1`, `libsqlite3` — existence-only,
  no guest build rule — plus libobjc.A, libstdc++.6, libSystem.B,
  libgcc_s.1, dyld). The audit script covers the symbol-drift half only,
  and no CI step invokes even that.

**P1 (open):** SAVES-02 upgrade data-wipe (no defaults migration);
UIAlertView present-during-dismissal loss and off-main `-show` weak-hop
loss; AVPlayer blanket probe override (two wrong-answer modes); the
unlanded/unregistered fixtures above; no CI invocation for any guest test;
G08-08 main-thread watchdog snapshot defect + LC-02 pre-runloop dead zone
(both host, NEEDS-OWNER); UNAME-01 (no SYS_uname case → uninitialized
utsname; host ticket with the data file ready); G08-04 latent semaphore
parking (unreachable for mfm).

**P2 (representative):** the sysctl data-file 16.6.0/16.7.0 pair; the
GKScore category has no CI pin; StoreKit Restore shows a wrong
parental-controls message (the only live Restore caller);
`lc32-corefoundation-string-transform` link failure and two sibling test
defects (pre-existing at HEAD, verified by stash); the KVO test's
`alarm(60)` is beatable on a slow runner; C-G2 effectiveness and OG-04
(host-mirror KVC struct ivars) are device checkpoints.

**Recorded contracts (deliberate, not to be "fixed" for this app):**
host-raised ObjC exceptions in bridged calls convert to **fatal crash
reports** by design (EH-01's cheapest option was taken; the app's 186
objc-personality catch frames in Crittercism/Chartboost/CBJson do not
unwind — one malformed-JSON response that the real device would have
caught now aborts); PLCrashReporter's signal handlers are recorded and
never delivered — **a missing .plcrash file is the designed contract**
(LiveExec32's own crash net is the reporter); sigaction is recorded but
guest signals are never delivered; `UIDevice.systemVersion` answers the
host version (all 17 app gates are `>=` floors, none can flip);
`uniqueIdentifier` answers a guest UUID; the CoreTelephony carrier probe
returns `(null)`.

### Top-10 device-pass risks (independently re-ranked; use this list)

1. **Post-intro/title freeze with a registerless report** — the only
   previously observed device failure (V-G2), cause never diagnosed; the
   positive path (`[player play]` → ReadyToPlay KVO → end notification)
   has zero executed coverage anywhere; the tap-skip exit routes through
   the un-fixtured fit hit-test; and when the watchdog fires its snapshot
   prints "no live JIT for this thread" for exactly the stalled main
   thread (G08-08) — plus a pre-runloop stall produces no report at all
   (LC-02).
2. **Instant dyld abort on a ramdisk packing regression** — 203 imports
   bind to the 5 RootFS residents, asserted nowhere; a missing libz.1
   instead aborts at the first `.pvr.ccz` load (black screen then crash);
   libsqlite3 is existence-only with no build rule and no audit naming it.
3. **Cold-launch geometry cluster** — the deciding regression test has
   never executed; the host foreground re-arm (+44 lines) has never been
   compiled; the contentScaleFactor *write* path and the fit inverse
   hit-test are bypassed/uncovered, so a wrong backing or offset touches
   would pass every test while failing on device.
4. **SAVES-01** — crash-on-every-launch-after-first-save remains
   formally undecided; it would brick the install and, to the user, look
   identical to risk 2.
5. **SAVES-02 data wipe** — an upgraded install silently resets
   `firstRun`/`firstRunCoins`/`IAProductPurchased-*` (IAP gates re-lock);
   unguarded suite creation can crash the very first
   `standardUserDefaults` call if a host ever throws.
6. **UIAlertView adapter holes** — the IAP error alert is lost when it
   lands one frame after the spinner dismissal; the Crittercism
   "Message from Developer"/rate alert never appears (off-main
   `-show` + weak capture).
7. **Audio chain** — the interruption adapter (the wave's only audio
   behavior change) has no landed gating test; a real interruption
   suspending/restoring music+effects is device-only; MP3 jingle decode
   is not covered by the landed CAF test; `prepareToPlay` stall is
   covered only by the degraded watchdog.
8. **AVPlayer blanket probe override** — pre-bind probes
   (host_self==0) answer NO for everything; guest-implemented /
   host-dropped selectors answer NO; class-wide on a hot NSObject surface
   with zero gating.
9. **Exception evidence cluster** — host-raised exceptions are fatal by
   contract and the report may lack the NSException name/reason; the
   guest uncaught-handler mirror is likely inert; Crittercism's first
   exercise under the JIT is unobserved and a stall there is in the
   no-report dead zone.
10. **comScore host-side effects** — SecItemDelete+SecItemAdd against
    the real HOST login keychain recurs **every cold start, forever**
    (not "until cached" as earlier analyses said — the stubbed
    SecKeyGetBlockSize forces re-encryption nil every launch); possible
    first-launch keychain prompt; UNAME-01's uninitialized utsname feeds
    `stringWithCString:` a garbage-length walk that can `abort()` (bounded
    lottery).

Cross-cutting amplifier: **gating debt.** Nine of the wave's 13
behavior-changing fixes have no test; the deciding instruments for the
three biggest verdicts (SAVES-01, geometry, the video chain) are built
and never executed. Any regression in the wave's fixes ships silently.

### Device-pass runbook (supersedes the 27 September handoff flow)

**macOS pre-flight** (every step below is MAC-OS-VERIFY; the Linux box
cannot run any of it):

1. `git submodule update --init --recursive`, then build in the fixed
   order: `gmake`; `gmake -C GuestMakefile generate-shims`;
   `gmake -C GuestMakefile`; `bash GuestMakefile/pack-ramdisk.sh`;
   `gmake package`. Re-run `pack-ramdisk.sh` after **any** guest framework
   change (this wave changed several — the packed ramdisk must contain
   the rebuilt frameworks). Frozen conventions unchanged:
   `FINALPACKAGE=1 STRIP=0 OPTFLAG=-O2 GO_EASY_ON_ME=1 TARGET_CODESIGN=`.
   Also: **rebuild the guest obj dir before packing if in doubt** — a
   stale binary was caught in review (the built Foundation predated a
   wave fix until a critic rebuilt it).
2. **Manual RootFS content check** (nothing asserts it; run it):
   `for lib in libz.1.dylib libsqlite3.dylib libobjc.A.dylib
   libstdc++.6.dylib libSystem.B.dylib libgcc_s.1.dylib libiconv.2.dylib;
   do test -f Resources/RootFS/usr/lib/$lib || echo MISSING: $lib; done`;
   plus `test -f Resources/RootFS/usr/lib/dyld`, the
   `LC32.framework/LC32` native-thread marker under
   `System/Library/Frameworks`, and the three existence-only framework
   bundles (CoreLocation, MobileCoreServices, CoreData).
3. **Run the guest tests before the pass** (see the command block above)
   — this is the first execution of the regression test, both
   persistence probes, and the KVO chain. If `dispatch_concurrency.m`'s
   registration line is added first, run it too.
4. Optional audits: `gmake -C test check-mfm MFM=…`,
   `check-uikit-legacy-canvas-fit`,
   `check-uikit-legacy-statusbar-orientation`, `check-symbols`.
5. Confirm the imported mfm IPA is stock (armv7-only slice, no arm64
   shim inside the bundle).

**LiveContainer import**: nightly IPA in → LiveExec32 default app →
import the mfm IPA → configure per-app settings **before the first
launch** (the SDK gates are once-per-launch static locals) → launch.

**Launch configuration:**

- `spoofSDKVersion`: **leave unclamped** (LiveContainer's 2.0* fallback).
  An 8+/11.0 clamp = canvas mode = the declared-universal class
  intentionally does nothing → scene-sized ~440x956 bounds, scale 3,
  mispositioned HUD, no letterbox. This is the single most likely
  accidental failure; detection is the geometry table below.
- `LCOrientationLock`: off for the primary pass (on only as an A/B
  diagnostic).
- Classic Mode: on (the device class the Zenonia passes used).
- Env: `LC32_DISABLE_UIKIT_COMPATIBILITY` must NOT be set;
  `NATIVE_GUEST_THREADS` must be left unset entirely (explicit `=0`
  silently disables native guest threads and breaks mfm's GCD contract);
  `SIMULATOR_UDID`/`SIMULATOR_DEVICE_NAME` absent (their presence
  triggers the silent-OpenAL fallback); on the deb route only,
  `LC32_PRESERVE_GUEST_SDK=1` (the default; `=0` behaves like an SDK-11
  clamp). **Never debug mfm in cooperative mode** — condition waits
  return ETIMEDOUT and the workqueue serializes; any stall there is
  expected mode behavior, not a game bug.
- Forwards: `LC32_GUEST_ENV_NSUnbufferedIO=YES` on every pass (reports
  land unbuffered); `LC32_GUEST_ENV_DYLD_PRINT_SEGMENTS=1` for one cold
  launch only (all 26 dylibs binding), then remove. The watchdog
  threshold is fixed at 45 s, compile-time, no env override — the ~40 s
  intro video on a slow device could approach it (grace + background
  stand-down mitigate; a watchdog hit with the video playing is a
  threshold artifact, not a hang).

**What to watch, in launch order**: (1) the startup line — confirm the
build is at/beyond `6692780` plus this wave's changes; (2) all 26 dylibs
bind, no "Library not loaded"; (3) `LC32: enabling native guest threads
for shim frameworks` present (its absence means the RootFS is missing the
LC32 marker or someone set NATIVE_GUEST_THREADS); (4) cold-launch
geometry per the table below; (5) Crittercism init completing
(NSLog-and-continue internal failures benign; expect repeated
`LC32: cannot relay foreign-thread guest callback -[SDURLCache
cachedResponseForRequest:]: <reason>` lines — the designed foreign-thread
drop, note the `: <reason>` suffix when grepping; expect one
"unimplemented Darwin syscall"-class line while the uname host ticket is
open); (6) the first `standardUserDefaults` call
(`-[AppDelegate detectLanguage]`) does not crash — the highest-priority
SAVES checkpoint; (7) title scene → ~100 ms initIAP + title → **~3.5 s**
(CCSequence, not dispatch_after) `playIntroVideo` → 2 s after the menu,
`initGameCenter`; (8) intro video ~40 s, fullscreen, aspect-fill; **if
the video stalls, tap first**, then debug AVFoundation; (9) the
post-video transition — the previously-observed freeze shape: modal
dismiss, fit restore, GameMenuScene replaceScene — if it freezes, export
the watchdog report before touching anything; (10) menu at 2x, 4-inch
layout branch, Game Center "Leaderboards Unavailable" alert; StoreKit
products request always fires and fails app-side; Restore shows the
wrong parental-controls warning (known, don't chase); (11) audio: menu
loop, effects, the MP3 jingle — a silent game is tolerated, a missing
jingle is an MP3 decode issue; (12) letterboxed centered presentation
(568x320 pt, 1136x640 px at the clamped 2x), touches landing on the
centered canvas; (13) background/foreground: the letterbox must stay
fitted after a plain resume (the new re-arm).

**Expected geometry (corrected contract):** `UIScreen.bounds`
{0,0,320,568} portrait-ordered (tall art), `scale` 2.0 (clamped),
`applicationFrame` {0,0,320,568} (hidden status bar), `statusBarFrame`
{0,0,0,0} (or {0,0,320,20} if visible), **`winSize` {320,480},
`winSizeInPixels` {640,960}, GL backing 640x960**, window frame and HUD
forks 568-class. Contingencies (escalate, never ad-hoc patch): observed
`renderer.bounds {0,0,320,568}` + 640x1136 backing → the
at-or-below-canvas adoption rule starved; observed `winSize {568,320}`
→ the old handoff model won, the adoption+freeze+turn-wait triad needs
re-audit; 640x960 backing but HUD mispositioned → the 568 forks are
authentic, look elsewhere first (e.g. the statusBarFrame offset).
Canvas-mode detection: scene-sized ~440x956 bounds, unclamped scale 3,
no letterbox → remove the spoofSDKVersion clamp and relaunch.

**Expected audio:** 6 AVAudioPlayer mp3s; 168 .caf effects +
`music_intro.mp3` + `sfx_ending.mp3` through ExtAudioFile (the landed
decode test is CAF-only — the MP3 jingle is device-only evidence);
`alcOpenDevice(NULL)` non-NULL; `alcGetProcAddress` for
`alcMacOSXMixerOutputRate` returning NULL is correct (cached, never
called); SoloAmbient/Ambient category by string value; a real
interruption (call/Siri) suspends and restores both effects and music —
**this is the unproven behavior the new adapter exists to deliver**.
Tolerated failures: silent effects, missing BGM — never a crash.

**Expected video:** fullscreen native aspect-fill `VideoPlayerView`
modal, ~40 s, then `VideoCompleted` → `firstRealScene`; watchdog silent
throughout (the cocos display link is paused, not the main queue);
built-in exits on asset-Failed / `isPlayable` NO / raw tap.

**Expected Crittercism:** init completes; `hw.machine`/`hw.cputype` show
Mac/arm64 host answers in dead-service metadata until the sysctl/uname
host ticket lands (cosmetic); dyld add/remove-image callbacks fire for
all ~25 images; **a missing .plcrash file is the designed contract**
(PLCrashReporter records, never delivers); the known
`LC32GuestSysctlValues.h` 16.6.0/16.7.0 pair inconsistency should be
aligned before the host ticket consumes it.

**Exporting the report — whichever channel fires:**

- *Guest crash report* (guest CPU faults): printed to **stderr** —
  capture the whole launch's syslog (Console.app / `idevicesyslog` /
  LiveContainer log collection, with NSUnbufferedIO set) and pull the
  matching OS crash log from Settings → Privacy & Security → Analytics
  Data.
- *Host-bridge report* (exceptions raised in host code during a bridged
  call): the dispatch shield converts to the reported crash channel with
  the throw-site stack, to stderr; the final-net handler covers raises
  outside the bridge and additionally writes the process abort reason.
- *Watchdog freeze report* (stalled main thread): after 45 s (grace
  re-verify, background stand-down) — stderr + abort reason. **Read it
  with two known limitations**: a pre-runloop stall (Crittercism
  mod_init, AppDelegate init/save unarchive) produces **no report at
  all** — absence of a report is not proof the main thread was healthy;
  and the snapshot prints "no live JIT for this thread" for the guest
  main thread, so the stalled thread's own registers/PC may be missing —
  the wait-kind list and abort reason still carry information. The
  report's triage tree: PC in asset-load / never reached `playIntroVideo`
  → the chain never fired (bridge/Foundation); stuck with the video
  presented → the end notification was lost (alias machinery, host);
  stuck at the title, video never presented → the status KVO is dead;
  snapshot in the fit/hit-test path → geometry owner; no watchdog at all
  → pre-runloop dead zone (LC-02), not the video chain.

**Save/defaults notes:** prefer a **fresh install** — on an existing
install the suite move silently resets `firstRun`/`firstRunCoins`/
`IAProductPurchased-*` (record it as the known SAVES-02 reset, not a
game bug), or wipe the app's container Preferences first. The first save
(`GumballSaveState.dat`) is unarchived in `-init` at every subsequent
launch — a crash there is the SAVES-01 verdict surfacing; export the
guest crash report. On non-LiveContainer routes, saves may land in the
process-owner's container (`/var/mobile` fallback) — verify before
comparing.

**Known-benign, do not chase as new bugs:** the SDURLCache
foreign-thread relay drops; the "unimplemented Darwin syscall" uname
line; ad-SDK NSLog noise and dead 2013-endpoint failures; the guest
UUID for `uniqueIdentifier`; host-version `systemVersion`;
`(null)` carrier label; the Game Center unavailable alert; StoreKit
products firing and failing app-side; Restore's parental-controls
warning; a missing Crittercism rate/message alert (known open P1 — an
absent alert there is a defect, not a new finding); Chartboost prefetch
slowness (correct throttling); a slow-device watchdog hit with the video
playing.

**Pass criteria** (one cold launch + one resume cycle): startup line ≥
`6692780` + this wave; 26 dylibs bind; native-threads line present;
geometry per the corrected table; Crittercism init completes; the intro
plays or built-in-exits with the watchdog silent; letterboxed-centered
2x menu with the 4-inch branch; Game Center unavailable alert; music and
effects audible; touches land on the centered canvas; resume keeps the
letterbox fitted; and any failure along the way produced one of the
three exportable reports. Record observed values in this document,
replacing the predictions above.
