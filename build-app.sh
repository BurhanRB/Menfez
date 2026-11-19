#!/bin/bash
# build-app.sh — build Menfez as a universal binary and package it as a .app bundle.
#
# Everything ships compiled: the UI, the privileged helper, and the shared
# core. There is no Python interpreter and no script in the bundle, so the
# sudoers entry is a single absolute path to one binary.
#
# UNIVERSAL BY CONSTRUCTION
# The user hands this build to strangers on Intel Macs and on Apple silicon, so
# a host-only build is worthless. Each architecture is built into its own
# scratch directory and then fused with `lipo -create`. Two separate builds
# rather than one `swift build --arch a --arch b` call on purpose: the
# multi-arch form writes its fused product into the shared .build directory,
# where any later single-arch invocation silently replaces it with a thin
# binary. Separate scratch paths make that impossible, and the assertions below
# turn any remaining surprise into a hard failure instead of a shipped dmg that
# only runs on the build machine.
#
# MINIMUM SYSTEM VERSION
# Package.swift declares .macOS(.v13). MACOSX_DEPLOYMENT_TARGET is also pinned
# to 13.0 because SwiftPM takes the lowest of the platform declaration and the
# environment variable; setting both means an accidental bump in either place
# cannot quietly raise the floor and lock Ventura users out. The value is
# re-read from the finished Mach-O headers below, so a silent change fails the
# build rather than the user's first launch.
#
# DEVELOPER_DIR is set explicitly: the SwiftUI macro plugin
# (libSwiftUIMacros.dylib) only exists under Xcode's macOS platform and is not
# part of the Command Line Tools, so building against them fails with
# "macro implementation type ... not found".
#
# Signing is ad-hoc unless MENFEZ_SIGN_IDENTITY is set (see tools/sign.sh and
# docs/SIGNING.md). Ad-hoc runs without an Apple Developer account; it is not
# notarised, so another Mac needs a right-click Open the first time.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/Menfez.app"
. "$DIR/tools/sign.sh"
# The binary products live here after a universal build. This used to point at
# a local `build/` staging directory that a previous script created; it went
# stale and the app shipped a binary without the latest changes while every
# check still passed, because the checks compared the bundle to that stale copy.
BUILD="$DIR/Menfez/.build/out/Products/Release"
# No existence check here: the build step below wipes and recreates $BUILD, so
# a fresh checkout has no such directory yet. The stale-copy bug stays fixed by
# that rm -rf and by assert_universal checking the freshly fused binaries.
# Every release bumps the patch number (1.0.0 → 1.0.1 → 1.0.2 …) and adds an
# entry to Menfez/Sources/MenfezCore/Changelog.swift; ChangelogTests checks both.
VERSION="1.0.12"
MIN_MINOS="13.0"
ARCHS="x86_64 arm64"
XCODE="/Applications/Xcode.app/Contents/Developer"
# Sparkle (docs/SIGNING.md §1c). The EdDSA public key pairs with the private
# key in the release machine's login keychain (generate_keys --account menfez;
# backup: docs/SIGNING.md). Only the public half is ever in the repository.
SPARKLE_ED_PUBLIC_KEY="jN18KqaLFRcHVoTcjDB0BecdZ3XPDHQNV7LS099ZwMk="

export MACOSX_DEPLOYMENT_TARGET="$MIN_MINOS"

if [ -d "$XCODE" ]; then
    export DEVELOPER_DIR="$XCODE"
else
    echo "warning: Xcode not found at $XCODE; SwiftUI macros may not resolve"
fi

# Read the minimum OS out of one architecture slice of a finished Mach-O.
# `otool -l` prints one LC_BUILD_VERSION per slice, so the arch has to be
# selected explicitly or the second value would silently win.
minos_of() {
    otool -l -arch "$2" "$1" 2>/dev/null \
        | awk '/LC_BUILD_VERSION/{seen=1} seen && /minos/{print $2; exit}'
}

# A single-arch binary is the exact failure this script exists to prevent, so
# check the architectures and the deployment target together and refuse to
# produce a bundle if anything is off.
assert_universal() {
    local file="$1" name="$2" archs minos
    [ -f "$file" ] || { echo "error: $name: no such file: $file" >&2; exit 1; }

    archs="$(lipo -archs "$file" 2>/dev/null || true)"
    for want in $ARCHS; do
        case " $archs " in
            *" $want "*) ;;
            *) echo "error: $name is not universal: lipo -archs reported '$archs', missing $want" >&2
               echo "       a thin binary only runs on the architecture it was compiled on" >&2
               exit 1 ;;
        esac
    done

    for arch in $ARCHS; do
        minos="$(minos_of "$file" "$arch")"
        if [ "$minos" != "$MIN_MINOS" ]; then
            echo "error: $name ($arch): minimum OS is '${minos:-unreadable}', expected $MIN_MINOS" >&2
            echo "       check the .macOS(.v13) declaration and MACOSX_DEPLOYMENT_TARGET" >&2
            exit 1
        fi
    done
    echo "    $name: $archs · minos $MIN_MINOS"
}

