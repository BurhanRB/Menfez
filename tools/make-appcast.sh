#!/bin/bash
# make-appcast.sh — write the two Sparkle appcasts for a finished release.
#
#   ./tools/make-appcast.sh            # version read from Menfez.app
#   ./tools/make-appcast.sh 1.0.6
#
# Run after build-dmg.sh (the dmgs must be the stapled ones: stapling changes
# the bytes, and the EdDSA signature covers the bytes). Writes
# appcast/appcast-arm64.xml and appcast/appcast-intel.xml, each with one item:
# the newest release for that architecture. Sparkle only needs the newest.
#
# The EdDSA private key never leaves the login keychain: sign_update reads it
# there (account "menfez", made once with generate_keys --account menfez).
# Each signature is verified again before the file is written.
#
# Publishing (docs/SIGNING.md, "Sparkle"): upload both dmgs to the GitHub
# release v<version>, then commit the two appcasts to the root of the public
# repo's main branch. The app reads
#   https://raw.githubusercontent.com/BurhanRB/Menfez/main/appcast-<arch>.xml
#
# Overrides, for the local end-to-end test only:
#   MENFEZ_DMG_DIR      where the dmgs are            (default: macos/)
#   MENFEZ_URL_PREFIX   download URL before the name  (default: the release)
#   MENFEZ_APPCAST_OUT  output directory              (default: macos/appcast)
#   MENFEZ_ED_KEY_FILE  sign with this key file instead of the keychain
#   MENFEZ_NOTES_VERSION  Changelog entry to use as notes (default: VERSION)
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DIR/Menfez.app/Contents/Info.plist")}"
DMG_DIR="${MENFEZ_DMG_DIR:-$DIR}"
PREFIX="${MENFEZ_URL_PREFIX:-https://github.com/BurhanRB/Menfez/releases/download/v$VERSION/}"
OUT="${MENFEZ_APPCAST_OUT:-$DIR/appcast}"
BIN="$DIR/Menfez/.build/artifacts/sparkle/Sparkle/bin"
KEY=(--account menfez)
[ -n "${MENFEZ_ED_KEY_FILE:-}" ] && KEY=(--ed-key-file "$MENFEZ_ED_KEY_FILE")

if [ ! -x "$BIN/sign_update" ]; then
    ( cd "$DIR/Menfez" && swift package resolve >/dev/null )
fi
[ -x "$BIN/sign_update" ] || { echo "error: Sparkle's sign_update not found in $BIN" >&2; exit 1; }

# The release notes: the Changelog entry for this version, both languages.
notes_html() {
    python3 -I - "$DIR/Menfez/Sources/MenfezCore/Changelog.swift" "${MENFEZ_NOTES_VERSION:-$VERSION}" <<'PY'
import html, re, sys
src, version = open(sys.argv[1], encoding="utf-8").read(), sys.argv[2]
start = src.find('version: "%s"' % version)
if start < 0:
    sys.exit("error: no Changelog entry for " + version)
end = src.find("ChangelogEntry(", start)
block = src[start:end if end > 0 else len(src)]
def items(lang):
    part = re.search(lang + r":\s*\[(.*?)\]", block, re.S).group(1)
    return [html.escape(s.replace('\\"', '"'), quote=False) for s in re.findall(r'"((?:[^"\\]|\\.)*)"', part)]
out = []
for title, lang in (("Yenilikler", "tr"), ("What's new", "en")):
    out.append("<h3>%s</h3><ul>%s</ul>" % (title, "".join("<li>%s</li>" % i for i in items(lang))))
print("".join(out))
PY
}

NOTES="$(notes_html)"
mkdir -p "$OUT"

for arch in arm64 intel; do
    name="Menfez-$VERSION-$arch.dmg"
    dmg="$DMG_DIR/$name"
    [ -f "$dmg" ] || { echo "error: missing $dmg (run build-dmg.sh first)" >&2; exit 1; }
    # Prints: sparkle:edSignature="..." length="..."
    attrs="$("$BIN/sign_update" "${KEY[@]}" "$dmg")"
    sig="$(echo "$attrs" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
    [ -n "$sig" ] || { echo "error: sign_update gave no signature for $name" >&2; exit 1; }
    "$BIN/sign_update" "${KEY[@]}" --verify "$dmg" "$sig" >/dev/null \
        || { echo "error: signature for $name does not verify" >&2; exit 1; }
    cat > "$OUT/appcast-$arch.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Menfez ($arch)</title>
    <item>
      <title>Menfez $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <description><![CDATA[$NOTES]]></description>
      <enclosure url="$PREFIX$name" type="application/octet-stream" $attrs/>
    </item>
  </channel>
</rss>
XML
    xmllint --noout "$OUT/appcast-$arch.xml"
    echo "    $OUT/appcast-$arch.xml  ($name, signature verified)"
done
