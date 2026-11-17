#!/bin/bash
# install.sh — install Menfez and grant its helper the narrowest possible root
# permission.
#
# Design decisions worth knowing before you change anything here:
#
#   1. The sudoers rule names ONE absolute path, with no wildcards and no
#      shell: /Library/PrivilegedHelperTools/menfez/menfez-route. It has no
#      argument list, which in sudoers means ANY arguments are allowed; the
#      helper itself validates every subcommand and value it accepts.
#      install-helper.sh copies the helper there, together with root-owned
#      copies of wg, wg-quick, wireguard-go and bash from Homebrew, so neither
#      the binary the rule trusts nor any tool it runs as root sits in a
#      directory the user can write (an app bundle or /opt/homebrew).
#
#   2. `visudo -c` is run after writing, and the file is removed again if the
#      syntax check fails. A malformed sudoers file can lock you out of sudo
#      entirely; validating before leaving it in place is what prevents that.
#
#   3. Nothing is installed until the user has seen exactly what will be added
#      to their system. The user runs this script; it does not run itself.
#
#   4. The sudoers grant is OPTIONAL. The app's default DPI mode is a proxy
#      inside the app process and needs no root, so the copy alone produces a
#      working app. Only the WireGuard tunnel needs the helper, and enabling
#      that is a separate decision (`--tunnel`) with its own visible rule.
#
# Usage:  ./install.sh            install or upgrade (DPI mode works, no root)
#         ./install.sh --tunnel   also grant the helper its narrow permission
#         ./install.sh --dry-run  show every change, touch nothing
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

# Resolve the invoking user's home even when this script is run through sudo,
# where $HOME points at root's. Writing profiles into /var/root would create
# files the app (running as the user) cannot read.
REAL_USER="${SUDO_USER:-$(id -un)}"
REAL_HOME="$(dscl . -read "/Users/$REAL_USER" NFSHomeDirectory 2>/dev/null \
            | awk '{print $2}')"
[ -n "$REAL_HOME" ] || REAL_HOME="$HOME"
APP_SRC="$DIR/Menfez.app"
APP_DST="/Applications/Menfez.app"
SUDOERS="/etc/sudoers.d/menfez"
HELPER_REL="Contents/MacOS/menfez-route"
TRUSTED_HELPER="/Library/PrivilegedHelperTools/menfez/menfez-route"
DRY=0
WITH_TUNNEL=0

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY=1 ;;
        --tunnel) WITH_TUNNEL=1 ;;
        -h|--help) sed -n '1,30p' "$0"; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

say() { printf '%s\n' "$*"; }
run() {
    if [ "$DRY" -eq 1 ]; then
        say "  would run: $*"
        return 0
    fi
    "$@" || { say "  error: command failed: $*"; exit 1; }
}

# Same, but elevated. The bundle must end up owned by root: the sudoers rule
# grants root to a binary inside it, so a user-writable bundle would let the
# user replace that binary and inherit the grant.
run_root() {
    if [ "$DRY" -eq 1 ]; then
        say "  would run: sudo $*"
        return 0
    fi
    sudo "$@" || { say "  error: command failed: sudo $*"; exit 1; }
}

# --- preflight -------------------------------------------------------------

say "Menfez installer"
say ""

if [ ! -d "$APP_SRC" ]; then
    say "error: Menfez.app not found next to this script."
    say "       Build it first with ./build-app.sh"
    exit 1
fi

if [ ! -x "$APP_SRC/$HELPER_REL" ]; then
    say "error: the privileged helper is missing from the bundle."
    exit 1
fi

if [ "$WITH_TUNNEL" -eq 1 ] && [ ! -f "$DIR/install-helper.sh" ]; then
    say "error: install-helper.sh not found next to this script."
    exit 1
fi

# Refuse to touch a system that already has a Menfez running from somewhere
# else: two copies would fight over the same sudoers path.
RUNNING="$(pgrep -f "Menfez.app/Contents/MacOS/Menfez" || true)"
if [ -n "$RUNNING" ]; then
    say "Menfez is running (pid $RUNNING). Quit it first."
    exit 1
fi

say "This will:"
say "  1. copy Menfez.app to $APP_DST"
if [ "$WITH_TUNNEL" -eq 1 ]; then
    say "  2. copy the helper and Homebrew's wg, wg-quick, wireguard-go and bash"
    say "     into /Library/PrivilegedHelperTools/menfez (root-owned)"
    say "  3. create $SUDOERS granting your account passwordless root for exactly:"
    say "       $TRUSTED_HELPER"
