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
# Usage: ./verify-build.sh [path-to-dmg]
#   With no argument the newest Menfez-*.dmg next to this script is used.
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/Menfez.app"
MIN_MINOS="13.0"
ARCHS="x86_64 arm64"

DMG="${1:-}"
if [ -z "$DMG" ]; then
    # Newest first; `ls -t` on a glob is portable enough for this one directory.
    DMG="$(ls -t "$DIR"/Menfez-*.dmg 2>/dev/null | head -n 1)"
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
if codesign -dv "$APP" >/dev/null 2>&1; then
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

# --- 4. the dmg -----------------------------------------------------------
section "dmg"
if [ -z "${DMG:-}" ] || [ ! -f "$DMG" ]; then
    fail "dmg exists" "ls $DIR/Menfez-*.dmg" "no dmg found; run ./build-dmg.sh first"
else
    pass "dmg exists" "ls -l $DMG"
    # The dmg hash is what the download page publishes, so print it here too —
    # otherwise the number on the page has no reproducible source.
    pass "dmg sha256" "shasum -a 256 $DMG -> $(shasum -a 256 "$DMG" | awk '{print $1}')"

    if codesign -dv "$DMG" >/dev/null 2>&1; then
        pass "dmg is signed" "codesign -dv $DMG -> $(codesign -dv "$DMG" 2>&1 | grep -E '^Signature=' || echo 'no Signature= line')"
    else
        fail "dmg is signed" "codesign -dv $DMG" "not signed"
    fi

    # Mount read-only at a private mountpoint so a running verify never
    # disturbs, or is disturbed by, a dmg the user has open in Finder.
    MOUNT="$(mktemp -d)"
    if hdiutil attach "$DMG" -mountpoint "$MOUNT" -readonly -nobrowse -noautoopen >/dev/null 2>&1; then
        pass "dmg mounts" "hdiutil attach $DMG -mountpoint $MOUNT"

        if [ -d "$MOUNT/Menfez.app" ]; then
            pass "dmg contains Menfez.app" "test -d $MOUNT/Menfez.app"
        else
            fail "dmg contains Menfez.app" "test -d $MOUNT/Menfez.app" "missing"
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

        # Byte-for-byte identity between the built bundle and the shipped one.
        # A dmg built from a stale Menfez.app is indistinguishable from a fresh
        # one until somebody notices the version or a missing fix, so compare
        # the bytes rather than the names. `cmp` on the Mach-O files is the
        # check that matters; Info.plist and the icon are compared too because
        # a wrong icon or version in the dmg is just as confusing.
        for inner in "Contents/MacOS/Menfez" "Contents/MacOS/menfez-route" \
                     "Contents/Info.plist" "Contents/Resources/AppIcon.icns"; do
            if [ ! -e "$APP/$inner" ] && [ ! -e "$MOUNT/Menfez.app/$inner" ]; then
                skip "identical: $inner" "absent from both the build and the dmg"
                continue
            fi
            if cmp -s "$APP/$inner" "$MOUNT/Menfez.app/$inner"; then
                pass "identical: $inner" "cmp $APP/$inner $MOUNT/Menfez.app/$inner"
            else
                fail "identical: $inner" "cmp $APP/$inner $MOUNT/Menfez.app/$inner" \
                     "differs — the dmg was not built from this bundle"
            fi
        done

        hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
    else
        fail "dmg mounts" "hdiutil attach $DMG -mountpoint $MOUNT" "attach failed"
    fi
    rmdir "$MOUNT" 2>/dev/null || true
fi

section "result"
if [ "$FAILED" -eq 0 ]; then
    echo "all checks passed"
    exit 0
fi
echo "$FAILED check(s) failed"
exit 1
