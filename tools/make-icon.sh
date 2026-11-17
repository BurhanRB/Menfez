#!/bin/bash
# make-icon.sh — regenerate icon.png and AppIcon.icns from
# Menfez/Sources/MenfezCore/LogoMark.swift (the same code draws the menu-bar
# icon at runtime). Deterministic: run it after changing LogoMark.swift and
# commit both outputs. Pass a directory to also keep the iconset and the
# menu-bar previews there.
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
XCODE="/Applications/Xcode.app/Contents/Developer"
[ -d "$XCODE" ] && export DEVELOPER_DIR="$XCODE"

WORK="${1:-$(mktemp -d)}"
mkdir -p "$WORK"
swiftc -O -o "$WORK/make-icon" \
    "$DIR/Menfez/Sources/MenfezCore/LogoMark.swift" "$DIR/tools/icon/main.swift"
"$WORK/make-icon" "$WORK"
iconutil -c icns "$WORK/AppIcon.iconset" -o "$DIR/AppIcon.icns"
cp "$WORK/icon.png" "$DIR/icon.png"
echo "wrote $DIR/icon.png and $DIR/AppIcon.icns (previews in $WORK)"