fi
say ""
say "Nothing else is touched. Uninstall with ./uninstall.sh"
say ""

if [ "$DRY" -eq 1 ]; then
    say "DRY RUN — no changes will be made."
else
    read -r -p "Continue? [y/N] " answer
    case "$answer" in
        [yY]*) ;;
        *) say "cancelled"; exit 0 ;;
    esac
fi

# --- install the app -------------------------------------------------------

say ""
say "==> installing the app"
if [ -d "$APP_DST" ]; then
    say "    replacing the existing copy"
    run_root rm -rf "$APP_DST"
fi
run cp -R "$APP_SRC" "$APP_DST"

# The bundle must be owned by root and not writable by the user, otherwise the
# sudoers rule trusts a binary the user could swap.
run_root chown -R root:wheel "$APP_DST"
run_root chmod -R go-w "$APP_DST"

# --- sudoers ---------------------------------------------------------------
#
# OPTIONAL BY DEFAULT.
#
# The app's default path needs no root at all: the DPI proxy is a listener
# inside the app process, so a fresh install is fully usable after the copy
# above. Only the optional WireGuard tunnel needs this grant, and a stranger
# deciding whether to trust a downloaded app should not have to edit sudoers
# before the first useful click. So the grant is offered, not imposed:
#
#   ./install.sh            copy the app, grant nothing, mention the option
#   ./install.sh --tunnel   also grant the helper its narrow root permission
#
# The rule is unchanged and stays the narrowest thing that works: ONE absolute
# path (any arguments: the helper validates them), no wildcards, validated
# with `visudo -c` before it lands.

if [ "${WITH_TUNNEL:-0}" -eq 0 ]; then
    say ""
    say "==> skipping the privileged helper (DPI mode needs no root)"
    say "    the WireGuard tunnel is optional; to enable it later run:"
    say "      $0 --tunnel"
    say "    or apply the one-time setup shown in the app's Help panel."
else
    say ""
    say "==> granting the helper its narrow root permission"

    # The rule is written with the invoking user's name, resolved now, not
    # "$USER" at sudo time.
    TARGET_USER="$REAL_USER"
    say "    user: $TARGET_USER"
    say "    path: $TRUSTED_HELPER"

    if [ "$DRY" -eq 1 ]; then
        say "    would install:"
        /bin/bash "$DIR/install-helper.sh" --print-sudoers "$TARGET_USER" | sed 's/^/      /'
    fi
    # install-helper.sh copies from the root-owned bundle installed above,
    # validates the rule with `visudo -c -f` before it lands and re-checks
    # `visudo -c` after, removing the file if sudo would no longer parse.
    run_root /bin/bash "$DIR/install-helper.sh" "$APP_DST/$HELPER_REL" "$TARGET_USER"
fi

# --- profiles directory ----------------------------------------------------

say ""
say "==> preparing the profile directory"
PROFILE_DIR="$REAL_HOME/Library/Application Support/Menfez/wireguard"
run mkdir -p "$PROFILE_DIR"
# 0700: the directory holds files with private keys. Filenames alone would
# leak which servers a user connects to.
run chown -R "$REAL_USER" "$REAL_HOME/Library/Application Support/Menfez" 2>/dev/null || true
run chmod 700 "$REAL_HOME/Library/Application Support/Menfez" "$PROFILE_DIR"

# --- verify ----------------------------------------------------------------

if [ "$DRY" -eq 0 ]; then
    say ""
    say "==> verifying"
    if [ "${WITH_TUNNEL:-0}" -eq 0 ]; then
        # Nothing privileged was installed, so there is nothing to verify. The
        # app's own `status` would need the grant that was deliberately skipped.
        say "    app installed; no privileged helper was configured"
    elif sudo -n "$TRUSTED_HELPER" status >/dev/null 2>&1; then
        say "    helper runs without a password: ok"
    else
        say "    warning: the helper did not run. Check $SUDOERS and re-run."
        exit 1
    fi
fi

say ""
say "Done. Open Menfez from /Applications."
say ""
say "Discord works straight away: press \"Enable Discord\" in the app."
say "That path needs no root, no sudo and no password."
if [ "${WITH_TUNNEL:-0}" -eq 0 ]; then
    say ""
    say "The WireGuard tunnel is optional. To enable it later:"
    say "    $0 --tunnel"
fi
say ""
say "Drop any WireGuard .conf file into:"
say "  $PROFILE_DIR"
say "or use the server menu once the app is open."
