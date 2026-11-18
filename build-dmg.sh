#!/bin/bash
# build-dmg.sh — produce the distributable disk images.
#
# TWO images rather than one universal build, because macOS 27 shows every
# Apple-silicon user a "this app contains a component that will not open on
# macOS 28" warning when the bundle carries an x86_64 slice. The slice is for
# Intel Macs; an M-series user paying that warning for a slice they never run is
# a bad trade.
#
#   Menfez-<v>-arm64.dmg   Apple silicon (M1 and later), no warning
#   Menfez-<v>-intel.dmg   Intel, carries the warning because it must be x86_64
#
# The layout, the app, and the install text are identical. Only the architecture
# differs, so a user who downloads the wrong one gets a clear "not supported on
# this Mac" rather than a crash.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/Menfez.app"
# Ad-hoc by default; Developer ID and notarisation from MENFEZ_SIGN_IDENTITY
# and MENFEZ_NOTARY_PROFILE (see tools/sign.sh).
. "$DIR/tools/sign.sh"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
           "$APP/Contents/Info.plist" 2>/dev/null || echo "1.0.0")"
STAGE="$(mktemp -d)"

cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

if [ ! -d "$APP" ]; then
    echo "error: Menfez.app not found. Run ./build-app.sh first." >&2
    exit 1
fi

# The app must be universal before slicing: a single-arch app here means the
# build script produced something unexpected and neither image would be right.
for bin in "$APP/Contents/MacOS/Menfez" "$APP/Contents/MacOS/menfez-route" \
           "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"; do
    [ -x "$bin" ] || { echo "error: missing $bin" >&2; exit 1; }
    archs="$(lipo -archs "$bin" 2>/dev/null)"
    case "$archs" in
        *arm64*x86_64*|*x86_64*arm64*) ;;
        *) echo "error: $(basename "$bin") is not universal (archs: $archs)" >&2; exit 1 ;;
    esac
done

install_text() {
    # $1 = "arm64" or "intel"
    local flavour="$1"
    local note=""
    if [ "$flavour" = "intel" ]; then
        note='
NOTE: macOS 27 may warn that this app "contains a component that will not open
on macOS 28". That component is the Intel binary itself: Apple is retiring
Rosetta, so Intel Macs stop being supported by macOS 28 anyway. The app works
normally on every Intel Mac that runs a supported macOS.
'
    fi

    # Every release is signed and notarised (docs/SIGNING.md). An ad-hoc dmg is
    # for local testing only and is never published, so it gets the same text.
    local steps='2. Open Menfez. macOS asks once whether to open an app downloaded from the
   internet. Click Open.'

    cat <<TXT
Menfez ($flavour)
==================

1. Drag Menfez into your Applications folder.

$steps

Menfez needs no administrator password to bypass DPI. The optional tunnel mode
asks for a one-time setup; the app explains it when you open that mode.
$note
Source: https://github.com/burhanrb/Menfez
Web:    https://menfez.app
Licence: Apache-2.0
TXT
}

build_image() {
    local flavour="$1"   # arm64 | intel
    local slice="$2"     # arm64 | x86_64
    local out="$DIR/Menfez-${VERSION}-${flavour}.dmg"
    local work="$STAGE/$flavour"

    echo "==> $flavour"
    mkdir -p "$work"
    cp -R "$APP" "$work/Menfez.app"

    # Thin both executables. `lipo -thin` rewrites in place only via a temp
    # file, so copy then replace to keep the bundle's permissions.
    # Sparkle's binaries too: an x86_64 slice anywhere in the arm64 image
    # brings back the macOS 27 warning this split exists to avoid.
    local fw="Frameworks/Sparkle.framework/Versions/B"
    for bin in MacOS/Menfez MacOS/menfez-route "$fw/Sparkle" "$fw/Autoupdate" \
               "$fw/Updater.app/Contents/MacOS/Updater"; do
        local target="$work/Menfez.app/Contents/$bin"
        lipo -thin "$slice" "$target" -output "$target.thin" 2>/dev/null
        mv "$target.thin" "$target"
        chmod 0755 "$target"
    done

    # Sign after thinning: the old signature covered the fat binary and is
    # invalid once the file changes.
    sign_app "$work/Menfez.app"

    ln -s /Applications "$work/Applications"
    install_text "$flavour" > "$work/INSTALL.txt"

    rm -f "$out"
    hdiutil create -volname "Menfez" -srcfolder "$work" -ov -format UDZO \
        -fs HFS+ "$out" >/dev/null 2>&1

    sign_dmg "$out"
    # Stapling changes the file, so the sha256 below is taken after it.
    notarise_dmg "$out" "$work/Menfez.app"

    local size sha
    size="$(du -h "$out" | cut -f1)"
    sha="$(shasum -a 256 "$out" | awk '{print $1}')"
    printf "    %s (%s)\n    sha256: %s\n" "$(basename "$out")" "$size" "$sha"
}

build_image arm64 arm64
build_image intel x86_64

echo
echo "Two images on purpose: the arm64 one carries no Rosetta slice, so macOS 27"
echo "does not warn its users about a component they will never run. Publish both"
echo "with their sha256 next to each download link."
