# AGENTS.md

## Build prerequisites (macOS only)

Requires Xcode CLI, Theos (`$THEOS` must point at commit `5280bd0` per CI), CMake, Boost >=1.57, `ldid`, `pzb`, Python 3, `hdiutil`, `rsync`, `gmake` (GNU Make 4+). Plain `make` will fail / serialize incorrectly. Theos needs `iPhoneOS16.5.sdk` in `$THEOS/sdks`; guest builds fetch `iPhoneOS10.3.sdk` separately (see below).

```bash
git submodule update --init --recursive   # External/dynarmic, External/mini-gdbstub
```

## Build order — do not reorder

1. `gmake` — host app + `HostFrameworks/LC32` (`LiveExec32Shared.framework`). Auto-configures Dynarmic via CMake (`External/dynarmic` → `.theos/obj/dynarmic`, cross-compile `arm64`, `RelWithDebInfo`, `-DDYNARMIC_FRONTENDS=A32`) and `External/mini-gdbstub` (`ARCH=rv32`). Static libs: `libdynarmic.a`, `libmcl.a`, `libfmt.a`.
2. `gmake -C GuestMakefile generate-shims` — builds `Generator/GenerateShimAPI/GenerateShimObjC` then runs it with `Generator/templates/generated.plist` + `generated-framework-map.plist` `--runtime-uikit` → atomically replaces `GuestFrameworks/.generated/` (stamp `.complete`). Subsequent guest builds error if stamp missing.
3. `gmake -C GuestMakefile` — guest frameworks (`ARCHS=armv7s`, `TARGET=iphone:clang:16.5:10.3`). Honors jobserver `-jN`; ordering: `LC32` first, `Foundation` after `CoreFoundation`+`CFNetwork`, `AVFoundation` after `AVFAudio`.
4. `bash GuestMakefile/pack-ramdisk.sh` — populates `Resources/RootFS` (gitignored) from iOS 10.3.3 IPSW `058-75249-062.dmg` via `pzb` + `extract-img3.py` + `hdiutil` + `rsync -aH` (7z breaks HFS hardlinks). Must rebuild after guest framework changes.
5. `gmake package` (default `PACKAGE_FORMAT=ipa`) or `gmake package PACKAGE_FORMAT=deb THEOS_PACKAGE_SCHEME=rootless` — embeds `LiveExec32Shared.framework` + `LC32HelpUI.framework` from `HostFrameworks/*/ .theos/obj/`, signs with `ldid`, strips `.DS_Store` via `Scripts/dm-clean.sh`.

Optional: `gmake LC32_BUILD_CATALYST=1` — rewrites binaries with `vtool -set-build-version 6 11.0` for local macOS launch; revert with plain `gmake`. `gmake -C GuestMakefile sdk` prefetches guest SDK without building.

## Guest SDK & module cache

- Guest SDK `tmp/iPhoneOS10.3.sdk` auto-downloaded from `github.com/okanon/iPhoneOS.sdk` to `tmp/iPhoneOS10.3.sdk.tar.gz`, SHA256 `fcbbd539…1ceb80`, verified + extracted atomically with `lockf`. Override with `ISYSROOT=/path/to/sdk` (skips download) or `LC32_GUEST_SDK_URL` + `LC32_GUEST_SDK_SHA256` together. See `GuestMakefile/guest-sdk.mk:1` and `GuestMakefile/setup-sdk.sh:1`.
- Theos SDK `iPhoneOS16.5.sdk` (`5e0fd3f0…202fb`) stays in `$THEOS/sdks` — do not confuse.
- Clang module cache at `.theos/module-cache` (`module-cache.mk:6`, `CLANG_MODULE_CACHE_PATH`). Guest frameworks share MRC/ARC PCMs via `-fmodules-ignore-macro=THEOS_INSTANCE_NAME`; debug only with `LC32_SHARE_GUEST_MODULE_CACHE=0`. Do not delete cache mid-build under parallel `gmake`.

## RootFS quirks

