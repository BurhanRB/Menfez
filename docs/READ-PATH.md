# The read path

How Menfez observes the machine, why it used to cost a root process every five
seconds, and what it costs now. Written after measuring on the development
machine (macOS 14, Apple silicon, a live ProtonVPN `utun5`) rather than from
first principles.

## 1. What actually needs root

Measured as uid 501, with `utun5` up and managed by this app. "Works" means the
command produced real output; "denied" means `Permission denied`.

| Command | Needs root? | Evidence |
|---|---|---|
| `wg show interfaces` | **no** | prints `utun5`, rc=0. It enumerates `/var/run/wireguard`, which is `drwxr-xr-x root daemon`. |
| `wg show utun5 latest-handshakes` | **yes** | `Unable to access interface: Permission denied`, rc=1. Opens `/var/run/wireguard/utun5.sock`, which is `srwx------ root daemon`. |
| `wg show utun5 endpoints` | **yes** | same denial |
| `wg show utun5 peers` | **yes** | same denial |
| `wg show utun5 transfer` | **yes** | same denial |
| `route -n get default` | **no** | prints `gateway: 192.168.1.1 / interface: en0`, rc=0 |
| `route -n get -net <cidr>` | **no** | prints the entry, or `not in table` **with rc=0** — presence must be read from the output, not the status |
| `networksetup -listnetworkserviceorder` | **no** | prints the service list, rc=0 |
| `networksetup -getdnsservers Wi-Fi` | **no** | prints `1.1.1.1 / 1.0.0.1`, rc=0 |
| `ifconfig utun5` | **no** | rc=0 |
| `ipconfig getifaddr en0` | **no** | prints `192.168.1.2`, rc=0 |
| `curl` (ipify, ipinfo, discord) | **no** | ~180 ms round trip |
| `dig` | **no** | used only by the DNS sheet |

**Conclusion.** Of the twelve values in `Report`, exactly five need root, and
they are all the same thing: `wg show <iface>`. Everything else — the interface
list, health-by-existence, every route, the resolver, the gateway, the local
address — is readable as the user. The old design paid for root to get five
numbers and threw in eleven free ones it could have read itself.

This is why `RouteManager.TunnelFacts` is a separate type: it is the complete
list of privileged reads, and anything added to it is a change to this table.

## 2. Designs rejected

### B. Long-lived root daemon (rejected)

A launchd daemon started once, speaking a unix socket.

Rejected on attack surface, not on effort. Today the privileged code exists only
while one command runs, and the sudoers rule names one file inside a root-owned
bundle. A daemon would keep a root process resident for the whole login session,
listening on a socket. That socket becomes the target: mode 0600 on the socket
file helps, but `LOCAL_PEERCRED` checks have to be written correctly to be worth
anything, and a bug there is a local privilege escalation on a stranger's
machine. It also needs a `LaunchDaemon` plist and a second install path, so the
"one line in sudoers" property — the thing that makes the current grant easy to
audit — would be replaced by a grant plus a service plus a protocol.

The benefit would have been avoiding ~6 process spawns per 25 seconds. That is
not worth a permanently listening root process. It would become the right answer
only if mutations needed to be called many times per second, which they never
are: they happen when a person clicks.

### A. Split the read path, nothing else (rejected as incomplete)

Read everything unprivileged, call the helper only for the five privileged
values, at the same 5-second rate.

This fixes the worst of the cost but leaves a root process on a timer. It also
leaves the app with no answer to "the window is in the background": the timer
would keep firing and keep exercising the sudo grant for a window nobody is
looking at.

## 3. Chosen design — C, the hybrid

Two paths, split by what they need:

**Fast path (`ReportBuilder.buildLocal`).** Runs entirely in the app process.
Starts eight short-lived unprivileged commands (down from forty-two including
children), no `sudo`, no `wg show <iface>`. Every field it cannot fill is left
`nil` and drawn as a dash. `Health.code` is `.unknown` until the privileged half
arrives, so the UI says "checking" rather than claiming "tunnel down".

Why eight and not zero: the data has to come from somewhere. `route -n get`
reports the gateway and the interface, `networksetup` reports the service and
its resolvers, `ifconfig` decides whether the utun still exists, `ipconfig`
reports the local address, and `wg show interfaces` reports which utun is up.
All of them are reads; none of them needs root; all of them finish in ~78 ms
together.

**Privileged path (`menfez-route facts`).** One new subcommand, four `wg` reads,
one JSON object. Called at most once per 25 seconds, and **only while the
window is frontmost or a mode change is settling**. It carries no state, takes
no arguments, and is the same sudoers path as every other command.

Why 25 seconds: ProtonVPN configs use a 25-second keepalive, so the handshake
epoch cannot change faster than that. A faster read would only confirm the same
number.

Why the age is still live: `facts` returns the **epoch**, not the age. The app
computes `now - epoch` on every redraw, so the "last handshake" row moves even
though the underlying fact is 25 seconds old. Sending a pre-computed age would
freeze that row for up to 25 seconds, which is the kind of stale number that
makes a user think the tunnel died.

### Timer behaviour

| State | Tick | Privileged read |
|---|---|---|
| Frontmost | 2 s | every 25 s |
| Mode change settling (8 s) | 2 s | once, after the mutation |
| Background | 15 s | never |

The rates come from `Model.currentInterval`, driven by
`NSApplication.didBecomeActiveNotification` / `didResignActiveNotification`.
`scenePhase` was not used: this is a single-window `WindowGroup`, and the
AppKit notifications fire for the whole app, which is the thing that actually
changes when the user switches away.