echo "==> building ($ARCHS)"
rm -rf "$BUILD"
mkdir -p "$BUILD"

for arch in $ARCHS; do
    SCRATCH="$BUILD/scratch-$arch"
    echo "--> swift build -c release --arch $arch"
    ( cd "$DIR/Menfez" && swift build -c release --arch "$arch" --scratch-path "$SCRATCH" )
    # Ask SwiftPM where it put the products instead of assuming a layout: the
    # path has moved between SwiftPM releases. stderr is discarded because
    # compiler warnings land there and would otherwise be parsed as a path.
    BINPATH="$( cd "$DIR/Menfez" \
        && swift build -c release --arch "$arch" --scratch-path "$SCRATCH" --show-bin-path 2>/dev/null \
        | tail -n 1 )"
    [ -n "$BINPATH" ] || { echo "error: $arch: SwiftPM did not report a bin path" >&2; exit 1; }
    for exe in Menfez menfez-route; do
        [ -x "$BINPATH/$exe" ] || { echo "error: $arch: missing build product $BINPATH/$exe" >&2; exit 1; }
        mkdir -p "$SCRATCH/slices"
        cp "$BINPATH/$exe" "$SCRATCH/slices/$exe"
    done
    # SwiftPM adds an rpath to its own build directory for Sparkle; it names
    # this machine's home folder and means nothing on a user's Mac.
    otool -l "$SCRATCH/slices/Menfez" | awk '/LC_RPATH/{r=1} r && $1=="path"{print $2; r=0}' \
        | { grep PackageFrameworks || true; } | while read -r rp; do
            install_name_tool -delete_rpath "$rp" "$SCRATCH/slices/Menfez"
        done
    SPARKLE_FW="$BINPATH/Sparkle.framework"
done
[ -d "$SPARKLE_FW" ] || { echo "error: Sparkle.framework not found next to the build products" >&2; exit 1; }

echo "==> lipo (fusing slices)"
for exe in Menfez menfez-route; do
    SLICES=()
    for arch in $ARCHS; do
        SLICES+=("$BUILD/scratch-$arch/slices/$exe")
    done
    lipo -create "${SLICES[@]}" -output "$BUILD/$exe"
done

echo "==> verifying architectures and deployment target"
for exe in Menfez menfez-route; do
    assert_universal "$BUILD/$exe" "$exe"
done
if otool -l "$BUILD/Menfez" | grep -q PackageFrameworks; then
    echo "error: Menfez still carries a build-directory rpath" >&2; exit 1
fi

# One test run, both the summary and the verdict. Two runs doubled a 25 s
# step and, because the summary was piped through grep first, a failure could
# scroll past and look like a clean stop.
#
# The test gate runs before packaging, and build-dmg.sh calls this script, so a
# failing suite stops the dmg as well.
echo "==> testing"
TESTLOG="$(mktemp)"
if ! ( cd "$DIR/Menfez" && swift test >"$TESTLOG" 2>&1 ); then
    echo "error: tests failed; refusing to package" >&2
    grep -E "error: -\[" "$TESTLOG" | head -5 >&2
    echo "  (full log: $TESTLOG)" >&2
    exit 1
fi
grep -E "Executed [0-9]+ tests" "$TESTLOG" | tail -1
# A zero-test run would otherwise look identical to a passing one, and an empty
# suite is not evidence that the code works.
if ! grep -qE "Executed [0-9]+ tests" "$TESTLOG"; then
    echo "error: test runner produced no summary; refusing to package" >&2
    exit 1
fi
rm -f "$TESTLOG"

BIN="$BUILD/Menfez"
HELPER="$BUILD/menfez-route"

echo "==> assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Declared languages (CFBundleLocalizations): the app menu and Sparkle's
# windows follow the user's language only for languages the app ships.
for l in en tr; do
    mkdir -p "$APP/Contents/Resources/$l.lproj"
    printf '/* Menfez: the UI strings live in the app. */\n' > "$APP/Contents/Resources/$l.lproj/InfoPlist.strings"
