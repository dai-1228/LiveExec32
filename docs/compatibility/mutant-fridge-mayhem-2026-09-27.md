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
superseded and are not claimed as evidence. Device verification, and the
guest end-to-end regression test that would make the controller-backed
fit path CI-checkable, remain open (see Verification and Handoff).

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
- **GCD-paced launch**: `dispatch_after` chains didFinishLaunching →
  (100 ms) initIAP + title scene → (~3.5 s) `playIntroVideo` → (2 s)
  `initGameCenter`; texture loading uses `dispatch_sync`/`dispatch_async`
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
- `make -C test check-symbols` and the guest framework link run on the
  macOS CI side as usual; the guest end-to-end regression test for this
  class (modeled on `test/uikit_legacy_native_canvas.m`, with
  `UIDeviceFamily [1,2]`, plist landscape keys, 4-inch launch art, a
  `rootViewController`-wrapped renderer, and no runtime status-bar call)
  is deliberately **not** in this commit — it needs Theos + the guest SDK
  + built frameworks, and is the recommended first follow-up.

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
9. **Expected `winSize` {568,320}** on the 4-inch-art canvas: if the game
   instead reads 480-tall geometry, the tall-art detection path is the
   first thing to re-check.

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
rotation). Before the first launch, on the macOS build host, confirm the
RootFS check in risk 6. Expected geometry on the 4-inch-art canvas:
`UIScreen.bounds` {0,0,320,568} portrait-ordered, `scale` 2.0,
`applicationFrame` {0,0,320,568} (plist-hidden status bar), `winSize`
{568,320} / `winSizeInPixels` {1136,640}; expected presentation: the
320x568 portrait canvas turned to landscape (568x320 points, 1136x640
pixels at the clamped 2x) MIN-scaled onto the live viewport, centered
with letterbox bars — on a ~2.4:1 Classic-Mode viewport the 16:9-class
content fills the screen height with side bars, the same binding the
device-verified Zenonia canvas produced. Watch: dyld messages, Crittercism
init completing, the intro video firing (or falling back, or tap-skipped),
the first-scene `winSize` numbers, music + effect playback, and the
letterboxed centered presentation.

Follow-up list, in order: (1) the first device pass against the
expectations above, then update this document with observed results;
(2) the guest end-to-end regression test modeled on
`uikit_legacy_native_canvas.m` (needs Theos + guest frameworks on macOS)
to make the controller-backed fit path CI-checkable; (3) canvas-mode
wiring for the universal population only if a clamped runtime becomes a
real target; (4) the usual `check-symbols`/framework audits on the macOS
side, which are already part of the nightly build.

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
state for exact offline symbolication.

Expected device behavior after this wave: launch → upright
letterboxed title → intro video (fullscreen, native presentation) →
menu at 2x with the 4-inch layout branch, Game Center reporting its
designed "unavailable" alert instead of crashing, music and effects
playing, touches landing on the centered canvas. If anything still
fails, the process now either shows the guest crash report (guest
faults), the host-bridge report (bridged-call exceptions), or writes
the report to stderr and the OS abort reason (everything else) —
export whichever appears and the next iteration starts from evidence.