There is no zero case. A hidden window still has to notice a tunnel that died,
and the local tick is cheap enough that stopping it would trade a real safety
signal for 0.4% of a core.

### First paint

`Model.init` calls `buildLocal()` synchronously — about 80 ms — and only then
schedules the first `facts` call on the next runloop turn. The window appears
with every unprivileged row filled and dashes where the privileged ones will
land. Nothing waits for `sudo`.

### What happens when the helper is missing

| Failure | Behaviour |
|---|---|
| No sudoers rule | `sudo -n` exits non-zero, `facts()` returns nil, privileged rows stay dashes. The card still renders. |
| Helper binary deleted | same |
| Helper older than the app | exits 2 on `facts`, so `HelperClient` falls back to `report --fast` — the old cost, once per 25 s, not per redraw |
| Helper newer than the app | never asks for `facts`; the extra subcommand is simply unused |

The fallback is keyed on exit status 2 only. Exit 1 is a real failure and must
not be retried with a different command, or a genuine problem would be hidden
behind a second attempt.

## 4. Spawn counts

Measured, not estimated. `swift test --filter SpawnBudgetTests` drives the exact
functions each path calls through a runner that records instead of starting
them, so the count includes children a process-tree walk would miss. The
`sudo` and helper processes themselves cannot be recorded that way, so they are
added as the constant 6 per privileged call (sudo + helper + 4 `wg`).

```
one UI refresh, process spawns
─────────────────────────────────────────────────────────────
BEFORE  report --fast children          13
BEFORE  profiles children                2
BEFORE  dns status children             27
BEFORE  children per refresh            42
BEFORE  sudo + helper per refresh        6
BEFORE  privileged spawns per refresh    8
─────────────────────────────────────────────────────────────
AFTER   children per fast tick           8
AFTER   privileged spawns per tick       0
```

**30 seconds of idle, window frontmost** (the old 5 s tick, the new 2 s tick):

| | Processes | Root |
|---|---|---|
| Before | 6 × 48 = **288** | **18** |
| After | 15 × 8 + 1 facts call = **126** | **1** |

**30 seconds of idle, window in the background:**

| | Processes | Root |
|---|---|---|
| Before | 6 × 48 = **288** | **18** |
| After | 2 × 8 = **16** | **0** |

**Wall clock for one refresh**, measured with `/usr/bin/time` against the real
helper and the real sudoers rule:

| | Time |
|---|---|
| Before (`sudo` × 3, sequentially) | **4.89 s** |
| After, fast tick | **78 ms** |

The 4.89 s is why the old UI felt sluggish on a cold cache: three privileged
round trips, one after another, each spawning a process tree, and the `dns
status` call alone runs 21 `dig` queries. The new fast tick finishes in 78 ms
and the 25-second privileged read happens off the main thread while the card is
already on screen.

## 5. What a future maintainer must not break

1. **One sudoers path.** `HelperClient.run` is the only place `sudo` is called,
   and it always passes the same absolute helper path. `HelperClientTests`
   asserts every call shares that prefix. Adding a privileged read means adding
   an argument to the existing grant, never a new binary or a wrapper script.

2. **`buildLocal` must never gain a privileged call.** The test
   `testLocalReportSpawnsNothingPrivileged` fails the build if it does. This is
   the single property the whole change exists for.

3. **`.unknown` is app-only.** `Health.Code.unknown` must never appear in JSON
   written by `menfez-route`. `Report.health` is non-optional, so an older app
   decoding an unrecognised code fails on the entire payload — not just that
   field. `testHelperReportNeverEmitsUnknownHealth` pins this.

4. **`TunnelFacts` is the whole privileged surface.** If a new field needs root,
   it goes there and the measurement table above gets a new row. Do not add a
   second narrow command; the point of one type is that the list can be read.

5. **The endpoint pin ordering is untouched.** Nothing in this change modifies
   `up`, `down`, `changeMode`, `switchTo`, `reconcile`, `persistAfterRollback`
   or the route primitives. The read path calls them not at all.

6. **Do not put `report --fast` back on the timer.** It is kept for the
   old-helper fallback and for `status`; it is not a refresh mechanism.

7. **`nil` means not measured.** Every optional field in `Report` is optional so
   a failed probe can render as a dash. A default of `0`, `""` or `false` in
   this path is a fabricated measurement and `Probes.swift`'s one rule forbids
   it.

## 6. Known limits

* `wg show interfaces` succeeding with empty output means "no tunnel"; failing
  means "we could not look". These are distinguished everywhere the report is
  built, but a caller that uses the older `RouteManager.interfaces()` (which
  collapses both to `[]`) still cannot tell them apart. That is deliberate for
  mutations, where an empty list must abort either way; read code should use
  `interfaceList()`.
* The DNS sheet still runs ~21 `dig` queries. That is now paid on open instead
  of on every tick, which is the right trade, but it is not cheap and has not
  been optimised.
* `Shell.run` builds a fresh `DispatchQueue` per call and does not prove its
  reader finished on the timeout path (finding M6 in `FIX-STATUS.md`). Unchanged
  here: it is a `Shell` refactor and would touch every caller.
* The `facts` subcommand has not been exercised through sudo on this machine,
  because the installed helper predates it and reinstalling to test was out of
  scope. Its code path is covered by unit tests through the injected launcher,
  and by `report --fast` sharing every function it calls. The first run after
  install is the live test.
