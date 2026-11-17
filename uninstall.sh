#!/bin/bash
# uninstall.sh — remove Menfez completely.
#
# "Completely" means: no app, no sudoers rule, no routes, no DNS override, no
# profiles, no state. A leftover sudoers line is the most dangerous residue
# because it keeps granting root to a path that may later be replaced by
# something else, so it is removed first and its removal is verified.
#
# Usage:  ./uninstall.sh            remove everything
#         ./uninstall.sh --keep-data  keep profiles and preferences
#         ./uninstall.sh --dry-run    show what would be removed
set -euo pipefail

APP_DST="/Applications/Menfez.app"
SUDOERS="/etc/sudoers.d/menfez"
HELPER_DIR="/Library/PrivilegedHelperTools/menfez"
# Same lookup as install.sh: under sudo, $HOME is root's.
REAL_USER="${SUDO_USER:-$(id -un)}"
REAL_HOME="$(dscl . -read "/Users/$REAL_USER" NFSHomeDirectory 2>/dev/null \
            | awk '{print $2}')"
[ -n "$REAL_HOME" ] || REAL_HOME="$HOME"
SUPPORT="$REAL_HOME/Library/Application Support/Menfez"

# The helper that can undo what it did: the root-owned install, or a 1.0.x
# copy inside a bundle install.sh made root-owned. A copy the user owns is
# never run as root.
HELPER=""
for h in "$HELPER_DIR/menfez-route" "$APP_DST/Contents/MacOS/menfez-route"; do
    if [ -x "$h" ] && [ "$(stat -f %u "$h")" = 0 ]; then HELPER="$h"; break; fi
done
STATE="/var/run/menfez"
# Persistent DNS record (1.0.2+); older releases kept it in $STATE.
DNS_DIR="/Library/Application Support/Menfez"
DRY=0
KEEP_DATA=0

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY=1 ;;
        --keep-data) KEEP_DATA=1 ;;
        -h|--help) sed -n '1,14p' "$0"; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

say() { printf '%s\n' "$*"; }
run() {
    if [ "$DRY" -eq 1 ]; then say "  would run: $*"; else "$@"; fi
}

say "Menfez uninstaller"
say ""

if [ "$DRY" -eq 1 ]; then
    say "DRY RUN — no changes will be made."
    say ""
else
    # Ask for the password once up front. Every later `sudo -n` check relies on
    # the cached credential; without it they fail and look like "not present".
    sudo -v || { say "error: sudo is required"; exit 1; }
fi

# --- 1. tear down the tunnel before removing the tool that can --------------

say "==> removing routes and the tunnel, restoring DNS"
if [ -n "$HELPER" ]; then
    # `down` removes exactly the routes recorded in the state file. If the
    # helper is already gone, fall through to the manual cleanup below.
    # Best effort: a failure here must not stop the rule from being removed.
    run sudo "$HELPER" down >/dev/null 2>&1 || say "    warning: helper 'down' failed"
    # `dns auto` puts back the resolvers recorded in dns-state.json, which is
    # why that file must outlive this step. Without a record Menfez never
    # changed DNS, and `dns auto` would wipe a resolver the user set by hand.
    if [ "$DRY" -eq 1 ] || sudo test -f "$DNS_DIR/dns-state.json" 2>/dev/null \
        || sudo test -f "$STATE/dns-state.json" 2>/dev/null; then
        run sudo "$HELPER" dns auto >/dev/null 2>&1 \
            || say "    warning: DNS restore failed; check System Settings > Network > DNS"
    fi
fi

# Belt and braces: the helper may be missing, root-owned state may be stale, or
# a previous crash may have left routes behind. Remove the known prefixes
# directly. Deleting a route that is not there is harmless.
for cidr in 162.159.128.0/18 162.159.192.0/24 0.0.0.0/1 128.0.0.0/1; do
    run sudo -n /sbin/route -n delete -net "$cidr" >/dev/null 2>&1 || true
done
for cidr in ::/1 8000::/1; do
    run sudo -n /sbin/route -n delete -inet6 "$cidr" >/dev/null 2>&1 || true
done