done
cp "$BIN"    "$APP/Contents/MacOS/Menfez"
# The helper lives beside the app binary so the UI finds it without a lookup
# path, and so the sudoers line names one stable absolute path.
cp "$HELPER" "$APP/Contents/MacOS/menfez-route"
# The one-time tunnel setup the Help panel shows runs this script; it copies the
# helper out of the bundle into a root-owned directory before granting it.
cp "$DIR/install-helper.sh" "$APP/Contents/Resources/install-helper.sh"
# Sparkle, found through @executable_path/../Frameworks (Package.swift).
# ditto keeps the framework's symlinks. The XPC services exist for sandboxed
# apps only; Menfez is not sandboxed, and Sparkle's docs allow removing them.
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" \
       "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
# Sparkle's MIT license must travel with the binary. Its LICENSE comes from the
# SwiftPM artifact (or the checkout); About > Third-party licenses opens it.
SPARKLE_LICENSE=""
for f in "$BUILD"/scratch-*/artifacts/sparkle/Sparkle/LICENSE "$DIR/Menfez/.build/artifacts/sparkle/Sparkle/LICENSE" \
         "$BUILD"/scratch-*/checkouts/Sparkle/LICENSE "$DIR/Menfez/.build/checkouts/Sparkle/LICENSE"; do
    [ -f "$f" ] && { SPARKLE_LICENSE="$f"; break; }
done
[ -n "$SPARKLE_LICENSE" ] || { echo "error: Sparkle LICENSE not found (resolve the package first)" >&2; exit 1; }
{ printf 'Third-party licenses\n\nSparkle 2.10.1 (https://sparkle-project.org), MIT License:\n\n'
  cat "$SPARKLE_LICENSE"; } > "$APP/Contents/Resources/ThirdPartyNotices.txt"
SPARKLE_DIR="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for bin in Sparkle Autoupdate Updater.app/Contents/MacOS/Updater; do
    archs="$(lipo -archs "$SPARKLE_DIR/$bin" 2>/dev/null || true)"
    for want in $ARCHS; do
        case " $archs " in *" $want "*) ;;
            *) echo "error: Sparkle $bin is not universal ($archs)" >&2; exit 1 ;;
        esac
    done
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Menfez</string>
    <key>CFBundleDevelopmentRegion</key> <string>en</string>
    <key>CFBundleLocalizations</key>   <array><string>en</string><string>tr</string></array>
    <key>CFBundleDisplayName</key>     <string>Menfez</string>
    <key>CFBundleIdentifier</key>      <string>com.menfez.app</string>
    <key>CFBundleVersion</key>         <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key> <string>${VERSION}</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleExecutable</key>      <string>Menfez</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>LSApplicationCategoryType</key> <string>public.app-category.utilities</string>
    <key>SUPublicEDKey</key>           <string>${SPARKLE_ED_PUBLIC_KEY}</string>
    <key>SUEnableAutomaticChecks</key> <true/>
    <key>SUAutomaticallyUpdate</key>   <true/>
    <key>SUEnableSystemProfiling</key> <false/>
</dict>
</plist>
PLIST

# AppIcon.icns is generated and committed by tools/make-icon.sh (exact-size
# slices drawn from LogoMark.swift). The sips path below is the fallback for a
# checkout without it.
if [ -f "$DIR/AppIcon.icns" ]; then
    cp "$DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
elif [ -f "$DIR/icon.png" ] && command -v iconutil >/dev/null 2>&1; then
    TMP="$(mktemp -d)"
    ICONSET="$TMP/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for s in 16 32 128 256 512; do
        sips -z "$s" "$s" "$DIR/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null 2>&1 || true
        d=$((s * 2))
        sips -z "$d" "$d" "$DIR/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null 2>&1 || true
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null || true
    rm -rf "$TMP"
fi

# Ad-hoc unless MENFEZ_SIGN_IDENTITY names a Developer ID (tools/sign.sh).
echo "==> signing (${SIGN_IDENTITY:-ad-hoc})"
xattr -cr "$APP" 2>/dev/null || true
sign_app "$APP"

# LaunchServices registers every bundle it sees, so the build copy and the
# /Applications copy of the same bundle id both show up in Launchpad. Unregister
# the build copy so only the installed one is discoverable.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
    "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
    # Re-register the installed copy, if there is one, so the icon is correct.
    [ -d "/Applications/Menfez.app" ] && "$LSREGISTER" -f "/Applications/Menfez.app" >/dev/null 2>&1 || true
fi

echo "==> done: $APP ($(du -sh "$APP" | cut -f1))"
echo
echo "Next, install it:"
echo "    ./install.sh            (DPI mode, no root)"
echo "    ./install.sh --tunnel   (also the optional WireGuard tunnel helper)"
echo
echo "Never point a sudoers rule at this build directory: it is writable by you,"
echo "so a rule naming it would hand root to whatever is put there."
