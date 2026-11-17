#!/bin/bash
# verify-build.sh — check that the built artefacts are actually shippable.
#
# Every check below exists because its failure is invisible to a builder on an
# Apple-silicon machine and fatal for somebody else: a thin binary runs fine
# here and dies on Intel, a raised deployment target launches here and refuses
# to start on Ventura, an unsigned or wrongly signed bundle trips Gatekeeper,
# and a dmg that lost its /Applications symlink or its exact app copy is only
# discovered by a stranger after the download.
#
# Each check prints PASS or FAIL with the command that produced the evidence, so
# a reviewer can re-run any line by hand. The script exits non-zero if anything
# failed, which is what makes it usable as a release gate.
#
# Usage: ./verify-build.sh [path-to-dmg ...]
#   With no argument every Menfez-<version>-*.dmg next to this script is
#   checked, <version> being the built app's. build-dmg.sh makes one per
#   architecture (arm64, intel), each with thinned binaries.
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/Menfez.app"
MIN_MINOS="13.0"
ARCHS="x86_64 arm64"

DMGS=("$@")
if [ "${#DMGS[@]}" -eq 0 ]; then
    VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
               "$APP/Contents/Info.plist" 2>/dev/null || true)"
    for f in "$DIR"/Menfez-"$VERSION"-*.dmg; do [ -f "$f" ] && DMGS+=("$f"); done
fi

FAILED=0
pass() { printf 'PASS  %s\n      $ %s\n' "$1" "$2"; }
fail() { printf 'FAIL  %s\n      $ %s\n      -> %s\n' "$1" "$2" "$3"; FAILED=$((FAILED + 1)); }
skip() { printf 'SKIP  %s\n      %s\n' "$1" "$2"; }

# section headings, so a long log stays readable
section() { printf '\n== %s ==\n' "$1"; }

# --- 1. both executables carry both architectures -------------------------
# A universal binary is the whole point: the same download has to run natively
# on Apple silicon and on Intel. `lipo -archs` is checked per slice rather than
# trusting `file`, which also calls a binary universal on weaker evidence.
section "architectures"
for exe in "$APP/Contents/MacOS/Menfez" "$APP/Contents/MacOS/menfez-route"; do
    name="$(basename "$exe")"
    if [ ! -f "$exe" ]; then
        fail "$name exists" "test -f $exe" "missing from the bundle"
        continue
    fi
    got="$(lipo -archs "$exe" 2>/dev/null)"
    missing=""
    for want in $ARCHS; do
        case " $got " in *" $want "*) ;; *) missing="$missing $want" ;; esac
    done
    if [ -z "$missing" ]; then
        pass "$name is universal" "lipo -archs $exe -> $got"
    else
        fail "$name is universal" "lipo -archs $exe -> $got" "missing:$missing"
    fi
done

# --- 2. deployment target is 13.0 in every slice -------------------------
# LC_BUILD_VERSION carries the minimum OS the loader enforces. Package.swift
# saying .macOS(.v13) is not proof; only the Mach-O header is. Both slices are
# read, because a fat binary can mix a 13.0 arm64 slice with a newer x86_64 one
# and then fail only on the Intel Mac.
section "deployment target"
for exe in "$APP/Contents/MacOS/Menfez" "$APP/Contents/MacOS/menfez-route"; do
    name="$(basename "$exe")"
    [ -f "$exe" ] || { fail "$name minos" "otool -l $exe" "binary missing"; continue; }
    for arch in $ARCHS; do
        minos="$(otool -l -arch "$arch" "$exe" 2>/dev/null \
            | awk '/LC_BUILD_VERSION/{seen=1} seen && /minos/{print $2; exit}')"
        if [ "$minos" = "$MIN_MINOS" ]; then
            pass "$name ($arch) minos $MIN_MINOS" \
                 "otool -l -arch $arch $exe | grep -A5 LC_BUILD_VERSION -> minos $minos"
        else
            fail "$name ($arch) minos $MIN_MINOS" \
                 "otool -l -arch $arch $exe -> minos '${minos:-none}'" \
                 "the loader will refuse this slice below ${minos:-?}"
        fi
    done
done

