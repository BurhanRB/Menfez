# The DPI engine

How the free tier opens Discord without a VPN, what it costs, and what it does
not know.

Source: `Menfez/Sources/MenfezCore/dpi/`.
Measured basis: probe scripts run against a blocking network during development
(not included in this repository).

---

## 1. What the engine is

A local HTTP `CONNECT` proxy. It listens on `127.0.0.1`, reusing the port it last bound (UserDefaults `dpi.lastPort`) and falling back to an ephemeral one when that port is taken,
accepts one tunnel per client connection, and rewrites exactly one thing on the
way through: the header of the first TLS record.

```
Discord ──CONNECT──▶ 127.0.0.1:<port> ──TCP──▶ Discord edge
                          │
                          └─ first TLS record re-cut into two
```

No root, no utun, no `pf`, no route change, no system proxy. Nothing outside the
process that was pointed at the proxy is affected: if the engine dies, only that
app loses its connection.

### Why a proxy and not the utun design

`DESIGN.md` describes a utun + pf NAT + raw-socket engine that needs an
administrator password, a launch daemon and a network extension. The measured
result makes all of that unnecessary: the block can be defeated by changing a
5-byte header in a byte stream that a userspace process already owns. Shipping
the privileged design to do the same job would ask the user for more trust and
give them a harder-to-recover failure mode.

The trade-off is stated plainly rather than hidden: a proxy only covers
applications that use it. That is why Discord has to be launched by this app
(§6), and it is why the utun design is still the right shape for a future tier
that wants to cover every app.

---

## 2. The split, and why it is a length rule

### What is sent

A TLS ClientHello normally travels as **one** TLS record:

```
┌─────────┬─────────┬──────────────────────────────────┐
│ 0x16    │ 0x0301  │ length L                          │  ← 5-byte record header
├─────────┴─────────┴──────────────────────────────────┤
│ handshake bytes: random, session id, ciphers, … SNI …│  ← L bytes of payload
└──────────────────────────────────────────────────────┘
```

The engine re-cuts the payload into two records:

```
┌────────┬────────┬──────────┬────────┬──────────────────┐
│ 0x16   │ 0x0301 │   40     │ 0x16   │ 0x0301 │ L - 40  │
│ header │        │ payload  │ header │        │ payload │
└────────┴────────┴──────────┴────────┴────────┴─────────┘
```

The payload bytes are **identical and in the same order**. Only two 5-byte
headers differ from what the client wrote. A server reassembles the handshake
message from the two records exactly as if it had arrived in one, because that
is what TLS records are for. The DPI, which only ever inspects a record it can
parse, never sees a complete hostname.

### Why the property is length, not SNI placement

A probe script separated the two candidate explanations by sending:

| First record | SNI inside it? | Result |
|---|---|---|
| 40 bytes | **no** | pass |
| 40 bytes | **yes, fully** | pass |
| 160 bytes | no | reset |
| 160 bytes | yes | reset |

If the rule were "hide the hostname", case B — 40 bytes, hostname fully present
— would have reset. It passed. If the rule were "keep the hostname out", case C
— 160 bytes, no hostname — would have passed. It reset. **Only the length of the
first record predicts the outcome.**

That is why the implementation contains no ClientHello parser. There is no SNI
search, no extension walk, no handshake-length validation. The whole decision
is: read 5 bytes of header, compare the declared payload length against a
constant.

### The one knob

```swift
public static let firstRecordPayloadLimit = 40
```

The measured boundary was exact on one network: **40 payload bytes passed, 41
reset**, reproducibly, with the control being reset in the same run. It is a
constant and not a computed value because there is nothing to compute from — no
input tells the proxy what this network's DPI does.

`min(40, len)` is applied rather than a bare 40, so a ClientHello whose payload
is already 30 bytes is left alone instead of producing an empty second record.

### What the engine deliberately does not do

- **No TCP segmentation tricks.** The measured result explicitly says the DPI
  reassembles TCP, and the two records travel in one segment anyway.
- **No decoy or forged packets.** Those need root, and the length rule makes
  them unnecessary: the DPI's problem is that it does not parse short first
  records at all, not that it mis-attributes flows.
- **No parsing past the record header.** A malformed ClientHello is forwarded
  untouched. Parsing further would create a class of inputs that can confuse a
  process sitting in front of every connection the app makes.

---

