#!/bin/bash
# install-helper.sh — install the tunnel helper where only root can change it,
# and grant one user passwordless sudo for exactly that path.
#
# Why a separate root-owned copy: the sudoers rule makes whatever sits at the
# granted path run as root. A binary inside a user-owned app bundle, or a
# WireGuard tool in a user-owned /opt/homebrew, can be swapped by that user.
# So the helper and the tools it runs as root (wg, wg-quick, wireguard-go and
# a bash >= 4 for wg-quick) are copied once, here, into
#
#   /Library/PrivilegedHelperTools/menfez/            root:wheel 0755
#     menfez-route                                    root:wheel 0755
#     bin/{wg,wg-quick,wireguard-go,bash}             root:wheel 0755
#     lib/<dylibs Homebrew's bash links against>      root:wheel 0644
#
# and the helper refuses to run any tool as root from anywhere else.
#
# Used by install.sh --tunnel, by the app's "Set up tunnel" button (through
# macOS's own administrator password dialog) and by the command in its Help.
#
# Usage:  sudo /bin/bash install-helper.sh <path to menfez-route> <user>
#         sudo /bin/bash install-helper.sh --remove   take the tunnel down, remove
#                                                     the rule and the helper only
#         install-helper.sh --print-sudoers <user>   print the rule, change nothing
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin

DEST=/Library/PrivilegedHelperTools/menfez
SUDOERS=/etc/sudoers.d/menfez
TOOLS="wg wg-quick wireguard-go bash"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

valid_user() { [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] && [ "$1" != root ]; }

rule() {
    cat <<EOF
# Menfez — privileged helper for the WireGuard split tunnel.
#
# Installed by install-helper.sh. Remove with uninstall.sh.
#
# This grants ONE command, by absolute path, with no arguments and no wildcards.
# The binary and every directory above it are owned by root, so the user it is
# granted to cannot replace it.
#
# The app works without this file: its default DPI mode needs no root.
$1 ALL=(root) NOPASSWD: $DEST/menfez-route
EOF
}

if [ "${1:-}" = "--print-sudoers" ]; then
    valid_user "${2:-}" || die "invalid user name"
    rule "$2"
    exit 0
fi

# The helper only: the app, profiles and preferences stay (uninstall.sh removes
# everything). The rule goes first, since it is the part that grants root.
if [ "${1:-}" = "--remove" ]; then
    [ "$(id -u)" -eq 0 ] || die "run this with sudo"
    if [ -x "$DEST/menfez-route" ] && [ "$(stat -f %u "$DEST/menfez-route")" = 0 ]; then
        # `teardown` also stops the interface; a helper older than it only knows `down`.
        "$DEST/menfez-route" teardown >/dev/null 2>&1 \
            || "$DEST/menfez-route" down >/dev/null 2>&1 \
            || echo "warning: could not take the tunnel down" >&2
        # Only with a record: without one Menfez never changed DNS.
        if [ -f "/Library/Application Support/Menfez/dns-state.json" ] \
            || [ -f /var/run/menfez/dns-state.json ]; then
            "$DEST/menfez-route" dns auto >/dev/null 2>&1 || echo "warning: could not restore DNS" >&2
        fi
    fi
    echo "==> removing $SUDOERS and $DEST"
    rm -f "$SUDOERS"
    [ ! -e "$SUDOERS" ] || die "could not remove $SUDOERS"
    visudo -c >/dev/null 2>&1 || echo "warning: sudo reports a problem; check with: sudo visudo -c" >&2
    rm -rf "$DEST"
    echo "==> done"
    exit 0
fi

[ "$#" -eq 2 ] || die "usage: sudo /bin/bash $0 <menfez-route> <user>"
SRC="$1"
TARGET_USER="$2"
[ "$(id -u)" -eq 0 ] || die "run this with sudo"
valid_user "$TARGET_USER" && id "$TARGET_USER" >/dev/null 2>&1 \
    || die "unknown user: $TARGET_USER"
[ -f "$SRC" ] && [ -x "$SRC" ] || die "helper not found: $SRC"

# --- find the WireGuard toolchain (read once, as the user installed it) -------

