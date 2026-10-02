#!/bin/sh
# mfm (Mutant Fridge Mayhem 4.1.1, armv7) undefined-symbol audit.
#
# Extracts every undefined symbol from the app's armv7 Mach-O (the union of
# its bind / lazy_bind / weak_bind tables) and resolves each against the
# built guest world:
#
#   * exports of every GuestMakefile/.theos/obj/armv7s/*.framework image,
#     following LC_REEXPORT_DYLIB chains via otool -l, so reexported
#     symbols resolve (NSURLConnection binds nominally against Foundation
#     but is a CFNetwork reexport; AVAudioPlayer binds against AVFoundation
#     but lives in AVFAudio);
#   * the RootFS-resident dylib set (libz.1 / libobjc.A / libstdc++.6 /
#     libSystem.B / libgcc_s.1), which is not built here: it ships inside
#     the iOS 10.3.3 restore ramdisk that pack-ramdisk.sh (macOS/CI only)
#     copies into Resources/RootFS.  Imports bound to those five are
#     annotated MAC-OS-VERIFY instead of being resolved against a built
#     image; CI on macOS must confirm they exist in the packed RootFS.
#     Their symbol sets are cross-checked against the guest SDK .tbd stubs
#     so a symbol the 10.3 SDK does not even know is still reported.
#
# Weak imports (LC_LOAD_WEAK_DYLIB: AdSupport, Foundation) are audited like
# strong ones: LiveExec32 builds both images, so every weak reference must
# resolve.  Weak-bound symbols (weak_bind table, no nominal dylib) are
# resolved against every provider, ramdisk set included.
#
# Any unresolved framework symbol fails with a sorted missing list.
#
# Modeled on audit_openal_symbols.sh + messenger_eager_symbols.sh.
# Usage: gmake -C test check-mfm MFM=/path/to/mfm.app/mfm

set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)
MFM=${MFM:-${1:-}}
GUEST_OBJ_DIR=${GUEST_OBJ_DIR:-${2:-"$REPO_ROOT/GuestMakefile/.theos/obj/armv7s"}}
SDKROOT=${SDKROOT:-"$REPO_ROOT/tmp/iPhoneOS10.3.sdk"}

# The five ramdisk-resident dylibs: short bind-table name -> install stem.
RAMDISK_LIBZ=libz.1
RAMDISK_LIBOBJC=libobjc.A
RAMDISK_LIBSTDCPP=libstdc++.6
RAMDISK_LIBSYSTEM=libSystem.B
RAMDISK_LIBGCC=libgcc_s.1
RAMDISK_SET="$RAMDISK_LIBZ $RAMDISK_LIBOBJC $RAMDISK_LIBSTDCPP $RAMDISK_LIBSYSTEM $RAMDISK_LIBGCC"

if [ -z "$MFM" ]; then
    echo 'usage: gmake -C test check-mfm MFM=/path/to/mfm.app/mfm' >&2
    exit 2
fi
if [ ! -f "$MFM" ]; then
    echo "mfm executable does not exist: $MFM" >&2
    exit 2
fi
if [ ! -d "$GUEST_OBJ_DIR" ]; then
    echo "Guest framework build output missing: $GUEST_OBJ_DIR" >&2
    echo "Run: gmake -C GuestMakefile first" >&2
    exit 1
fi

# otool/nm/dyldinfo: classic tools on PATH (macOS), else the Theos cross
# toolchain the guest build itself uses.
OTOOL=${LC32_OTOOL:-otool}
NM=${LC32_NM:-nm}
DYLDINFO=${LC32_DYLDINFO:-dyldinfo}
if ! command -v "$OTOOL" >/dev/null 2>&1 \
    || ! command -v "$DYLDINFO" >/dev/null 2>&1; then
    tc=${THEOS:-}/toolchain/linux/iphone/bin
    if [ -x "$tc/otool" ] && [ -x "$tc/dyldinfo" ]; then
        OTOOL="$tc/otool"
        NM="$tc/nm"
        DYLDINFO="$tc/dyldinfo"
    else
        echo "otool/dyldinfo not found; set THEOS or LC32_OTOOL/LC32_NM/LC32_DYLDINFO" >&2
        exit 1
    fi
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/lc32-mfm-symbols.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

