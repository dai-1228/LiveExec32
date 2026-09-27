#!/bin/sh
# Opt-in native Simulator SDK/language matrix. Does not boot devices or touch
# unrelated apps. --build-only preserves signed bundles without running them.
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
device=booted
build_only=0
keep=0
run_timeout=${LC32_FONT_TEST_TIMEOUT:-30}
while [ "$#" -gt 0 ]; do
    case "$1" in
        --device) [ "$#" -ge 2 ] || exit 2; device=$2; shift 2 ;;
        --build-only) build_only=1; keep=1; shift ;;
        --keep) keep=1; shift ;;
        *) echo "usage: $0 [--device UDID] [--build-only] [--keep]" >&2; exit 2 ;;
    esac
done
case "$run_timeout" in ''|*[!0-9]*) echo "invalid timeout" >&2; exit 2 ;; esac
[ "$run_timeout" -ge 1 ] && [ "$run_timeout" -le 60 ] || exit 2
test -f "$repo_root/HostFrameworks/UIKit/LegacyFonts.mm"
temp_base=$(CDPATH= cd -- "${TMPDIR:-/tmp}" && pwd -P)
workdir=$(mktemp -d "$temp_base/lc32-font-test.XXXXXX")
run_id=$(basename "$workdir" | tr -cd '[:alnum:]')
installed_bundle=
matrix_failed=0
bounded() { perl -e 'alarm shift; exec @ARGV; die "exec: $!\n"' "$@"; }
cleanup() {
    result=$?
    trap - EXIT INT TERM
    if [ -n "$installed_bundle" ]; then
        bounded 10 xcrun simctl terminate "$device" "$installed_bundle" >/dev/null 2>&1 || :
        bounded 10 xcrun simctl uninstall "$device" "$installed_bundle" >/dev/null 2>&1 || :
    fi
    if [ "$keep" -eq 1 ] || [ "$result" -ne 0 ]; then
        echo "Font test artifacts: $workdir"
    else
        case "$workdir" in "$temp_base"/lc32-font-test.*) rm -rf -- "$workdir" ;; esac
    fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

sdk_root=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun --sdk iphonesimulator clang -target arm64-apple-ios15.0-simulator \
    -isysroot "$sdk_root" -fobjc-arc -g -O0 -Wall -Wextra \
    -Wl,-headerpad,0x1000 -framework UIKit -framework Foundation \
    -framework CoreGraphics -framework CoreText -lc++ \
    "$repo_root/test/uikit_legacy_font_metrics.m" \
    "$repo_root/HostFrameworks/UIKit/LegacyFonts.mm" \
    "$repo_root/HostFrameworks/UIKit/LegacyAlerts.mm" \
    "$repo_root/HostFrameworks/UIKit/LegacyAutoLayout.mm" -o "$workdir/test"

for sdk in 0 7 10 11; do
    app="$workdir/sdk$sdk.app"
    bundle="org.liveexec32.test.fontmetrics.$run_id.sdk$sdk"
    mkdir "$app"
    plist="$app/Info.plist"
    plutil -create xml1 "$plist"
    plutil -insert CFBundleExecutable -string FontMetrics "$plist"
    plutil -insert CFBundleIdentifier -string "$bundle" "$plist"
    plutil -insert CFBundleName -string "Font SDK$sdk" "$plist"
    plutil -insert CFBundlePackageType -string APPL "$plist"
    plutil -insert CFBundleVersion -string 1 "$plist"
    plutil -insert CFBundleShortVersionString -string 1.0 "$plist"
    plutil -insert MinimumOSVersion -string 15.0 "$plist"
    plutil -insert LSRequiresIPhoneOS -bool YES "$plist"
    plutil -insert UIDeviceFamily -json '[1,2]' "$plist"
    plutil -insert CFBundleSupportedPlatforms -json '["iPhoneSimulator"]' "$plist"
    plutil -insert CFBundleDevelopmentRegion -string en "$plist"
    plutil -insert CFBundleLocalizations -json '["en","vi"]' "$plist"
    plutil -insert UIInterfaceOrientation -string UIInterfaceOrientationLandscapeRight "$plist"
    plutil -insert UISupportedInterfaceOrientations -json '["UIInterfaceOrientationLandscapeLeft","UIInterfaceOrientationLandscapeRight"]' "$plist"
    plutil -insert LC32ExpectedSDK -integer "$((sdk * 65536))" "$plist"
    xcrun vtool -set-build-version 7 15.0 "$sdk.0" -replace \
        -output "$app/FontMetrics" "$workdir/test"
    codesign --force --sign - "$app" >/dev/null 2>&1
    codesign --verify --strict "$app"
    echo "Built $app ($bundle), SDK $sdk.0 / minOS15.0"
    [ "$build_only" -eq 0 ] || continue

    installed_bundle=$bundle
    bounded "$run_timeout" xcrun simctl install "$device" "$app"
    for language in en vi; do
        case "$language" in en) languages='(en,vi)'; locale=en_US ;; vi) languages='(vi,en)'; locale=vi_VN ;; esac
        # Isolate each layout case, then run eight mixed animated/nonanimated
        # presentation/dismissal cycles in one process to check native cleanup.
        for test_case in plain text untitled titled repeat; do
            alert_case=$test_case
            repeat_alerts=NO
            if [ "$test_case" = repeat ]; then alert_case=plain; repeat_alerts=YES; fi
            log="$workdir/sdk$sdk-$language-$test_case.log"
            status=0
            bounded "$run_timeout" xcrun simctl launch --console "$device" "$bundle" \
                -AppleLanguages "$languages" -AppleLocale "$locale" \
                -LC32ExpectedLanguage "$language" -LC32AlertCase "$alert_case" \
                -LC32RepeatAlerts "$repeat_alerts" \
                >"$log" 2>&1 || status=$?
            echo "Font test launch SDK$sdk/$language/$test_case status=$status"
            sed -n '1,160p' "$log"
            bounded 10 xcrun simctl terminate "$device" "$bundle" >/dev/null 2>&1 || :
            if [ "$status" -ne 0 ] || ! grep -q 'legacy-font-regression: PASS' "$log"; then
                matrix_failed=1
            fi
        done
    done
    bounded 10 xcrun simctl uninstall "$device" "$bundle"
    installed_bundle=
done
exit "$matrix_failed"