# --- 3. the bundle is signed, and signed ad-hoc --------------------------
# Gatekeeper reads the signature on the bundle, not on the binary alone. An
# ad-hoc signature is what this project ships before the Developer ID
# membership, so the check asserts "adhoc" specifically: a bundle that lost its
# signature entirely, or one signed with an unexpected identity, is a different
# distribution story and must not pass silently.
section "signature"
# With MENFEZ_SIGN_IDENTITY set (a Developer ID build) the identity and the
# hardened runtime are asserted instead.
if [ -n "${MENFEZ_SIGN_IDENTITY:-}" ]; then
    info="$(codesign -dvv "$APP" 2>&1)"
    if echo "$info" | grep -qxF "Authority=$MENFEZ_SIGN_IDENTITY" \
        && echo "$info" | grep -qE '^CodeDirectory .*flags=.*runtime'; then
        pass "app is signed by $MENFEZ_SIGN_IDENTITY with hardened runtime" "codesign -dvv $APP"
    else
        fail "app is signed by $MENFEZ_SIGN_IDENTITY with hardened runtime" "codesign -dvv $APP" \
             "$(echo "$info" | grep -E '^Authority=|^CodeDirectory' | head -2 | tr '\n' ' ')"
    fi
elif codesign -dv "$APP" >/dev/null 2>&1; then
    sigline="$(codesign -dv "$APP" 2>&1 | grep -E '^Signature=' || true)"
    if [ "$sigline" = "Signature=adhoc" ]; then
        pass "app is ad-hoc signed" "codesign -dv $APP -> $sigline"
    else
        fail "app is ad-hoc signed" "codesign -dv $APP -> ${sigline:-no Signature= line}" \
             "expected exactly 'Signature=adhoc'"
    fi
else
    fail "app is signed" "codesign -dv $APP" "codesign could not read a signature"
fi

# Nested code is what `--deep` gets wrong, so both executables are checked
# individually as well.
for exe in "$APP/Contents/MacOS/Menfez" "$APP/Contents/MacOS/menfez-route"; do
    name="$(basename "$exe")"
    [ -f "$exe" ] || continue
    if codesign -dv "$exe" >/dev/null 2>&1; then
        pass "$name is signed" "codesign -dv $exe -> $(codesign -dv "$exe" 2>&1 | grep -E '^Signature=' || echo 'no Signature= line')"
    else
        fail "$name is signed" "codesign -dv $exe" "not signed"
    fi
done

# --- 4. the dmgs -----------------------------------------------------------
# One per architecture. Each carries thinned binaries, re-signed after
# thinning, so a binary is compared with the matching slice of the universal
# build (lipo -thin), both with their signatures removed: the code must be
# the same bytes, the signature is expected to differ.
same_code() {   # $1 universal, $2 thin, $3 arch
    local tmp ok=1
    tmp="$(mktemp -d)"
    lipo -thin "$3" "$1" -output "$tmp/a" 2>/dev/null || { rm -rf "$tmp"; return 1; }
    cp "$2" "$tmp/b"
    codesign --remove-signature "$tmp/a" 2>/dev/null
    codesign --remove-signature "$tmp/b" 2>/dev/null
    cmp -s "$tmp/a" "$tmp/b" && ok=0
    rm -rf "$tmp"
    return $ok
}