## 3. Limits, and why each number is that number

| Limit | Value | Why |
|---|---|---|
| Bind address | `127.0.0.1` | The single thing preventing an open relay. The CONNECT path has no authentication (the spike's proxy had none either), so binding the wildcard address would let any machine on the same network tunnel through this Mac's address. Asserted by `testListenerBindsLoopbackOnly`. |
| Port | last bound port, else ephemeral (`0`) | A running Discord was launched with the old `--proxy-server` port, so a restart must keep it. If the port is taken the engine binds an ephemeral one and reports `portChanged`, and the UI asks the user to relaunch Discord. |
| Concurrent connections | **128** | One Discord client holds under ~20 TCP flows (gateway, CDN, media, a handful of API calls). 128 is several instances' worth of headroom while keeping the worst-case buffer footprint near 5 MiB. It is also below the point where one serial callback queue bottlenecks this traffic shape, and below the kernel's listen backlog, so an overflow is refused **here** with a readable 503 rather than becoming a silent SYN drop. |
| CONNECT head | **8 KiB** | The large-header limit production HTTP servers use (nginx's `large_client_header_buffers` default). A larger head would be refused by the origin anyway, so buffering one only helps whoever sent it. Enforced *while reading*, so a 10 MB header line costs 8 KiB, not 10 MB. |
| Bytes per read | 16 KiB | A TLS record carries at most 16 KiB of payload plus a 5-byte header and a 16-byte AEAD tag, so a whole record usually arrives in one read and the split costs no extra round trip. |
| Buffering per direction | one 16 KiB chunk | The next read is issued only after the previous send completes. That hands flow control back to TCP instead of growing a queue, so memory does not scale with transfer size or connection lifetime. |
| Splitter state | 45 bytes | The decision window is the record header plus the limit. Asserted by `testSplitterBufferNeverExceedsDecisionWindow`. |
| Connect timeout | 10 s | A DNS lookup plus a TCP handshake to a Cloudflare edge takes well under a second; 10 s survives a slow tether and is short enough that a dead origin does not hold a slot. Same value the spike used. |
| Header timeout | 10 s | The client sends the head before any server response. Anything slower is not a client about to use the tunnel. This is the only thing bounding a connection that opens and sends nothing. |
| Idle timeout | 120 s | Discord's gateway heartbeats roughly every 41 s. A 60 s timeout would sit 19 s from killing a healthy idle websocket, and a backgrounded Electron app slips past that. 120 s tolerates two missed heartbeats while making it impossible for a hung connection to hold a slot forever. |

Peak memory for a served connection: 8 KiB of head (once, before the tunnel
exists) plus 2 × 16 KiB in flight. For the whole engine at the cap, ~5 MiB.
None of it grows with how long a connection lives or how much it carries.

### Refusals

| Status | Cause |
|---|---|
| `503` | concurrency cap reached (counted separately as `overCapacity`) |
| `431` | CONNECT head over 8 KiB |
| `405` | method is not `CONNECT`, with `Allow: CONNECT` |
| `400` | malformed request line, bad target, missing or out-of-range port |
| `403` | target is not port 443, or is a loopback/private/link-local literal or `localhost`/`*.local` |
| `408` | no CONNECT head within the header timeout |
| `502` | upstream dial failed |
| `504` | upstream dial exceeded the connect timeout |

A `CONNECT` to a target without a port is refused rather than defaulted to 443:
guessing a port the client did not name is how a proxy surprises its user.
Methods other than `CONNECT` are refused rather than rewritten, because serving
plain `GET http://…` means rewriting request targets and stripping hop-by-hop
headers — a different feature with a larger surface, and Electron sends only
CONNECT for the https/wss traffic Discord uses.

---

## 4. Honest status

`DPIStatus` reports only what the engine observed:

```swift
public struct DPIStatus {
    public var running: Bool      // a listener exists
    public var port: Int?         // the port it owns
    public var connections: Int   // served right now
    public var reframed: Int      // connections where a split happened
    public var passthrough: Int   // connections with no TLS record
}
```

Plus `rejected`, `overCapacity`, `uptimeS`, `splitAt` and `lastError`.

**`reframed > 0` proves the proxy did its job. It does not prove the network
needed it.** The spike's own caveat is the reason this distinction is treated as
a first-class design concern: the block lifted partway through the session and
every counter would have looked identical. So the counters are never presented
as health, and the mode badge goes green only for "the listener is up", never
for "it is working".

Two details that follow from taking that seriously:

- **Split and passthrough are counted when the first record is classified**, not
  when the connection closes. A Discord tunnel can live for hours, and a counter
  that only moves at close would read "0 split" during exactly the case it
  exists to report.
- **The probe is the only thing that may say "working"**, and only for the
  moment it ran.

### The probe

`DPIProbe.run` makes **two** requests to `discord.com`, sequentially: one
direct, one through the proxy. The verdict is a four-way comparison:

| direct | proxied | verdict | shown as |
|---|---|---|---|
| ✗ | ✓ | `working` | "the split is helping" |
| ✓ | ✓ | `notNeeded` | "this network is not blocking, so the split is not needed" |
| ✗ | ✗ | `notHelping` | "the split is not helping on this network" |
| ✓ | ✗ | `proxyBroken` | "the proxy is at fault, not the network" |

Design points that are easy to get wrong:

- **A real TLS request, not a TCP connect.** The DPI keys on the ClientHello, so
  a probe that only proved the TCP handshake works would pass straight through
  the block and report "not needed" on a fully blocked network.
- **Judged on curl's exit status, not the HTTP code.** A captive portal
  answering `200` with a login page would otherwise count as "the network is
  fine".
- **`--noproxy ""` on the direct attempt.** Otherwise a user's `NO_PROXY` could
  make the "direct" attempt go through the proxy too, comparing the proxy with
  itself and always reporting `notNeeded`.
- **`exit: -1` means no attempt was made.** It maps to `proxyOff`, not to
  `proxyBroken`: "no measurement" and "a measurement that failed" must not look
  the same.
- **Never on a timer.** Two real HTTPS requests per run. A background probe would
  spend the user's bandwidth on a schedule and would turn "no samples" into
  "seems fine" in the UI. It runs only when the user clicks.

### What the probe still cannot say

One request over a CONNECT tunnel is not Discord. A pass proves the proxy path
reaches `discord.com:443`; it does not prove the gateway websocket will connect,
nor that QUIC is not in use. The sentences stop at that boundary on purpose.

---

## 5. Start and stop, and the two modes

- The proxy starts when the user selects **DPI** mode — or presses the primary
  **Enable Discord** button, which starts it and launches Discord in one step.
- It runs **inside the app process**. No helper, no sudo, no launch daemon. This
  is the default experience and the reason a downloaded .app is useful with zero
  configuration.
- Quitting the app calls `shutdown()`, which cancels the listener and every
  tunnel: a Discord launched with `--proxy-server` must not be left pointing at
  a dead port. The WireGuard tunnel is deliberately *not* torn down on quit —
  it is machine state with its own revert timer, not app state.
- A second start is **refused** with the port already in use, not ignored and not
  given a second port. One hidden port would mean a "start" that reports success
  while listening somewhere the UI is not showing.

### The rule: one at a time, and teardown before start

DPI mode and the WireGuard tunnel never run at once, and `ModeCoordinator`
enforces that as a state machine over three states: `direct`, `dpi`, `tunnel`.

Every transition has two ordered phases:

1. **Teardown** of whatever is not the target.
2. **Start** of the target.

A failure in either phase leaves at most one thing running, and a start failure
leaves nothing — `direct`. That is the property the tests assert after every
step, because a half-up pair is the failure nobody can debug: with `all` routes
the proxy's own upstream dial would enter the tunnel and every CONNECT would be
encrypted twice; with `discord` routes the proxy would exit through the tunnel
for Discord and directly for everything else, so the counters and the probe
would describe two different networks.

This replaced an earlier design that *refused* to switch while the tunnel was up
and left the teardown to the user. Refusal looked cautious but produced two
worse states: a user who clicked "DPI" and saw a message instead of a proxy, and
— once the mode chip and the refusal shared a chip — a "Tunnel" chip highlighted
while every command behind it failed, because `wg show interfaces` lists a utun
whether or not the helper has a sudo grant. Teardown-first is recoverable in one
click in both directions, which the refusal never was.

A failed start is **amber, not red**, in the UI: nothing is intercepting, the
traffic is fine, and one click fixes it.

### The tunnel is optional, and the app says so

`Capabilities` separates the two halves honestly:

| Field | Meaning | Probe |
|---|---|---|
| `dpiAvailable` | the proxy can run | always true: the engine is in-process |
| `tunnelAvailable` | the helper can be driven | one `sudo -n <helper> status` |
| `reason` | why the tunnel is unavailable, in a sentence | derived from sudo's answer |

The probe runs **once at launch, off the main thread**, and is cached. Its
default value before the answer arrives is `dpiOnly`, so the first frame is
never blocked by a `sudo` that might hang, and a machine with no helper never
sees an error — only a quiet row explaining the one-time setup, plus a Help
sheet with the single copyable command. A missing optional extra is not a
failure, and the UI must not render it as one.

`adoptExistingState(canManageTunnel:)` is the other half of the honesty rule: a
tunnel that is up but cannot be managed is *reported* (the status line names the
interface) but not *claimed* as this app's mode, because a "Direct" button that
cannot honour its own click is worse than no attribution.

### "Up" is not "carrying"

Three different things produce a WireGuard interface on a real Mac:

1. this app, with routes installed — interception;
2. another WireGuard client the user runs for something else — not ours;
3. the husk `wg-quick` leaves behind after `down` — not interception.

`wg show interfaces` cannot tell them apart, and an app that treats presence as
interception breaks in the worst direction: on a machine with a stray utun it
tried to stop a tunnel it had no sudo grant for, the stop failed, and **DPI mode
— the one mode that needs no root — could not be turned on at all**.

So the mode logic asks `TunnelControl.isCarryingTraffic()`, which reads the
route state (`/var/run/menfez/route-state.json`, world-readable, no root) and
requires both a non-`off` mode and at least one route or host entry:

| Interface | Routes | Mode | Carrying | DPI may start beside it |
|---|---|---|---|---|
| yes | yes | `discord` | yes | no — the tunnel must be stopped first |
| yes | none | `off` | **no** | **yes, with no root at all** |
| no | any | any | no | yes |

The same rule governs the `invariantHolds` assertion, the mode bar, the status
line and which detail rows are drawn. Interface presence is used for exactly one
thing: `switchTo(.tunnel)` treats an existing interface as "already up" and does
not start a second one.

---

## 6. Launching Discord

```
open -a Discord --args --proxy-server=http://127.0.0.1:<port>
```

Available from the window's DPI panel and from the **DPI** menu.

- Electron reads `--proxy-server` **at process start**. An already-running
  Discord ignores the new arguments entirely, so the launch is refused with
  "quit Discord first" before the click can do nothing visible. That refusal is
  the most important part of this feature: the failure it prevents is a user
  believing the app is covered when it is not.
- `open` is given an **argument list**, never a shell string, and the port is
  validated to 1–65535 first, so nothing can be injected.
- Discord's own files, `Preferences`, `Local State` and any system-wide proxy
  setting are **not touched**. `--proxy-server` is a per-process argument, so
  quitting Discord removes the proxy from the picture completely.

Known limitation to state: Discord's client may use QUIC for some traffic, and
QUIC would not go through an HTTP CONNECT proxy. The spike verified the TCP
gateway (`HTTP 101 Switching Protocols` on `gateway.discord.gg`), which is what
Discord's realtime connection uses, but a live logged-in client test is still
required before claiming the whole app is covered.

---

## 7. What must be re-measured when the ISP block returns

The 40-byte boundary was measured during a window in which the control was being
reset in the same run, so the split-versus-unsplit comparison is sound. The
block then lifted and was still off at the end of the session. The following are
therefore **not** independently re-verified:

1. **Whether the threshold is still 40** on another day, another ISP box, or
   after a DPI firmware change. This is the single thing most likely to be wrong
   on a different network, and it is the reason the value is one constant.
2. **Whether the DPI ever inspects the second record.** Everything here assumes
   it does not. If a future block reassembles records the way it already
   reassembles TCP, the split stops working and *no* constant fixes it.
3. **That the short first record is not itself a signature.** A DPI that learns
   "first record ≤ 40 bytes on a ClientHello" as a block rule would make this
   engine fail closed — the split would *cause* the block. Nothing in the design
   can detect that; only re-measurement can.
4. **The threshold for each host Discord actually uses** (`gateway.discord.gg`,
   `cdn.discordapp.com`), not just `discord.com`.

To re-measure, with the block active, send ClientHellos whose first TLS record
carries increasing payload lengths and note where the resets start. If the
boundary moves, change `firstRecordPayloadLimit` in
`TLSRecordReframer.swift`. Nothing else needs to change: the rule is a length,
and the constant is the only place the length appears.

Then use **Check now** in the DPI panel. The honest answers it can give:

| Result | Meaning |
|---|---|
| Direct fails, proxy works | the split is doing its job — this is the shipping case |
| Both work | the block is not active; nothing here is being tested |
| Both fail | the split is not helping: either the rule changed (see 1–4) or the block is not SNI-on-TCP at all any more |
| Direct works, proxy fails | the engine has a bug, not the network |

---

## 8. Tests

`Tests/MenfezCoreTests/DPIProxyTests.swift` and `DPIModeTests.swift`. **No test
requires the internet.** CONNECT tests run against an in-process `NWListener`;
reframing tests are pure array arithmetic.

The claims that are asserted rather than described:

- Output is exactly `5 + N + 5 + (len − N)` bytes; both record headers carry the
  right content type, version and length; payload concatenation equals the input
  **byte for byte** (a repeating pattern, so a shifted payload is visible).
- A payload at or below the limit is not split — including 0, 1 and exactly 40 —
  because an empty second record is a change that buys nothing.
- A record header claiming more bytes than are present is refused, not
  force-sliced.
- Non-TLS first bytes are forwarded unchanged, and decided on the **first** byte,
  so a plain tunnel never waits for 45 bytes.
- The splitter's buffer never exceeds the decision window.
- The streaming splitter produces exactly what the one-shot reframer produces.
- An oversized CONNECT head is refused **and the buffer never grew past the
  limit**.
- A CONNECT through the proxy returns `200`, a synthetic ClientHello reaches the
  fake origin as two records, and a plaintext tunnel arrives byte-identical.
- Eight arbitrary malformed byte sequences each get a 4xx and leave the engine
  serving: a malformed client byte must never crash the app.
- Idle timeout and header timeout both close a silent connection.
- A second start is refused with the port already in use; after stop the port
  no longer accepts.
- The listener's required local endpoint is `127.0.0.1:0`.
- The probe never reports `working` when the direct request succeeded.
- Launching Discord while it is running is refused and **no process is spawned**.

The two-mode design and the rootless promise have their own suites:

- `CapabilityTests` — helper missing → unavailable with a reason and **no sudo
  process spawned**; helper present and sudo granted → available; helper present
  but sudo refused → unavailable with a *different* reason; a hung helper →
  reported as a timeout, not as a refusal; the generated setup command is
  executed and its rule passes a real `visudo -c`.
- `ModeCoordinatorTests` — `direct → dpi → tunnel → dpi` leaves exactly one
  thing running after every step, in every direction; teardown is asserted to
  *precede* start on the recorded call order; a failed tunnel start ends in
  `direct`; a proxy that refuses to bind ends in `direct` after the tunnel was
  already stopped; a tunnel that will not stop blocks the proxy from starting;
  `direct` stops both; quit closes the listener and the port really refuses
  connections; quit leaves a WireGuard tunnel alone.
- `RootlessTests` — the suite runs as an unprivileged user and asserts it; the
  proxy binds, accepts a CONNECT and re-frames a ClientHello on the wire with no
  helper and no sudo; enabling DPI mode spawns **no process at all**; the DPI
  path never touches the helper client.

These verify the mechanism. They do not verify the bypass against a real block —
that requires the network and is §7's job.

### One end-to-end check that is stronger than a unit test

Beyond the suite, the engine was driven over loopback with a hand-built
ClientHello whose SNI sits at payload offset 65 — well past the 40-byte cut —
and delivered in two writes that straddle the 45-byte decision window, so the
streaming path was exercised rather than a single-shot reframe:

```
synthetic ClientHello: 96 bytes, record payload 91 B
SNI starts at payload offset 65
origin received: 101 bytes (sent 96)
  record 0: type 0x16 version 0x0301 payload 40 B
  record 1: type 0x16 version 0x0301 payload 51 B
payload concatenation identical to input: true
checks: two records=true, first payload 40=true, payload identical=true, length +5=true, version 0x0301=true
```

This proves the proxy does what it claims on the wire, including that the SNI is
split across a record boundary. It is still **loopback**: it proves the engine,
not that the split defeats this ISP's DPI. That distinction is the whole point of
§7.