# ---------------------------------------------------------------------------
# 1. Every undefined symbol of the app, with the dylib it nominally binds
#    to.  dyldinfo prints the short install name (libz, libSystem, Security,
#    UIKit, ...) and a trailing "(weak import)" flag on weak references.
#      bind:      seg sect addr type addend dylib symbol [weak-marker]
#      lazy_bind: seg sect addr index dylib symbol [weak-marker]
#      weak_bind: seg sect addr type addend symbol   (no dylib column)
#    The weak marker is folded into a third field so a weak miss can be
#    reported distinctly from a strong one.  dyld_stub_binder (the only
#    import without a leading underscore) is accepted explicitly: the guest
#    dyld resolves it against libSystem at load time.
# ---------------------------------------------------------------------------
"$DYLDINFO" -bind "$MFM" 2>/dev/null |
    awk '$4 == "pointer" && ($7 ~ /^_/ || $7 == "dyld_stub_binder") {
             print $6 "\t" $7 ($8 == "(weak" ? "\tweak" : "")
         }' > "$work/imports"
"$DYLDINFO" -lazy_bind "$MFM" 2>/dev/null |
    awk '$6 ~ /^_/ {
             print $5 "\t" $6 ($7 == "(weak" ? "\tweak" : "")
         }' >> "$work/imports"
"$DYLDINFO" -weak_bind "$MFM" 2>/dev/null |
    awk '$4 == "pointer" && $6 ~ /^_/ {
             print "(self)\t" $6 "\tweak-bound"
         }' >> "$work/imports"
LC_ALL=C sort -u "$work/imports" -o "$work/imports"

if [ ! -s "$work/imports" ]; then
    echo "No bind entries found in $MFM; unsupported or malformed Mach-O" >&2
    exit 1
fi

total_imports=$(wc -l < "$work/imports" | tr -d ' ')
n_symbols=$(cut -f2 "$work/imports" | sort -u | wc -l | tr -d ' ')

# ---------------------------------------------------------------------------
# 2. Export namespaces.
#
# 2a. Built guest frameworks (*.framework/<name> plus the guest libiconv).
# 2b. Ramdisk dylibs: no built image exists on this side, so the guest SDK
#     .tbd stub is the provider list.  A ramdisk import not even listed in
#     its .tbd is reported (SDK drift), but the MAC-OS-VERIFY annotation
#     still covers the image-level check on the packed RootFS.
# ---------------------------------------------------------------------------
find "$GUEST_OBJ_DIR" -maxdepth 2 -type d -name '*.framework' | sort |
    while IFS= read -r fw; do
        bin="$fw/$(basename "$fw" .framework)"
        [ -f "$bin" ] && printf '%s\n' "$bin"
    done > "$work/guest-images"
if [ -f "$GUEST_OBJ_DIR/libiconv.2.dylib" ]; then
    printf '%s\n' "$GUEST_OBJ_DIR/libiconv.2.dylib" >> "$work/guest-images"
fi
n_guest_images=$(wc -l < "$work/guest-images" | tr -d ' ')
if [ "$n_guest_images" -eq 0 ]; then
    echo "No built guest frameworks found under $GUEST_OBJ_DIR" >&2
    exit 1
fi

# Per-framework exports and the all-guest union.
while IFS= read -r bin; do
    "$NM" -gjU "$bin" 2>/dev/null || :
done < "$work/guest-images" | LC_ALL=C sort -u > "$work/all-guest-exports"