- `Resources/RootFS` and `tmp/` gitignored. First `pack-ramdisk.sh` caches IPSW under `tmp/ipsw/` (CI key `lc32-ramdisk-v1-3564d…`). Overrides: `RAMDISK_IPSW_URL`, `RAMDISK_IPSW_COMPONENT_SHA256`, `RAMDISK_IMAGE_SHA256`, `RAMDISK_SETUP_DIR`, `RAMDISK_ROOT`, `IOS_SYSTEM_ROOT`, `FRAMEWORK_INFO_ROOT` (`GuestMakefile/FrameworkInfoPlists/` holds bundle `Info.plist` snapshots).
- Env isolation: host env not passed to guest. Use `LC32_GUEST_ENV_<NAME>=value` (launcher strips prefix). Cannot override `HOME`, `LC32_OBJC_TRACE`, `NATIVE_GUEST_THREADS`, `DYLD_SHARED_REGION`. `DYLD_PRINT_*` disabled by default — enable via `LC32_GUEST_ENV_DYLD_PRINT_SEGMENTS=1`.

## Code layout

- `HostFrameworks/LC32/` — emulator core (`dynarmic*.cpp`, `bridge.mm`/`block_bridge.mm`/`bridge.s`, `guest_bootstrap.cpp`, `filesystem.cpp`, `debugger_server.cpp`). `LiveExec32Shared.framework` re-exports via `HostFrameworks/*/Foundation.mm` etc. Entry `App/main.c:1`.
- `GuestFrameworks/<Framework>/` — hand-written shims (tracked). `GuestFrameworks/.generated/<Framework>/` — generated forwarding shims (ignored, `// Generated file` marker). Generator sources: `Generator/GenerateShimAPI/main.m`, `Generator/templates/`.
- `GuestLibraries/libiconv/` — guest `libiconv.2.dylib` (installs to `/usr/lib` in RootFS).
- `Tweak/` — `LiveExec32Injector` (deb only, `Tweak.x`, `FatMachO.c`, `AdHocSigner.c`). `include/LC32*ABI.h` — bridge ABIs.
- `ObjCProxy.md:1` explains dual-runtime proxy model.

## Tests

Host-only (no Theos/SDK needed, macOS `xcrun`):
```bash
make -C test check-guest-bootstrap   # guest_bootstrap_host.cpp + HostFrameworks/LC32/guest_bootstrap.cpp
make -C test check-memory-hash       # guest_memory_hash_host.cpp (khash.h)
```

Guest (requires Theos + guest SDK + built frameworks in `GuestMakefile/.theos/obj/armv7s`):
```bash
make -C test                         # all ~90 tools → /private/tmp/lc32-*
make -C test vm-copy                 # single test; lc32- prefix optional
make -C test abi audio corefoundation graphics threading uikit
make -C test check-symbols           # audits OpenAL/OpenGLES/Security/CoreText symbol coverage
make -C test check-messenger MESSENGER=/path/to/Messenger.app/Messenger [ROOTFS=/path/to/RootFS]
make -C test clean-outputs           # only /private/tmp copies; test/.theos via Theos clean
```

Tweak helper:
```bash
make -C Tweak test   # FatMachO/AdHocSigner on macOS (CoreFoundation+Security)
```

## Packaging & CI gotchas

- IPA build does `rm -f packages/*.ipa` before `zip -u` would retain stale `libdynarmic.dylib` entries (`Makefile:116`).
- `Tweak` subproject appended only for `PACKAGE_FORMAT=deb` (`Makefile:125`).
- CI (`.github/workflows/nightly.yml:1`) runs `macos-26`, installs `make boost ldid`, pinned Theos `5280bd0`, builds deb `rootless` then `ipa`, uploads both.
- `FINALPACKAGE=1`, `STRIP=0`, `OPTFLAG=-O2`, `GO_EASY_ON_ME=1` throughout — do not change; `TARGET_CODESIGN=` is intentional (signing deferred to `ldid -S`/`ldid -Sentitlements.plist`).

## Conventions to preserve

- Always `gmake`, never `make`.
- Never commit `GuestFrameworks/.generated/` or `Resources/RootFS`; never edit generated `// Generated file` sources — fix `Generator/templates/` or hand-written adapters.
- Framework `Info.plist` tracked under `GuestMakefile/FrameworkInfoPlists/` — keep in sync when adding frameworks.
- Guest tests use `-isysroot $(ISYSROOT) -fno-autolink -F$(GUEST_FRAMEWORK_DIR)`; per-file `-fobjc-arc`/`-fno-objc-arc`/`-fblocks` flags in `test/Makefile:178` are intentional.
