# sign.sh — signing shared by build-app.sh and build-dmg.sh. Sourced, not run.
#
#   MENFEZ_SIGN_IDENTITY   "Developer ID Application: <Name> (<TEAMID>)".
#                          Unset: ad-hoc, exactly as before.
#   MENFEZ_NOTARY_PROFILE  keychain profile made once with
#                          `xcrun notarytool store-credentials <name> ...`.
#                          Unset: no notarisation. Needs MENFEZ_SIGN_IDENTITY.
#
# Nothing here names an identity, an Apple ID or a password; they come only
# from the environment and the keychain. See docs/SIGNING.md, "Release checklist".
#
# Developer ID signing is inside-out and never --deep: Sparkle's helpers
# (Autoupdate, Updater.app), Sparkle.framework, menfez-route, then the app,
# then (build-dmg.sh) the dmg. Hardened runtime and a secure timestamp are
# what notarisation requires. No entitlements file: the app is not sandboxed
# and only spawns system tools; the one third-party library, Sparkle, is
# signed here with the same identity, so library validation passes. Sparkle's
# XPC services are removed by build-app.sh (they serve sandboxed apps only).

SIGN_IDENTITY="${MENFEZ_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${MENFEZ_NOTARY_PROFILE:-}"

if [ -n "$NOTARY_PROFILE" ] && [ -z "$SIGN_IDENTITY" ]; then
    echo "error: MENFEZ_NOTARY_PROFILE is set but MENFEZ_SIGN_IDENTITY is not;" >&2
    echo "       Apple notarises only Developer ID signed code" >&2
    exit 1
fi

# $1 = path to Menfez.app
sign_app() {
    local app="$1"
    if [ -z "$SIGN_IDENTITY" ]; then
        codesign --force --deep --sign - "$app" >/dev/null 2>&1 || \
            echo "    warning: ad-hoc signing failed; right-click Open may be needed"
        return 0
    fi
    echo "    signing with: $SIGN_IDENTITY"
    local fw="$app/Contents/Frameworks/Sparkle.framework"
    if [ -d "$fw" ]; then
        local item
        for item in "$fw/Versions/B/Autoupdate" "$fw/Versions/B/Updater.app" "$fw"; do
            codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$item"
        done
    fi
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" \
        "$app/Contents/MacOS/menfez-route"
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$app"
    codesign --verify --strict --verbose=2 "$app"
}

# $1 = path to the dmg
sign_dmg() {
    local dmg="$1"
    if [ -z "$SIGN_IDENTITY" ]; then
        codesign --force --sign - "$dmg" >/dev/null 2>&1 || true
        return 0
    fi
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$dmg"
    codesign --verify --strict --verbose=2 "$dmg"
}

# $1 = path to the signed dmg, $2 = the app that went into it.
# Submits, waits, staples, then asks Gatekeeper about both.
notarise_dmg() {
    local dmg="$1" app="$2"
    [ -n "$NOTARY_PROFILE" ] || return 0
    echo "    notarising (this waits for Apple)"
    local out
    out="$(xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait --timeout "${MENFEZ_NOTARY_TIMEOUT:-25m}" 2>&1)" || true
    echo "$out" | sed 's/^/    /'
    # --wait can end with status Invalid; only Accepted may be stapled.
    if ! echo "$out" | grep -q "status: Accepted"; then
        echo "error: notarisation was not accepted; see: xcrun notarytool log <id> --keychain-profile \"$NOTARY_PROFILE\"" >&2
        return 1
    fi
    xcrun stapler staple "$dmg"
    xcrun stapler validate "$dmg"
    spctl -a -vvv -t open --context context:primary-signature "$dmg"
    spctl -a -vvv -t exec "$app"
}