# Ramdisk export sets from the SDK .tbd stubs.  tbd v2 lists plain symbols
# in symbols:/weak-def-symbols: and ObjC runtime entities as bare names in
# objc-classes:/objc-ivars:/objc-ehtypes: (the linker synthesizes the
# _OBJC_CLASS_$_/_OBJC_METACLASS_$_/_OBJC_IVAR_$_/_OBJC_EHTYPE_$_ spellings
# from those).  Each list spans lines until its closing ']' and may wrap,
# so the extraction is a small line-oriented state machine.  $ld$...
# availability markers are ignored.
tbd_collect() {
    # $1 = tbd path, $2 = selector: "plain" (symbol lists) or "objc" (entity lists)
    awk -v what="$2" '
        function emit(sym,   s) {
            s = sym
            gsub(/^[\[[:space:]]+/, "", s)
            gsub(/[\][:space:]]+$/, "", s)
            sub(/^'\''/, "", s); sub(/'\''$/, "", s)
            if (s == "" || s ~ /^\$ld\$/) return
            if (kind == "objc-classes") {
                sub(/^_/, "", s)
                print "_OBJC_CLASS_$_" s
                print "_OBJC_METACLASS_$_" s
            } else if (kind == "objc-ivars") {
                sub(/^_/, "", s)
                print "_OBJC_IVAR_$_" s
            } else if (kind == "objc-ehtypes") {
                sub(/^_/, "", s)
                print "_OBJC_EHTYPE_$_" s
            } else {
                print s
            }
        }
        function start_list(tag,   line) {
            kind = tag
            line = $0
            sub(/^[[:space:]]*[a-z-]+:[[:space:]]*/, "", line)
            in_list = (line ~ /\[/)
            n = split(line, items, ",")
            for (i = 1; i <= n; i++) emit(items[i])
            if (line ~ /\]/) in_list = 0
        }
        /^[[:space:]]*(symbols|weak-def-symbols):/ {
            if (what == "plain") start_list("symbols")
            next
        }
        /^[[:space:]]*(objc-classes|objc-ivars|objc-ehtypes):/ {
            if (what == "objc") {
                _tag = $1
                sub(/:$/, "", _tag)
                start_list(_tag)
            }
            next
        }
        in_list {
            line = $0
            if (line ~ /\]/) { in_list = 0; sub(/\].*$/, "", line) }
            n = split(line, items, ",")
            for (i = 1; i <= n; i++) emit(items[i])
        }
    ' "$1"
}

for lib in $RAMDISK_SET; do
    {
        tbd_collect "$SDKROOT/usr/lib/$lib.tbd" plain
        tbd_collect "$SDKROOT/usr/lib/$lib.tbd" objc
    } | LC_ALL=C sort -u > "$work/ramdisk-exports.$lib"
done

# ---------------------------------------------------------------------------
# 3. Reexport chain expansion.  A framework's namespace is its own exports
#    plus, for each LC_REEXPORT_DYLIB, the namespace of the reexported image
#    (recursively).  Reexport install names pointing at a ramdisk dylib
#    (CoreFoundation -> /usr/lib/libobjc.A.dylib) contribute the ramdisk
#    set instead, which is what makes NSObject resolve through the guest
#    CoreFoundation exactly like it does at guest load time.
# ---------------------------------------------------------------------------
# Map any install-name spelling to a ramdisk set member, or nothing.
ramdisk_member() {
    _base=$(basename "$1" .dylib)
    case "$_base" in
        "$RAMDISK_LIBZ"|"$RAMDISK_LIBZ".*)            echo "$RAMDISK_LIBZ" ;;
        "$RAMDISK_LIBOBJC"|"$RAMDISK_LIBOBJC".*)       echo "$RAMDISK_LIBOBJC" ;;
        "$RAMDISK_LIBSTDCPP"|"$RAMDISK_LIBSTDCPP".*)   echo "$RAMDISK_LIBSTDCPP" ;;
        "$RAMDISK_LIBSYSTEM"|"$RAMDISK_LIBSYSTEM".*)   echo "$RAMDISK_LIBSYSTEM" ;;
        "$RAMDISK_LIBGCC"|"$RAMDISK_LIBGCC".*)         echo "$RAMDISK_LIBGCC" ;;
        *)                                              return 1 ;;
    esac
}