BREW=""
for d in /opt/homebrew/bin /usr/local/bin; do
    if [ -x "$d/wg-quick" ]; then BREW="$d"; break; fi
done
[ -n "$BREW" ] || die "WireGuard tools not found. Install them first: brew install wireguard-tools wireguard-go bash"
for t in $TOOLS; do
    [ -x "$BREW/$t" ] || die "$BREW/$t is missing. Install it: brew install wireguard-tools wireguard-go bash"
done
"$BREW/bash" -c '[ "${BASH_VERSINFO[0]}" -ge 4 ]' \
    || die "$BREW/bash is older than 4; wg-quick needs bash >= 4 (brew install bash)"

# --- copy -----------------------------------------------------------------------

echo "==> installing the helper and its tools into $DEST"
rm -rf "$DEST"
install -d -o root -g wheel -m 0755 "$DEST" "$DEST/bin" "$DEST/lib"
install -o root -g wheel -m 0755 "$SRC" "$DEST/menfez-route"
for t in $TOOLS; do
    # install(1) follows Homebrew's symlinks and copies the real file.
    install -o root -g wheel -m 0755 "$BREW/$t" "$DEST/bin/$t"
done

# Homebrew's bash loads readline and friends from /opt/homebrew, which the user
# can write. Copy every non-system dylib next to it and point the binary there.
bundle_libs() {
    local f="$1" dep name
    for dep in $(otool -L "$f" | tail -n +2 | awk '{print $1}'); do
        case "$dep" in /usr/lib/*|/System/*|@*) continue ;; esac
        name="$(basename "$dep")"
        if [ ! -f "$DEST/lib/$name" ]; then
            install -o root -g wheel -m 0644 "$dep" "$DEST/lib/$name"
            install_name_tool -id "@executable_path/../lib/$name" "$DEST/lib/$name" 2>/dev/null
            bundle_libs "$DEST/lib/$name"
        fi
        install_name_tool -change "$dep" "@executable_path/../lib/$name" "$f" 2>/dev/null
    done
}
for t in wg wireguard-go bash; do bundle_libs "$DEST/bin/$t"; done

# install_name_tool invalidates the signature; arm64 refuses unsigned code.
for f in "$DEST"/bin/wg "$DEST"/bin/wireguard-go "$DEST"/bin/bash "$DEST"/lib/*; do
    [ -f "$f" ] || continue
    codesign --force --sign - "$f" >/dev/null 2>&1 || die "could not re-sign $f"
done

# wg-quick must start the copied bash, not whatever `env bash` finds.
head -1 "$DEST/bin/wg-quick" | grep -q '^#!' || die "$DEST/bin/wg-quick is not a script"
sed -i '' "1s|.*|#!$DEST/bin/bash|" "$DEST/bin/wg-quick"

# Nothing root runs may still reach into a user-writable prefix.
for f in "$DEST"/bin/wg "$DEST"/bin/wireguard-go "$DEST"/bin/bash "$DEST"/lib/*; do
    [ -f "$f" ] || continue
    if otool -l "$f" | grep -qE '/opt/homebrew|/usr/local'; then
        rm -rf "$DEST"
        die "$f still references a Homebrew path; nothing was installed"
    fi
done
"$DEST/bin/bash" -c '[ "${BASH_VERSINFO[0]}" -ge 4 ]' \
    || { rm -rf "$DEST"; die "the copied bash does not run; nothing was installed"; }

# --- sudoers ----------------------------------------------------------------------

echo "==> granting $TARGET_USER passwordless root for $DEST/menfez-route"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
rule "$TARGET_USER" > "$TMP"
# Validate in isolation first: a broken file in sudoers.d breaks sudo for everyone.
visudo -c -f "$TMP" >/dev/null || die "the sudoers rule failed validation; $SUDOERS unchanged"
install -m 0440 -o root -g wheel "$TMP" "$SUDOERS"
if ! visudo -c >/dev/null 2>&1; then
    rm -f "$SUDOERS"
    die "sudo no longer parses after installing the rule; it was removed"
fi

echo "==> done"