verify_dmg() {
    local DMG="$1" want_arch=""
    section "dmg $(basename "$DMG")"
    case "$(basename "$DMG")" in
        *-arm64.dmg) want_arch=arm64 ;;
        *-intel.dmg) want_arch=x86_64 ;;
    esac
    pass "dmg exists" "ls -l $DMG"
    # The dmg hash is what the download page publishes, so print it here too —
    # otherwise the number on the page has no reproducible source.
    pass "dmg sha256" "shasum -a 256 $DMG -> $(shasum -a 256 "$DMG" | awk '{print $1}')"

    if codesign -dv "$DMG" >/dev/null 2>&1; then
        pass "dmg is signed" "codesign -dv $DMG -> $(codesign -dv "$DMG" 2>&1 | grep -E '^Signature=|^Authority=' | head -1 || echo 'no Signature= line')"
    else
        fail "dmg is signed" "codesign -dv $DMG" "not signed"
    fi

    # Mount read-only at a private mountpoint so a running verify never
    # disturbs, or is disturbed by, a dmg the user has open in Finder.
    local MOUNT
    MOUNT="$(mktemp -d)"
    if ! hdiutil attach "$DMG" -mountpoint "$MOUNT" -readonly -nobrowse -noautoopen >/dev/null 2>&1; then
        fail "dmg mounts" "hdiutil attach $DMG -mountpoint $MOUNT" "attach failed"
        rmdir "$MOUNT" 2>/dev/null || true
        return
    fi
    pass "dmg mounts" "hdiutil attach $DMG -mountpoint $MOUNT"
    local IN="$MOUNT/Menfez.app"

    if [ -d "$IN" ]; then
        pass "dmg contains Menfez.app" "test -d $IN"
    else
        fail "dmg contains Menfez.app" "test -d $IN" "missing"
    fi

    # The symlink is the drag-to-install affordance; without it the window
    # is a bare folder and the instructions in INSTALL.txt stop matching.
    if [ -L "$MOUNT/Applications" ] && [ "$(readlink "$MOUNT/Applications")" = "/Applications" ]; then
        pass "dmg has /Applications symlink" \
             "readlink $MOUNT/Applications -> $(readlink "$MOUNT/Applications")"
    else
        fail "dmg has /Applications symlink" "readlink $MOUNT/Applications" \
             "missing or pointing somewhere other than /Applications"
    fi

    # The app inside must pass its own signature check after thinning.
    if codesign --verify --strict "$IN" >/dev/null 2>&1; then
        pass "dmg app signature verifies" "codesign --verify --strict $IN"
    else
        fail "dmg app signature verifies" "codesign --verify --strict $IN" \
             "$(codesign --verify --strict "$IN" 2>&1 | tail -1)"
    fi

    # Executables: the dmg's architecture only, and the same code as that
    # slice of the build. A dmg built from a stale Menfez.app is
    # indistinguishable from a fresh one until somebody notices a missing fix.
    local inner bin got
    for inner in "Contents/MacOS/Menfez" "Contents/MacOS/menfez-route"; do
        bin="$IN/$inner"
        [ -f "$bin" ] || { fail "present: $inner" "test -f $bin" "missing"; continue; }
        got="$(lipo -archs "$bin" 2>/dev/null)"
        if [ -n "$want_arch" ] && [ "$got" != "$want_arch" ]; then
            fail "$inner is $want_arch only" "lipo -archs $bin -> $got" "wrong slice for this image"
            continue
        fi
        if same_code "$APP/$inner" "$bin" "$got"; then
            pass "same code as the build's $got slice: $inner" \
                 "lipo -thin $got $APP/$inner | cmp (signatures removed) $bin"
        else
            fail "same code as the build's $got slice: $inner" \
                 "lipo -thin $got $APP/$inner | cmp (signatures removed) $bin" \
                 "differs — the dmg was not built from this bundle"
        fi
    done

    # Everything else is copied untouched, so it must match byte for byte.
    for inner in "Contents/Info.plist" "Contents/Resources/AppIcon.icns" \
                 "Contents/Resources/install-helper.sh"; do
        if [ ! -e "$APP/$inner" ] && [ ! -e "$IN/$inner" ]; then
            skip "identical: $inner" "absent from both the build and the dmg"
            continue
        fi
        if cmp -s "$APP/$inner" "$IN/$inner"; then
            pass "identical: $inner" "cmp $APP/$inner $IN/$inner"
        else
            fail "identical: $inner" "cmp $APP/$inner $IN/$inner" \
                 "differs — the dmg was not built from this bundle"
        fi
    done

    hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
    rmdir "$MOUNT" 2>/dev/null || true
}

if [ "${#DMGS[@]}" -eq 0 ]; then
    section "dmg"
    fail "dmg exists" "ls $DIR/Menfez-*.dmg" "no dmg found; run ./build-dmg.sh first"
else
    for d in "${DMGS[@]}"; do
        if [ -f "$d" ]; then verify_dmg "$d"
        else section "dmg"; fail "dmg exists" "ls -l $d" "no such file"; fi
    done
fi

section "result"
if [ "$FAILED" -eq 0 ]; then
    echo "all checks passed"
    exit 0
fi
echo "$FAILED check(s) failed"
exit 1