# resolve_chain <framework-name> <seen-file> -> exports on stdout
resolve_chain() {
    _fw=$1
    _seen=$2
    case "$(cat "$_seen")" in *"|$_fw|"*) return 0 ;; esac  # cycle guard
    echo "|$_fw|" >> "$_seen"
    _bin="$GUEST_OBJ_DIR/$_fw.framework/$_fw"
    [ -f "$_bin" ] || return 0
    "$NM" -gjU "$_bin" 2>/dev/null || :
    "$OTOOL" -l "$_bin" 2>/dev/null |
        awk '/LC_REEXPORT_DYLIB/{f=1} f && /^[[:space:]]*name /{print $2; f=0}' |
        while IFS= read -r _path; do
            if _rd=$(ramdisk_member "$_path"); then
                cat "$work/ramdisk-exports.$_rd" 2>/dev/null || :
                continue
            fi
            _img=$(basename "$_path" .dylib)
            if [ -f "$GUEST_OBJ_DIR/$_img.framework/$_img" ]; then
                resolve_chain "$_img" "$_seen"
            fi
        done
}

# Pre-expanded namespace per built framework (sorted, unique).
while IFS= read -r bin; do
    fw=$(basename "$bin")
    : > "$work/chain-seen"
    resolve_chain "$fw" "$work/chain-seen" \
        > "$work/chain.$fw" 2>/dev/null || :
    LC_ALL=C sort -u "$work/chain.$fw" -o "$work/chain.$fw" 2>/dev/null || :
done < "$work/guest-images"

# ---------------------------------------------------------------------------
# 4. Resolve each import.
#      ramdisk dylib  -> annotate MAC-OS-VERIFY (image lives in RootFS);
#                       still cross-check against the SDK .tbd list
#      guest framework -> must appear in its reexport-expanded namespace
#      (self)/weak-bound -> resolve against every provider incl. ramdisk
#      anything else  -> unresolved
# ---------------------------------------------------------------------------
: > "$work/missing-strong"
: > "$work/missing-weak"
: > "$work/ramdisk-unknown"
: > "$work/ramdisk-annotated"
n_resolved=0
n_weak_bound_ramdisk=0

# Short bind names -> ramdisk set members.
short_to_ramdisk() {
    case "$1" in
        libz)      echo "$RAMDISK_LIBZ" ;;
        libobjc)   echo "$RAMDISK_LIBOBJC" ;;
        libstdc++) echo "$RAMDISK_LIBSTDCPP" ;;
        libSystem) echo "$RAMDISK_LIBSYSTEM" ;;
        libgcc_s)  echo "$RAMDISK_LIBGCC" ;;
        *)         return 1 ;;
    esac
}

while IFS="$(printf '\t')" read -r module symbol flag; do
    [ -n "${symbol:-}" ] || continue
    if [ "$module" = "(self)" ]; then
        # Weak-bound (override-candidate) symbol with no nominal dylib:
        # accept any provider, the ramdisk set included.
        found=
        for lib in $RAMDISK_SET; do
            if grep -qx "$symbol" "$work/ramdisk-exports.$lib" 2>/dev/null; then
                printf '%s\t%s\n' "$lib" "$symbol" >> "$work/ramdisk-annotated"
                n_weak_bound_ramdisk=$((n_weak_bound_ramdisk + 1))
                found=1
                break
            fi
        done
        if [ -z "$found" ]; then
            if grep -qx "$symbol" "$work/all-guest-exports" 2>/dev/null; then
                n_resolved=$((n_resolved + 1))
            else
                printf '%s\t%s\t%s\n' "$module" "$symbol" "${flag:-}" \
                    >> "$work/missing-weak"
            fi
        fi
        continue
    fi
    if rd=$(short_to_ramdisk "$module"); then
        # Ramdisk-resident dylib: MAC-OS-VERIFY annotation (packed RootFS
        # check is CI-on-macOS work), plus a drift check against the SDK.
        printf '%s\t%s\n' "$rd" "$symbol" >> "$work/ramdisk-annotated"
        if ! grep -qx "$symbol" "$work/ramdisk-exports.$rd" 2>/dev/null; then
            printf '%s\t%s\n' "$rd" "$symbol" >> "$work/ramdisk-unknown"
        fi
        continue
    fi
    if [ -f "$work/chain.$module" ]; then
        if grep -qx "$symbol" "$work/chain.$module"; then
            n_resolved=$((n_resolved + 1))
        elif [ "${flag:-}" = "weak" ]; then
            printf '%s\t%s\tweak\n' "$module" "$symbol" >> "$work/missing-weak"
        else
            printf '%s\t%s\n' "$module" "$symbol" >> "$work/missing-strong"
        fi
        continue
    fi
    # Not a built framework, not a ramdisk dylib: resolve globally, the way
    # guest dyld's flat fallback would, before calling it missing.
    if grep -qx "$symbol" "$work/all-guest-exports" 2>/dev/null; then
        n_resolved=$((n_resolved + 1))
    elif [ "${flag:-}" = "weak" ]; then
        printf '%s\t%s\tweak\n' "$module" "$symbol" >> "$work/missing-weak"
    else
        printf '%s\t%s\n' "$module" "$symbol" >> "$work/missing-strong"
    fi