# The helper's `down` removes routes but not the WireGuard interface. Stop
# Menfez's own tunnels by removing their control socket, which makes
# wireguard-go exit. This never runs wg-quick, so no PostDown hook runs as root.
for name in wgmanaged wgsplit; do
    nf="/var/run/wireguard/$name.name"
    [ -e "$nf" ] || continue
    iface="$(sudo -n cat "$nf" 2>/dev/null || true)"
    case "$iface" in
        utun[0-9]|utun[0-9][0-9]|utun[0-9][0-9][0-9])
            run sudo -n rm -f "/var/run/wireguard/$iface.sock" "$nf"
            say "    stopped tunnel $iface ($name)" ;;
        *) say "    warning: unexpected interface name in $nf; left alone" ;;
    esac
done

# --- 2. quit the app -------------------------------------------------------

say "==> quitting Menfez if it is running"
if pgrep -f "Menfez.app/Contents/MacOS/Menfez" >/dev/null 2>&1; then
    run osascript -e 'tell application "Menfez" to quit' >/dev/null 2>&1 || true
    sleep 1
    if pgrep -f "Menfez.app/Contents/MacOS/Menfez" >/dev/null 2>&1; then
        run pkill -f "Menfez.app/Contents/MacOS/Menfez" || true
    fi
fi

# --- 3. sudoers: remove first, verify after --------------------------------

say "==> removing the sudoers rule"
# /etc/sudoers.d is world-listable, so existence needs no root.
if [ -e "$SUDOERS" ]; then
    run sudo rm -f "$SUDOERS"
    if [ "$DRY" -eq 0 ]; then
        if [ -e "$SUDOERS" ]; then
            say "error: could not remove $SUDOERS — remove it by hand:"
            say "  sudo rm $SUDOERS"
            exit 1
        fi
        # A broken sudoers file can lock the machine out of sudo, so re-validate
        # after the removal rather than assuming it is fine.
        if ! sudo visudo -c >/dev/null 2>&1; then
            say "warning: sudo reports a problem after removing the rule; check with: sudo visudo -c"
        fi
        say "    removed"
    fi
else
    say "    not present"
fi

say "==> removing the root-owned helper and tools"
if [ -d "$HELPER_DIR" ]; then
    run sudo rm -rf "$HELPER_DIR"
else
    say "    not present"
fi

# --- 4. the app ------------------------------------------------------------

say "==> removing the app"
if [ -d "$APP_DST" ]; then
    run sudo rm -rf "$APP_DST"   # root-owned after install.sh
else
    say "    not present"
fi

# --- 5. state ---------------------------------------------------------------

say "==> removing runtime state"
if [ -d "$STATE" ] || [ -d "$DNS_DIR" ]; then
    run sudo rm -rf "$STATE" "$DNS_DIR"
else
    say "    not present"
fi

# --- 6. user data ----------------------------------------------------------

if [ "$KEEP_DATA" -eq 1 ]; then
    say "==> keeping $SUPPORT (--keep-data)"
else
    say "==> removing profiles and preferences"
    if [ -d "$SUPPORT" ]; then
        run rm -rf "$SUPPORT"
    else
        say "    not present"
    fi
    for p in "$REAL_HOME/Library/Preferences/com.menfez.app.plist" \
             "$REAL_HOME/Library/Preferences/Menfez.plist"; do
        [ -e "$p" ] && run rm -f "$p"
    done
    run defaults delete com.menfez.app >/dev/null 2>&1 || true
    run rm -f /tmp/menfez-trace.log /tmp/menfez-probe.log /tmp/menfez-spawn.log
    run rm -rf "$REAL_HOME/Library/Logs/Menfez"
fi

# --- 7. verify -------------------------------------------------------------

if [ "$DRY" -eq 0 ]; then
    say ""
    say "==> verifying"
    problems=0
    [ -d "$APP_DST" ] && { say "    still present: $APP_DST"; problems=1; }
    [ -e "$SUDOERS" ] && { say "    still present: $SUDOERS"; problems=1; }
    [ -d "$HELPER_DIR" ] && { say "    still present: $HELPER_DIR"; problems=1; }
    if netstat -rn -f inet 2>/dev/null | grep -qE "162\.159\.(128|192)"; then
        say "    routes still present:"
        netstat -rn -f inet | grep -E "162\.159\.(128|192)" | sed 's/^/      /'
        problems=1
    fi
    pgrep -f "Menfez.app/Contents/MacOS/Menfez" >/dev/null 2>&1 && {
        say "    Menfez is still running"; problems=1; }
    if [ "$problems" -eq 0 ]; then
        say "    clean"
    else
        say ""
        say "Some items remain. Re-run with sudo, or remove them by hand."
        exit 1
    fi
fi

say ""
say "Done."