done < "$work/imports"

LC_ALL=C sort -u "$work/missing-strong" -o "$work/missing-strong"
LC_ALL=C sort -u "$work/missing-weak" -o "$work/missing-weak"
LC_ALL=C sort -u "$work/ramdisk-unknown" -o "$work/ramdisk-unknown"
LC_ALL=C sort -u "$work/ramdisk-annotated" -o "$work/ramdisk-annotated"

# ---------------------------------------------------------------------------
# 5. Report.  Unresolved framework symbols fail the audit; the ramdisk set
#    is summarized with MAC-OS-VERIFY annotations.
# ---------------------------------------------------------------------------
exit_code=0
if [ -s "$work/missing-strong" ]; then
    n=$(wc -l < "$work/missing-strong" | tr -d ' ')
    echo "MISSING framework symbols in the built guest world ($n):" >&2
    sed 's/^/  /' "$work/missing-strong" >&2
    exit_code=1
fi
if [ -s "$work/missing-weak" ]; then
    n=$(wc -l < "$work/missing-weak" | tr -d ' ')
    echo "UNRESOLVED weak-import symbols ($n):" >&2
    sed 's/^/  /' "$work/missing-weak" >&2
    exit_code=1
fi
if [ -s "$work/ramdisk-unknown" ]; then
    n=$(wc -l < "$work/ramdisk-unknown" | tr -d ' ')
    echo "RAMDISK DYLIB SYMBOLS NOT IN THE SDK STUBS ($n):" >&2
    sed 's/^/  /' "$work/ramdisk-unknown" >&2
    exit_code=1
fi

n_ramdisk_refs=$(wc -l < "$work/ramdisk-annotated" | tr -d ' ')
n_ramdisk_libs=$(cut -f1 "$work/ramdisk-annotated" | sort -u | wc -l | tr -d ' ')

if [ "$exit_code" -eq 0 ]; then
    echo "mfm symbol audit: PASS"
else
    echo "mfm symbol audit: FAIL"
fi
echo "  binary:        $MFM"
echo "  imports:       $total_imports unique (module, symbol) bindings" \
     "($n_symbols distinct symbols)"
echo "  guest world:   $n_guest_images built images searched," \
     "reexport chains followed (Foundation->CoreFoundation/CFNetwork," \
     "AVFoundation->AVFAudio, CoreFoundation->libobjc.A)"
echo "  resolved:      $n_resolved refs against built guest framework exports"
echo "  ramdisk set:   $n_ramdisk_refs refs across $n_ramdisk_libs dylibs" \
     "(incl. $n_weak_bound_ramdisk weak-bound)"
n_missing_strong=$(wc -l < "$work/missing-strong" | tr -d ' ')
n_missing_weak=$(wc -l < "$work/missing-weak" | tr -d ' ')
echo "  missing:       $n_missing_strong framework symbols" \
     "($n_missing_weak unresolved weak)"
echo
if [ "$n_ramdisk_refs" -gt 0 ]; then
    echo "MAC-OS-VERIFY (RootFS contents; pack-ramdisk.sh runs on macOS/CI):"
    echo "  the following ramdisk-resident dylibs must exist in"
    echo "  Resources/RootFS/usr/lib after pack-ramdisk.sh:"
    cut -f1 "$work/ramdisk-annotated" | sort -u |
        while IFS= read -r lib; do
            n=$(awk -F'\t' -v l="$lib" '$1 == l' "$work/ramdisk-annotated" \
                | wc -l | tr -d ' ')
            echo "    $lib.dylib  ($n refs)  MAC-OS-VERIFY"
        done
fi

exit $exit_code
