// RouteManager.swift — the split tunnel's route table, and the rules that keep
// a mistake from taking the machine offline.
//
// WHY THIS IS NOT A ONE-LINER
// ---------------------------
// The tunnel is loaded with `Table = off`, so wg-quick creates the interface
// but deliberately adds no routes; `add_route()` in wg-quick returns immediately
// when TABLE=off. That also disables wg-quick's own endpoint exemption.
//
// Consequence: the moment a route covers the WireGuard endpoint's own address,
// the encrypted UDP packets that carry the tunnel are themselves routed *into*
// the tunnel. The transport loops, the handshake stops, and the interface dies
// — while the routes stay in the table. Every destination still matching those
// routes is then black-holed. That is not a theoretical failure; it happened on
// this machine with 0.0.0.0/1 + 128.0.0.0/1.
//
// Therefore every entry point below, in this order:
//   1. refuses to run unless the tunnel is actually up,
//   2. pins the endpoint to the physical gateway with a /32 (or /128) host
//      route,
//   3. adds the requested routes,
//   4. re-checks that the interface still exists and the handshake is fresh,
//   5. rolls every change back automatically if step 4 fails,
//   6. records exactly what it added so `down` removes only that.
//
// A failure that leaves a route behind is worse than a failure that does
// nothing, which is why the rollback runs in reverse order and why the state
// file is rewritten to "off" on every failed attempt: a stale state file would
// make the next `down` act on routes that are no longer ours.
//
// NOTHING HERE PRINTS
// The helper in Sources/menfez-route emits a single JSON object on stdout, so a
// library that printed would corrupt it. Human-readable progress goes into
// `log` instead, and the CLI decides whether to show it.

import Foundation

// MARK: - Mode

/// Which destinations the tunnel carries.
public enum Mode: String, Codable, Sendable, CaseIterable {
    /// Only the Discord/Cloudflare ranges.
    case discord
    /// Every destination (browser geo-mode).
    case all
    /// No routes; the tunnel may stay up but carries nothing.
    case off
    /// Only the /32s passed with `--host-routes` (Discord's updater) plus the
    /// resolver /32s. Runs beside DPI mode; everything else stays on the proxy.
    case updates

    /// Parse a `--mode` argument, refusing an explicit unknown value.
    ///
    /// `Mode(rawValue: value ?? "discord") ?? .discord` meant an explicit
    /// `--mode everything` silently became discord, and the result then reported
    /// `mode=discord` as if the user had asked for it. A usage error is the
    /// honest answer: the command did not run, so exit 2 rather than a runtime
    /// failure with a plausible-looking result.
    ///
    /// `allowingOff` is false for `mode <x>`, where "off" is the teardown and
    /// has its own command; true for `up --mode`, where off is accepted and
    /// routed to `down`.
    public static func argument(_ raw: String?,
                                allowingOff: Bool = true) -> Result<Mode, ModeProblem> {
        guard let raw else { return .success(.discord) }
        guard let mode = Mode(rawValue: raw) else {
            let allowed = allowingOff ? "'discord', 'all' or 'off'" : "'discord' or 'all'"
            return .failure(ModeProblem("--mode must be \(allowed) (got '\(raw)')"))
        }
        guard allowingOff || mode != .off else {
            return .failure(ModeProblem("--mode must be 'discord' or 'all' (got '\(raw)')"))
        }
        return .success(mode)
    }
}

/// A rejected `--mode` value, carrying the sentence to print.
///
/// A dedicated type rather than a bare String so `Result` can carry the message
/// without a String-Error shim, and so the CLI cannot print a problem as if it
/// were a success payload.
public struct ModeProblem: Error, Equatable, CustomStringConvertible {
    public let message: String
    public var description: String { message }
    public init(_ message: String) { self.message = message }
}

// MARK: - RouteManager

public struct RouteManager {

    // MARK: Constants

    /// Discord is served out of Cloudflare, and 162.159.128.0/18 is Cloudflare's
    /// own allocation, not a Discord-owned range. Discord is a tenant inside it,
    /// so the range does not move when Discord rotates servers; no scheduled
    /// re-resolve.
    public static let discordRanges: [String] = [
        "162.159.128.0/18",
        "162.159.192.0/24",
    ]

    /// Most resolver /32s one `--dns-routes` may add; a Mac has two or three.
    public static let maxDNSRoutes = 8

    /// Most host /32s one `--host-routes` may add: three updater names behind
    /// Cloudflare answer with about five addresses each.
    public static let maxHostRoutes = 16

    /// The `--dns-routes` value as /32 prefixes, or nil when any entry is not
    /// a public IPv4 address. The helper's input is a trust boundary, so one
    /// bad entry refuses the whole list rather than being dropped quietly.
    public static func dnsRoutes(argument raw: String) -> [String]? {
        publicHostRoutes(argument: raw, max: maxDNSRoutes)
    }

    /// The `--host-routes` value as /32 prefixes; same rules, larger cap.
    public static func hostRoutes(argument raw: String) -> [String]? {
        publicHostRoutes(argument: raw, max: maxHostRoutes)
    }

    static func publicHostRoutes(argument raw: String, max: Int) -> [String]? {
        let items = raw.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard !items.isEmpty, items.count <= max else { return nil }
        var out: [String] = []
        for item in items {
            guard let quad = ConnectRequest.dottedQuad(item),
                  !ConnectRequest.isPrivate(v4: quad) else { return nil }
            if !out.contains(item + "/32") { out.append(item + "/32") }
        }
        return out
    }

    /// The resolvers worth routing into the tunnel: public IPv4 only. A LAN
    /// router (192.168.1.1), loopback or link-local resolver must stay on the
    /// physical path, or the Mac loses DNS altogether.
    public static func publicResolvers(_ servers: [String]) -> [String] {
        var out: [String] = []
        for server in servers where !out.contains(server) {
            if let quad = ConnectRequest.dottedQuad(server), !ConnectRequest.isPrivate(v4: quad) {
                out.append(server)
            }
        }
        return Array(out.prefix(maxDNSRoutes))
    }

    /// The helper arguments for the current setting and resolvers: empty when
    /// the toggle is off or no resolver is public.
    public static func dnsRouteArgs(enabled: Bool, resolvers: [String]) -> [String] {
        let servers = enabled ? publicResolvers(resolvers) : []
        return servers.isEmpty ? [] : ["--dns-routes", servers.joined(separator: ",")]
    }

    /// A handshake older than this means the transport is not working.
    public static let handshakeMaxAge = 180

    /// Generation counter floor. Bumped on every successful apply; an armed
    /// `--revert-after` timer carries the value it saw so a stale timer is a
    /// no-op rather than a teardown of a tunnel a later run installed.
    public static var currentGeneration: Int {
        RouteStateStore.load().generation
    }

    /// Keepalive is every 25 s in typical configs, so 5 s is enough to
    /// observe the interface state without waiting for a full handshake cycle.
    public static let settleSeconds: TimeInterval = 5

    /// A mode swap touches two route sets; the Python allowed 2 s there, which
    /// is enough for the interface to survive losing and regaining a prefix.
    public static let swapSettleSeconds: TimeInterval = 2

    public static let wireGuardTimeout: TimeInterval = 90

    /// How long `up`/`switchTo` wait for the transport to move after routing.
    public static let transportProbeBudget: TimeInterval = 40

    // MARK: Result of one route command

    /// Outcome of a mutating route call, with the reason a user can read.
    public struct Mutation: Sendable {
        public let ok: Bool
        public let detail: String

        public init(ok: Bool, detail: String) {
            self.ok = ok
            self.detail = detail
        }
    }

    // MARK: Progress

    /// Lines a human would have seen from the Python version. A reference type
    /// so the public methods can stay non-mutating; one instance per command.
    private final class Journal {
        var lines: [String] = []
    }

    private let journal = Journal()

    /// Everything the last call did, in order, for the CLI to print.
    public var log: [String] { journal.lines }

    /// How long to wait before the post-change health check. Injectable so a
    /// test can prove the rollback path without waiting five seconds.
    public let settle: TimeInterval

    /// Where this instance reads and writes its state.
    ///
    /// Injectable so the crash-recovery tests can drive a pending file without
    /// writing to root-owned /var/run/menfez. Production always uses the
    /// default; nothing else in the app passes a value.
    public let statePath: String

    /// The config wg-quick is pointed at.
    ///
    /// Injectable for the same reason as `statePath`: a test that proves a
    /// failed tunnel start cannot echo the private key needs a config whose key
    /// it planted. Production always uses the default.
    public let managedConfigPath: String

    /// Resolver /32s that join the Discord ranges (`--dns-routes`), so other
    /// apps can resolve Discord's names when the ISP blocks plain DNS. Already
    /// validated by `dnsRoutes(argument:)`. Recorded in `routes` like every
    /// other prefix, so `down` and a mode change remove them the same way.
    public var dnsRoutes: [String] = []

    /// The /32s `updates` mode carries (`--host-routes`), already validated by
    /// `hostRoutes(argument:)`. Ignored in every other mode.
    public var hostRoutes: [String] = []

    /// Runner for the one command `up` starts directly.
    ///
    /// Defaults to the real `Shell.run`, so production behaviour is unchanged.
    /// A test injects a failing runner to reach the redacted-failure path
    /// without asking wg-quick to bring an interface up as an unprivileged
    /// user.
    var run: (String, [String], TimeInterval) -> CommandResult = {
        Shell.run($0, $1, timeout: $2)
    }

    public init(settle: TimeInterval = RouteManager.settleSeconds,
                statePath: String = Path.routeState,
                managedConfigPath: String = Path.managedConfig) {
        self.settle = settle
        self.statePath = statePath
        self.managedConfigPath = managedConfigPath
    }

    private func note(_ line: String) {
        journal.lines.append(line)
    }

    /// State file operations bound to this instance's path.
    func loadState() -> RouteState {
        RouteStateStore.load(path: statePath)
    }

    @discardableResult
    func saveState(_ state: RouteState) -> Bool {
        RouteStateStore.save(state, path: statePath)
    }

    /// Delete hooks, so the crash-recovery tests can observe which prefixes a
    /// reconcile would remove without deleting a route on the test machine.
    ///
    /// They default to the real static calls; production never replaces them.
    /// A test-only seam is preferable to a test that runs `route delete` and
    /// hopes the prefix was not in use.
    var deleteNet: (String) -> Bool = { RouteManager.deleteRoute($0) }
    var deleteHost: (String) -> Bool = { RouteManager.deleteHostRoute($0) }

    /// Add hooks, same reason as the delete hooks.
    var addNet: (String, String) -> Mutation = { RouteManager.addRoute($0, iface: $1) }
    var addHost: (String, String) -> Mutation = { RouteManager.addHostRoute($0, gateway: $1) }

    /// Stops the interface wg-quick started from the managed config. A hook so
    /// `teardown` can be tested without a tunnel.
    var stopTunnel: (String) -> Bool = { WireGuardProfiles.stopManagedTunnel(config: $0) }

    /// Tunnel-probe hooks.
    ///
    /// `up` cannot be exercised on a test machine because there is no tunnel to
    /// drive it, and H4 is about the ordering of a write relative to a mutation,
    /// not about the mutation itself. These defaults are the real probes; a test
    /// replaces them with values that reach the code under test.
    var probeInterfaces: () -> [String] = { RouteManager.interfaces() }
    var probeEndpoint: (String) -> String? = { RouteManager.endpoint(iface: $0) }
    var probeGateway: () -> String? = { RouteManager.physicalGateway() }
    var probeHostGateway: (String) -> String? = { RouteManager.hostRouteGateway($0) }
    var probeHealth: (String) -> (healthy: Bool, reason: String) = {
        RouteManager.diagnose(iface: $0)
    }
    var probeBaseline: (String) -> Baseline = { RouteManager.baseline(iface: $0) }
    var probeProgress: (String, Baseline, TimeInterval) -> (healthy: Bool, reason: String) = {
        RouteManager.awaitTransportProgress(iface: $0, since: $1, settle: $2)
    }

    // MARK: - Tunnel probes

    /// Every WireGuard interface that is up, in `wg show interfaces` order.
    ///
    /// `wg_iface()` in the Python took the first name only. Every caller here
    /// wants "the first one" too, but returning the list keeps the decision at
    /// the call site instead of hiding a second interface.
    public static func interfaces() -> [String] {
        interfaceList() ?? []
    }

    /// The same list, with "the tool could not answer" told apart from "there
    /// are none".
    ///
    /// This distinction is the whole reason the unprivileged report is honest.
    /// `wg show interfaces` needs no root on this platform (it enumerates
    /// /var/run/wireguard), so an empty *successful* answer really does mean no
    /// tunnel; a *failed* invocation means we learned nothing, and the caller
    /// must not render that as "tunnel down". Mutations keep using
    /// `interfaces()`, where an empty list is the safe reading either way.
    public static func interfaceList(using runner: CommandRunner = SystemRunner())
        -> [String]? {
        let result = runner.run("wg", ["show", "interfaces"], timeout: 10)
        guard result.ok else { return nil }
        return result.output
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }

    /// True when the kernel still knows the interface.
    ///
    /// `ifconfig <name>` is readable without root (verified: rc=0 as uid 501),
    /// which is why "the utun disappeared" can be detected on the fast path.
    public static func interfaceExists(_ name: String,
                                      using runner: CommandRunner = SystemRunner()) -> Bool {
        guard !name.isEmpty else { return false }
        return runner.run("ifconfig", [name], timeout: 10).ok
    }

    /// Seconds since the newest handshake, or nil when there is no peer.
    public static func handshakeAge(iface: String,
                                    using runner: CommandRunner = SystemRunner()) -> Int? {
        guard let newest = handshakeEpochs(iface: iface, using: runner).max() else {
            return nil
        }
        return max(0, Int(Date().timeIntervalSince1970) - newest)
    }

    /// Unix time of the newest handshake, for the UI's "last seen" row.
    public static func handshakeEpoch(iface: String,
                                      using runner: CommandRunner = SystemRunner()) -> Int? {
        handshakeEpochs(iface: iface, using: runner).max()
    }

    /// `wg show <iface> latest-handshakes` prints "<key> <epoch>" per peer, and
    /// 0 when a peer never completed one. Zeroes are dropped here because they
    /// would otherwise win the `max` calculation of nothing.
    private static func handshakeEpochs(iface: String,
                                        using runner: CommandRunner = SystemRunner()) -> [Int] {
        let result = runner.run("wg", ["show", iface, "latest-handshakes"], timeout: 10)
        guard result.ok else { return [] }
        return result.output.split(separator: "\n").compactMap { line in
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            guard parts.count >= 2, let epoch = Int(parts[1]), epoch > 0 else {
                return nil
            }
            return epoch
        }
    }

    /// The peer's host, without the port.
    ///
    /// `wg show <iface> endpoints` prints "198.51.100.7:51820" or
    /// "[2001:db8::7]:51820". An IPv6 endpoint keeps its brackets stripped,
    /// because the value is handed straight to `route -host`.
    public static func endpoint(iface: String,
                                using runner: CommandRunner = SystemRunner()) -> String? {
        let result = runner.run("wg", ["show", iface, "endpoints"], timeout: 10)
        guard result.ok else { return nil }
        for line in result.output.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            guard parts.count >= 2, parts[1].contains(":") else { continue }
            let address = String(parts[1])
            guard let colon = address.lastIndex(of: ":") else { continue }
            let host = String(address[address.startIndex..<colon])
            return host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        }
        return nil
    }

    /// First peer's public key, for display only. Never a private key.
    public static func peerPubkey(iface: String,
                                  using runner: CommandRunner = SystemRunner()) -> String? {
        let result = runner.run("wg", ["show", iface, "peers"], timeout: 10)
        guard result.ok else { return nil }
        return result.output
            .split(whereSeparator: { $0.isWhitespace })
            .first
            .map(String.init)
    }

    /// Received/sent byte counters, or nil when the probe could not run.
    ///
    /// Returning `Transfer()` (0/0) on failure was a fabricated measurement: the
    /// UI rendered "↓ 0 B ↑ 0 B" for a tunnel it simply could not read, which is
    /// exactly what `Probes.swift`'s one rule forbids. A nil is drawn as a dash.
    public static func transfer(iface: String,
                                using runner: CommandRunner = SystemRunner()) -> Transfer? {
        let result = runner.run("wg", ["show", iface, "transfer"], timeout: 10)
        guard result.ok else { return nil }
        for line in result.output.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            guard parts.count >= 3,
                  let rx = Int(parts[1]), let tx = Int(parts[2]) else { continue }
            return Transfer(rx: rx, tx: tx)
        }
        return nil
    }

    // MARK: - The privileged half, in one round trip

    /// Everything `wg show` can tell us, read once.
    ///
    /// WHY THIS TYPE EXISTS
    /// These five fields are the only part of the report that genuinely needs
    /// root (`wg show <iface> ...` is "Permission denied" unprivileged, while
    /// `wg show interfaces` is not). Grouping them means the app needs one
    /// privileged round trip per refresh instead of a whole `report`, and it
    /// makes the boundary auditable: this is the complete list of privileged
    /// reads, and nothing else in the report is on it.
    ///
    /// Every field is optional. A peer with no handshake has no epoch; a tunnel
    /// with no peer has no transfer counters. `nil` means "not measured", never
    /// zero — the same rule `Probes.swift` states.
    public struct TunnelFacts: Codable, Equatable, Sendable {
        public var tunnel: String?
        public var endpoint: String?
        public var peerPubkey: String?
        public var handshakeEpoch: Int?
        public var transfer: Transfer?

        enum CodingKeys: String, CodingKey {
            case tunnel, endpoint, transfer
            case peerPubkey = "peer_pubkey"
            case handshakeEpoch = "handshake_epoch"
        }

        public init(tunnel: String? = nil, endpoint: String? = nil,
                    peerPubkey: String? = nil, handshakeEpoch: Int? = nil,
                    transfer: Transfer? = nil) {
            self.tunnel = tunnel
            self.endpoint = endpoint
            self.peerPubkey = peerPubkey
            self.handshakeEpoch = handshakeEpoch
            self.transfer = transfer
        }
    }

    /// Read the privileged half for one interface.
    ///
    /// Four `wg` invocations, one each. The old report path asked for
    /// latest-handshakes three times per refresh (`handshakeAge`,
    /// `handshakeEpoch`, and again inside `health`) and every one of them was a
    /// separate root child process; the epoch is read once here and both ages
    /// are derived from it at the call site.
    public static func facts(iface: String,
                             using runner: CommandRunner = SystemRunner()) -> TunnelFacts {
        TunnelFacts(tunnel: iface,
                    endpoint: endpoint(iface: iface, using: runner),
                    peerPubkey: peerPubkey(iface: iface, using: runner),
                    handshakeEpoch: handshakeEpoch(iface: iface, using: runner),
                    transfer: transfer(iface: iface, using: runner))
    }

    /// Health from a facts snapshot, without touching the interface.
    ///
    /// Split out from `health(iface:)` so the app can judge a tunnel from data
    /// it already has: the epoch is a stable fact, while the age derived from
    /// it must be recomputed on every redraw or the row freezes.
    public static func health(iface: String,
                              exists: Bool,
                              handshakeEpoch: Int?,
                              now: Date = Date()) -> Health {
        guard exists else { return Health(ok: false, code: .gone) }
        guard let epoch = handshakeEpoch else {
            return Health(ok: false, code: .noHandshake)
        }
        let age = max(0, Int(now.timeIntervalSince1970) - epoch)
        if age > handshakeMaxAge {
            return Health(ok: false, code: .stale, ageS: age)
        }
        return Health(ok: true, code: .ok, ageS: age)
    }

    /// The gateway of the physical default route, or nil when there is none.
    ///
    /// The old version fell back to the hardcoded 192.168.1.1. That value is a
    /// guess, and it was handed to `route add -host`: a wrong gateway creates a
    /// pin that black-holes the transport on any network that is not the
    /// developer's own. A caller with no gateway must say "unknown" and refuse
    /// to pin, not invent a router.
    public static func physicalGateway(using runner: CommandRunner = SystemRunner())
        -> String? {
        let values = routeGetValues(["default"], using: runner)
        // A default via a utun is the tunnel, never the router the endpoint
        // must be pinned to; pinning there would loop the transport (K5).
        guard let gateway = values["gateway"],
              !gateway.isEmpty,
              Validate.ipAddress(gateway) != nil,
              !(values["interface"] ?? "").hasPrefix("utun")
        else { return nil }
        return gateway
    }

    /// Interface that carries the default route, i.e. the physical one.
    public static func primaryInterface(using runner: CommandRunner = SystemRunner())
        -> String? {
        guard let name = routeGetValues(["default"], using: runner)["interface"],
              !name.isEmpty else {
            return nil
        }
        return name
    }

    /// Healthy means: the interface exists and the handshake is fresh.
    public static func health(iface: String,
                              using runner: CommandRunner = SystemRunner()) -> Health {
        health(iface: iface,
               exists: interfaceExists(iface, using: runner),
               handshakeEpoch: handshakeEpoch(iface: iface, using: runner))
    }

    /// Same probe as `health`, plus the sentence the Python printed.
    ///
    /// Internal rather than public: the wording is for the helper's messages,
    /// while the app reads the structured `Health` codes.
    static func diagnose(iface: String,
                         using runner: CommandRunner = SystemRunner())
        -> (healthy: Bool, reason: String) {
        guard interfaceExists(iface, using: runner) else {
            return (false, "interface \(iface) is gone")
        }
        guard let age = handshakeAge(iface: iface, using: runner) else {
            return (false, "no handshake recorded")
        }
        if age > handshakeMaxAge {
            return (false, "handshake is stale (\(age)s)")
        }
        return (true, "handshake \(age)s old")
    }

    /// A snapshot taken immediately before a route change, so the change can be
    /// judged by what happened to the transport rather than by an absolute age.
    ///
    /// Why this exists: the previous check compared the post-change handshake
    /// age against a 180 s ceiling. After a 5 s settle a handshake that had just
    /// succeeded is 5 s old, so a transport that died during the change still
    /// read as healthy for the next three minutes and the rollback could never
    /// fire for the failure it was written for.
    public struct Baseline {
        public var epoch: Int?
        public var rx: Int?
        public var tx: Int?
    }

    public static func baseline(iface: String,
                                using runner: CommandRunner = SystemRunner()) -> Baseline {
        let bytes = transfer(iface: iface, using: runner)
        return Baseline(epoch: handshakeEpoch(iface: iface, using: runner),
                        rx: bytes?.rx,
                        tx: bytes?.tx)
    }

    /// True when the transport demonstrably moved since `before`.
    ///
    /// A new handshake or any byte growth counts. Typical configs use a 25 s
    /// keepalive, so within the budget there is normally at least one of the
    /// two; when neither moves the caller declares failure rather than assuming
    /// the best. `requireReceive` drops the tx-only case: bytes sent prove
    /// nothing about the path back, so an early answer needs rx or a handshake.
    public static func transportProgressed(iface: String, since before: Baseline,
                                           requireReceive: Bool = false,
                                           using runner: CommandRunner = SystemRunner()) -> Bool {
        guard interfaceExists(iface, using: runner) else { return false }
        let nowEpoch = handshakeEpoch(iface: iface, using: runner)
        if let a = before.epoch, let b = nowEpoch, b > a { return true }
        if before.epoch == nil, nowEpoch != nil { return true }
        guard let now = transfer(iface: iface, using: runner) else { return false }
        // Both sides are optional because an unreadable counter is not zero
        // bytes: it is no measurement. An unknown baseline cannot prove
        // progress, so it does not count as a tick.
        if let beforeRx = before.rx, now.rx > beforeRx { return true }
        if requireReceive { return false }
        if let beforeTx = before.tx, now.tx > beforeTx { return true }
        return false
    }

    /// Inside both modes' routes (discord.com's own /18, and the 128/1 half),
    /// so a SYN to it crosses the tunnel and its SYN-ACK comes back as rx.
    static let kickTarget = "162.159.128.233"

    /// Poll step once the settle is over. The verdict is the same at any step;
    /// a 5 s step only rounded every switch up to the next multiple of 5.
    static let transportPollSeconds: TimeInterval = 1

    /// The timeline of `awaitTransportProgress`, without sockets or sleeps so a
    /// test can drive it.
    ///
    /// 1. Send one TCP SYN through the new routes (`kick`), so the transport
    ///    gets a reply now instead of at the next keepalive, up to 25 s away.
    /// 2. Before `settle`: succeed early only on rx or a new handshake — a
    ///    reply that came back through the tunnel, stronger than the old check.
    /// 3. From `settle` on: the old criterion (any movement), until `budget`.
    static func waitForProgress(settle: TimeInterval,
                                budget: TimeInterval,
                                poll: TimeInterval,
                                kick: () -> Void,
                                exists: () -> Bool,
                                progressed: (_ requireReceive: Bool) -> Bool,
                                elapsed: () -> TimeInterval,
                                sleep: (TimeInterval) -> Void) -> (healthy: Bool, reason: String) {
        kick()
        while true {
            let t = elapsed()
            if !exists() { return (false, "gone") }
            if progressed(t < settle) { return (true, "moved") }
            if t >= budget { return (false, "transport did not move within \(Int(budget))s") }
            sleep(t < settle ? min(poll / 2, settle - t) : poll)
        }
    }

    /// Wait for the transport to prove it survived, up to `budget` seconds.
    public static func awaitTransportProgress(iface: String,
                                              since before: Baseline,
                                              settle: TimeInterval,
                                              budget: TimeInterval = transportProbeBudget)
        -> (healthy: Bool, reason: String) {
        let start = Date()
        var socketFD: Int32 = -1
        defer { if socketFD >= 0 { close(socketFD) } }
        let result = waitForProgress(
            settle: settle, budget: budget, poll: transportPollSeconds,
            kick: { socketFD = sendSYN(to: kickTarget, port: 443) },
            exists: { interfaceExists(iface) },
            progressed: { transportProgressed(iface: iface, since: before, requireReceive: $0) },
            elapsed: { Date().timeIntervalSince(start) },
            sleep: { Thread.sleep(forTimeInterval: $0) })
        if result.reason == "gone" { return (false, "interface \(iface) is gone") }
        guard result.healthy else { return result }
        let age = handshakeAge(iface: iface).map { "\($0)s" } ?? "unknown"
        return (true, "transport moved in \(Int(Date().timeIntervalSince(start) * 1000)) ms (handshake \(age) ago)")
    }

    /// Start a non-blocking TCP connect and return the socket (or -1). The SYN
    /// leaves inside `connect`; the caller closes the socket when done. Best
    /// effort: a failure only means the wait falls back to the keepalive.
    static func sendSYN(to ip: String, port: UInt16) -> Int32 {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return -1 }
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return -1 }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return fd
    }

    /// Keys and values from `route -n get <query>`.
    ///
    /// `route get` prints "key: value" lines with varying indentation, and more
    /// than one line can repeat a key. The first occurrence wins, which is what
    /// Python's `line.startswith(...)` loop did.
    static func routeGetValues(_ query: [String],
                               using runner: CommandRunner = SystemRunner()) -> [String: String] {
        let result = runner.run("route", ["-n", "get"] + query, timeout: 10)
        guard result.ok else { return [:] }
        var values: [String: String] = [:]
        for line in result.output.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let colon = text.firstIndex(of: ":") else { continue }
            let key = String(text[text.startIndex..<colon])
            let value = text[text.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            if values[key] == nil { values[key] = value }
        }
        return values
    }

    // MARK: - Route primitives

    /// Add a network route through an interface.
    ///
    /// "File exists" counts as success: the prefix is already in the table and
    /// belongs to the same interface, so the desired end state holds. Do NOT
    /// pre-check with `route get` instead — that consults the route cache and
    /// returned a false positive in the Python version, which then skipped a
    /// route it had actually not added.
    ///
    /// The prefix is parsed before it reaches `route`. It always comes from
    /// `ranges(for:)` today, but a privileged tool that accepts `-ifscope` as
    /// an argument must never be handed a string that was not proven to be a
    /// prefix: a value starting with "-" would be read as another flag, not as
    /// a destination.
    public static func addRoute(_ cidr: String, iface: String) -> Mutation {
        guard Validate.network(cidr) != nil else {
            return Mutation(ok: false, detail: "'\(cidr)' is not a CIDR prefix")
        }
        let result = Shell.run("route", ["-n", "add"] + familyArgs(cidr) + ["-interface", iface])
        if result.ok { return Mutation(ok: true, detail: "added") }
        if result.output.contains("File exists") {
            return Mutation(ok: true, detail: "already present")
        }
        let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return Mutation(ok: false, detail: detail.isEmpty ? "rc=\(result.status)" : detail)
    }

    /// Pin one address to the physical gateway.
    ///
    /// This is the step that keeps the tunnel's own transport out of the
    /// tunnel. It must run before any wide route exists, so a failure here
    /// aborts with the table untouched.
    ///
    /// Both arguments are parsed first. The address comes from `wg show
    /// endpoints` and the gateway from `route get default`, i.e. from tool
    /// output rather than from the user — but tool output is untrusted input
    /// too, and a value beginning with "-" would be read by `route` as a flag.
    public static func addHostRoute(_ ip: String, gateway: String) -> Mutation {
        guard Validate.ipAddress(ip) != nil else {
            return Mutation(ok: false, detail: "endpoint is not an IP address")
        }
        guard Validate.ipAddress(gateway) != nil else {
            return Mutation(ok: false, detail: "gateway is not an IP address")
        }
        let result = Shell.run("route", ["-n", "add", "-host", ip, gateway])
        if result.ok { return Mutation(ok: true, detail: "added") }

        if result.output.contains("File exists") {
            // A stale pin can outlive a network change: it still points at the
            // gateway of the network the machine was on when it was created.
            // Accepting "File exists" blindly left the transport exempted to a
            // router that no longer answers.
            let existing = hostRouteGateway(ip)
            if existing == gateway {
                return Mutation(ok: true, detail: "already present")
            }
            _ = deleteHostRoute(ip)
            let retry = Shell.run("route", ["-n", "add", "-host", ip, gateway])
            if retry.ok {
                return Mutation(ok: true, detail: "replaced stale pin (\(existing ?? "unknown"))")
            }
            let detail = retry.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return Mutation(ok: false,
                            detail: detail.isEmpty ? "rc=\(retry.status)" : detail)
        }

        let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return Mutation(ok: false, detail: detail.isEmpty ? "rc=\(result.status)" : detail)
    }

    /// Gateway a host route currently uses, or nil when there is no such route.
    ///
    /// Used to tell "our pin is already correct" from "a stale pin from another
    /// network is sitting there". `route -n get` exits 0 even for an unknown
    /// destination on this platform, so presence is decided by the output, not
    /// by the exit status.
    public static func hostRouteGateway(_ ip: String,
                                        using runner: CommandRunner = SystemRunner())
        -> String? {
        guard Validate.ipAddress(ip) != nil else { return nil }
        let result = runner.run("route", ["-n", "get", "-host", ip], timeout: 10)
        guard result.ok, !result.output.contains("not in table") else { return nil }
        for line in result.output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("gateway:") {
                return trimmed.dropFirst("gateway:".count)
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        // A route that exists but has no gateway line is an on-link interface
        // route; report the empty string so callers can tell it apart from nil.
        return result.output.contains("interface:") ? "" : nil
    }

    @discardableResult
    public static func deleteRoute(_ cidr: String) -> Bool {
        // Same reason as `addRoute`: a value that is not a prefix is not passed
        // to a privileged tool, because "-foo" would be read as a flag.
        guard Validate.network(cidr) != nil else { return false }
        return deleted(Shell.run("route", ["-n", "delete"] + familyArgs(cidr)))
    }

    /// A delete succeeded, or there was nothing to delete.
    ///
    /// `route delete` fails with "not in table" for an absent route, and the
    /// goal (the route is not installed) is reached either way. Counting it as
    /// a failure kept routes that died with their interface recorded forever.
    static func deleted(_ result: CommandResult) -> Bool {
        result.ok || (!result.timedOut && result.output.contains("not in table"))
    }

    @discardableResult
    public static func deleteHostRoute(_ ip: String) -> Bool {
        guard Validate.ipAddress(ip) != nil else { return false }
        return deleted(Shell.run("route", ["-n", "delete", "-host", ip]))
    }

    /// Whether a prefix is in the table, optionally on a specific interface.
    ///
    /// Read-only and cache-sensitive, so it must never gate an `add`: see the
    /// note on `addRoute`.
    public static func routeExists(_ cidr: String, iface: String? = nil,
                                   using runner: CommandRunner = SystemRunner()) -> Bool {
        guard Validate.network(cidr) != nil else { return false }
        let result = runner.run("route", ["-n", "get"] + familyArgs(cidr), timeout: 10)
        guard result.ok else { return false }
        // `route -n get` exits 0 for a destination that is not in the table
        // ("route: writing to routing socket: not in table"), so presence has to
        // be decided by the output. Without this every prefix read as present
        // when the caller passed no interface.
        guard !result.output.contains("not in table"),
              result.output.contains("destination:") else { return false }
        guard let iface, !iface.isEmpty else { return true }
        // Full-line match: a substring test let "utun1" match "utun10", so a
        // route belonging to another interface read as ours.
        for line in result.output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "interface: \(iface)" { return true }
        }
        return false
    }

    /// One routing-table entry from `netstat -rn`: canonical prefix and its
    /// interface.
    public struct TableEntry: Equatable, Sendable {
        public let prefix: String
        public let iface: String
    }

    /// The whole table in one `netstat -rn`, or nil when it could not be read.
    ///
    /// The tick used to run one `route -n get` per recorded prefix (two in
    /// discord mode, four in all mode); one table read answers them all, and
    /// it matches the prefix exactly instead of whatever covering route
    /// `route get` would pick.
    public static func routeTable(using runner: CommandRunner = SystemRunner()) -> [TableEntry]? {
        let result = runner.run("netstat", ["-rn"], timeout: 10)
        guard result.ok else { return nil }
        return parseRouteTable(result.output)
    }

    /// Parse `netstat -rn` text. Lines that are not a route are skipped.
    static func parseRouteTable(_ text: String) -> [TableEntry] {
        var out: [TableEntry] = []
        var inet6 = false
        for line in text.split(separator: "\n") {
            if line.hasPrefix("Internet6") { inet6 = true; continue }
            if line.hasPrefix("Internet") { inet6 = false; continue }
            let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            // Destination Gateway Flags Netif [Expire]
            guard cols.count >= 4, cols[0] != "Destination",
                  let prefix = canonicalPrefix(cols[0], inet6: inet6) else { continue }
            out.append(TableEntry(prefix: prefix, iface: cols[3]))
        }
        return out
    }

    /// "162.159.128/18" -> "162.159.128.0/18", "::/1" -> "::/1"; nil for
    /// "default" and anything unparsable. netstat drops trailing zero octets,
    /// and omits the mask when it equals the octets shown (8 per octet).
    static func canonicalPrefix(_ text: String, inet6: Bool) -> String? {
        let parts = text.split(separator: "/", maxSplits: 1).map(String.init)
        var address = parts[0]
        if let scope = address.firstIndex(of: "%") { address = String(address[..<scope]) }
        if inet6 {
            var bytes = in6_addr()
            guard inet_pton(AF_INET6, address, &bytes) == 1 else { return nil }
            let length = parts.count > 1 ? Int(parts[1]) : 128
            guard let length else { return nil }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &bytes, &buffer, socklen_t(buffer.count)) != nil else { return nil }
            return String(cString: buffer) + "/\(length)"
        }
        let octets = address.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(octets.count),
              octets.allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false }) else { return nil }
        let length = parts.count > 1 ? Int(parts[1]) : 8 * octets.count
        guard let length else { return nil }
        let padded = octets.map(String.init) + Array(repeating: "0", count: 4 - octets.count)
        return padded.joined(separator: ".") + "/\(length)"
    }

    /// Whether a recorded prefix is in a table read by `routeTable`.
    public static func routeExists(_ cidr: String, iface: String?, in table: [TableEntry]) -> Bool {
        guard Validate.network(cidr) != nil,
              let want = canonicalPrefix(cidr, inet6: cidr.contains(":")) else { return false }
        return table.contains { entry in
            entry.prefix == want && (iface.map { $0.isEmpty || $0 == entry.iface } ?? true)
        }
    }

    /// `route` arguments that name a prefix: `-net` for IPv4, `-inet6` for
    /// IPv6 (`route -net ::/1` would be read as an IPv4 destination).
    static func familyArgs(_ cidr: String) -> [String] {
        cidr.contains(":") ? ["-inet6", cidr] : ["-net", cidr]
    }

    /// The prefixes a mode needs.
    public static func ranges(for mode: Mode) -> [String] {
        switch mode {
        case .all:
            // Two halves rather than 0.0.0.0/0: a /0 route would collide with
            // the default route entry and is harder to reason about during
            // rollback.
            //
            // The IPv6 halves are always routed into the tunnel (Y4). The
            // profile's AllowedIPs is ::/0, so with only the IPv4 halves every
            // IPv6 connection left in clear through the physical interface. A
            // profile with an IPv6 Address carries IPv6 through the tunnel; one
            // without has IPv6 black-holed, which is the leak-safe failure.
            return ["0.0.0.0/1", "128.0.0.0/1", "::/1", "8000::/1"]
        case .discord:
            return discordRanges
        case .off, .updates:
            return []
        }
    }

    /// The prefixes this run installs for `mode`: the mode's ranges, plus the
    /// resolver /32s in Discord mode (in all mode the halves cover them); in
    /// updates mode only the host and resolver /32s.
    func wanted(_ mode: Mode) -> [String] {
        let base = mode == .updates ? hostRoutes : RouteManager.ranges(for: mode)
        guard mode == .discord || mode == .updates else { return base }
        var out = base
        for cidr in dnsRoutes where !out.contains(cidr) { out.append(cidr) }
        return out
    }

    // MARK: - Rollback

    /// One mutation we may have to undo.
    private struct Undo {
        let kind: String
        let target: String
        /// Returns true when the mutation is definitely gone from the table.
        /// A false here means the route is still installed and must stay
        /// recorded, which is the difference L7 existed to point out: the old
        /// rollback discarded every result and then wrote "off" regardless.
        let revert: () -> Bool
    }

    /// Undo in reverse order: the last thing added is the first thing removed,
    /// so no intermediate state has a wide route without its endpoint pin.
    ///
    /// Returns what could not be undone.
    @discardableResult
    private func rollback(_ undos: [Undo], reason: String)
        -> (nets: Set<String>, hosts: Set<String>) {
        note("ROLLBACK (\(reason))")
        var nets: Set<String> = []
        var hosts: Set<String> = []
        for item in undos.reversed() {
            let gone = item.revert()
            if gone {
                note("  undone: \(item.kind) \(item.target)")
            } else {
                // Still in the table. Saying "undone" here was a lie the state
                // file then repeated.
                note("  COULD NOT undo: \(item.kind) \(item.target)")
                switch item.kind {
                case "net": nets.insert(item.target)
                case "host": hosts.insert(item.target)
                default: break
                }
            }
        }
        return (nets, hosts)
    }

    /// Undo what this run added, and record what survived.
    ///
    /// One call rather than two at every failure site: the failure modes that
    /// mattered (C3, L7) were both "the rollback ran but the state file said
    /// something else". Keeping them together means there is no path that
    /// rolls back without persisting, or persists without knowing what is still
    /// there.
    private func rollbackAndPersist(_ undos: [Undo],
                                    iface: String?,
                                    previous: RouteState,
                                    reason: String) {
        let left = rollback(undos, reason: reason)
        // Anything created by this run *and* reported gone by the rollback is
        // removed from the claim; anything still installed stays.
        var removedNets: Set<String> = []
        var removedHosts: Set<String> = []
        for undo in undos {
            let survived = (undo.kind == "net" ? left.nets : left.hosts)
            guard !survived.contains(undo.target) else { continue }
            if undo.kind == "net" { removedNets.insert(undo.target) }
            if undo.kind == "host" { removedHosts.insert(undo.target) }
        }
        persistAfterRollback(iface: iface, previous: previous,
                             removedNets: removedNets,
                             removedHosts: removedHosts,
                             leftNets: left.nets,
                             leftHosts: left.hosts)
    }

    /// Longest prefix first, preserving the original order for equal lengths.
    ///
    /// Removing a /18 before a /1 cannot orphan anything, while the reverse
    /// leaves a window where a wide route still points at an interface that no
    /// longer has the narrow one. The Python's comment said the same thing but
    /// its sort key ran the other way; the comment was right.
    static func longestPrefixFirst(_ nets: [String]) -> [String] {
        nets.enumerated()
            .sorted { lhs, rhs in
                let left = prefixLength(lhs.element)
                let right = prefixLength(rhs.element)
                if left != right { return left > right }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// Record what is still installed after a failed run.
    ///
    /// The previous code wrote a blank `off` state on every failure, which
    /// forgot routes from an earlier successful run that the rollback had not
    /// touched. Those routes stayed in the table with nothing pointing at them,
    /// so `down` could not remove them and `sanity` bailed out because an
    /// interface still existed. Merge instead: drop what is gone, keep the
    /// rest.
    ///
    /// `previous` is passed in rather than re-read because by this point the
    /// file already holds this run's *pending* intent; reading it back would
    /// merge the intent into the record of what survived.
    ///
    /// `leftNets` / `leftHosts` are this run's own additions that the rollback
    /// could not delete. They are not in `previous`, so without them the merge
    /// would drop a route that is still in the table — the same "unrecorded
    /// route" the whole mechanism exists to prevent.
    private func persistAfterRollback(iface: String?,
                                      previous: RouteState,
                                      removedNets: Set<String>,
                                      removedHosts: Set<String>,
                                      leftNets: Set<String> = [],
                                      leftHosts: Set<String> = []) {
        let survivingRoutes = previous.routes.filter { !removedNets.contains($0) }
            + leftNets.filter { !previous.routes.contains($0) }.sorted()
        let survivingHosts = previous.hosts.filter { !removedHosts.contains($0) }
            + leftHosts.filter { !previous.hosts.contains($0) }.sorted()

        if survivingRoutes.isEmpty && survivingHosts.isEmpty {
            saveState(RouteState(mode: Mode.off.rawValue, iface: iface,
                                 generation: previous.generation))
            return
        }
        // Something is still installed that this app put there; keep claiming
        // it so the next `down` or `sanity` can clean it up.
        saveState(RouteState(mode: previous.mode,
                             iface: previous.iface ?? iface,
                             routes: survivingRoutes,
                             hosts: survivingHosts,
                             gateway: previous.gateway,
                             profile: previous.profile,
                             pending: false,
                             generation: previous.generation))
        note("  kept \(survivingRoutes.count) route(s) and \(survivingHosts.count) host(s) in state for cleanup")
    }

    /// Schedule an unconditional rollback, even if this process is killed.
    ///
    /// The Python spawned `sleep N; python3 <script> down`. The Swift helper is
    /// the equivalent entry point, so the same trick uses its own argv[0]. Only
    /// a path this process was started with is interpolated, and it is quoted
    /// here rather than trusted.
    ///
    /// Two things changed after the review (H7):
    ///   * it is armed only after the apply succeeded, so a failed run cannot
    ///     leave a timer that tears down a healthy tunnel installed at t+60;
    ///   * the timer carries the generation it was armed for, and `down`
    ///     ignores a generation that has moved on. A timer is therefore a
    ///     no-op rather than a second, uncancellable teardown.
    ///
    /// Returns the warning to show the user, or nil when the net is armed. The
    /// warning is what makes "safety net not armed" visible: it used to go only
    /// to the journal, which nothing reads.
    @discardableResult
    private func armedRevert(seconds: Int, generation: Int) -> String? {
        guard seconds > 0 else { return nil }
        guard let helper = CommandLine.arguments.first, helper.hasPrefix("/") else {
            // Started through PATH, so there is no absolute path to re-execute.
            let message = "safety net not armed: the helper has no absolute path to re-run"
            note("  " + message)
            return message
        }
        let inner = "/bin/sleep \(seconds); \(shellQuote(helper)) down --if-generation \(generation)"
        let outer = "nohup /bin/sh -c \(shellQuote(inner)) >/dev/null 2>&1 &"
        let started = Shell.run("/bin/sh", ["-c", outer], timeout: 5)
        guard started.ok else {
            let message = "safety net not armed: could not start the revert timer"
            note("  " + message)
            return message
        }
        note("  safety net armed: routes revert in \(seconds)s unless generation \(generation) has moved on")
        return nil
    }

    // MARK: - up

    /// Bring the requested routes up, or leave the table exactly as it was.
    @discardableResult
    public func up(mode: Mode,
                   revertAfter: Int? = nil,
                   dryRun: Bool = false) -> ActionResult {
        // `up --mode off` used to report success without touching the state
        // file or any route, so the previous mode's routes stayed installed
        // while the CLI said "mod: off". Off is not a route set to bring up; it
        // is the teardown, so it goes to `down`.
        if mode == .off && !dryRun {
            return down()
        }

        var iface = probeInterfaces().first

        if iface == nil {
            if dryRun {
                note("dry-run: tunnel would be started with wg-quick")
                return ActionResult(ok: true, mode: mode.rawValue, notes: journal.lines)
            }
            // /var/run is cleared on reboot. wg-quick on a missing file fails
            // with output we must redact anyway, so say what happened instead.
            // The app maps this sentence; keep it stable.
            guard FileManager.default.fileExists(atPath: managedConfigPath) else {
                var missing = ActionResult.failure("tunnel config missing (cleared at restart); choose a server to recreate it",
                                                   notes: journal.lines)
                missing.code = ActionResult.configMissing
                return missing
            }
            note("tunnel is down; starting it")
            let started = run("wg-quick", ["up", managedConfigPath],
                              RouteManager.wireGuardTimeout)
            guard started.ok else {
                // wg-quick echoes offending config lines, and the managed config
                // holds the private key. Raw output never leaves this frame.
                return .redacted("tunnel start",
                                 summary: WireGuardProfiles.managedConfigSummary(path: managedConfigPath),
                                 notes: journal.lines)
            }
            iface = probeInterfaces().first
        }

        guard let iface else {
            return .failure("tunnel did not come up; refusing to touch routes",
                            notes: journal.lines)
        }

        // Step 1 of the contract: no route changes against a tunnel that is
        // not carrying packets, because the health check afterwards could not
        // tell "our route broke it" from "it was already broken".
        let before = probeHealth(iface)
        guard before.healthy else {
            return .failure("refusing to add routes: \(before.reason)",
                            notes: journal.lines)
        }
        note("tunnel \(iface) up (\(before.reason))")

        let ranges = wanted(mode)
        guard !ranges.isEmpty else {
            note("mode needs no routes")
            return ActionResult(ok: true, mode: mode.rawValue, iface: iface,
                                notes: journal.lines)
        }

        // A hardcoded router address is not a gateway. Pinning to one that does
        // not exist creates a host route that black-holes the transport on any
        // other network, so the run refuses instead.
        guard let gateway = probeGateway() else {
            return .failure("cannot determine the physical gateway; refusing to change routes",
                            notes: journal.lines)
        }
        let endpoint = probeEndpoint(iface)
        note("physical gateway \(gateway), endpoint \(endpoint ?? "unknown")")

        if dryRun {
            note("dry-run, would apply:")
            if let endpoint {
                note("  host \(endpoint) via \(gateway)   (keeps the transport out of the tunnel)")
            }
            for cidr in ranges {
                note("  net \(cidr) -> \(iface)")
            }
            return ActionResult(ok: true, mode: mode.rawValue, iface: iface,
                                endpoint: endpoint, routes: ranges,
                                notes: journal.lines)
        }

        // The endpoint MUST leave through the physical interface. Without this,
        // the tunnel's own transport is routed into the tunnel: the handshake
        // stops and the interface dies with the routes still in the table.
        // No endpoint means no pin is possible, so no wide route may be added
        // either — that used to be skipped silently (H1's neighbour).
        guard let endpoint else {
            return .failure("the tunnel reports no endpoint; refusing to add routes",
                            notes: journal.lines)
        }
        return apply(mode: mode, iface: iface, gateway: gateway, endpoint: endpoint,
                     revertAfter: revertAfter)
    }

    /// Pin the endpoint, add the mode's prefixes and prove the transport
    /// survived, recording a pending intent first and rolling back on any
    /// failure. Shared by `up` and `WireGuardProfiles.switchTo` (Y5) so a
    /// switch gets the same crash and partial-failure guarantees.
    func apply(mode: Mode, iface: String, gateway: String, endpoint: String,
               revertAfter: Int?) -> ActionResult {
        let ranges = wanted(mode)

        // Taken before anything changes, so the post-change check can ask
        // "did the transport move" rather than "is its age under a ceiling".
        let baseline = probeBaseline(iface)
        let previous = loadState()

        // H4: record the intent BEFORE touching the table. Up to here a SIGKILL
        // left routes installed that no file mentioned, so no later command
        // could find them. A `pending` file is a claim of what we are about to
        // install; `reconcilePendingState` removes anything a crashed run left.
        //
        // The intent is the union of what is already claimed and what this run
        // adds, because a crash makes both sets equally unverified: the old
        // routes are still in the table and must be removed too.
        var intent = previous
        intent.mode = mode.rawValue
        intent.iface = iface
        intent.routes = previous.routes + ranges.filter { !previous.routes.contains($0) }
        intent.hosts = previous.hosts + (previous.hosts.contains(endpoint) ? [] : [endpoint])
        intent.gateway = gateway
        intent.pending = true
        saveState(intent)

        var undos: [Undo] = []
        var addedHosts: [String] = []

        let pinned = addHost(endpoint, gateway)
        note("  endpoint \(endpoint) -> \(gateway): \(pinned.detail)")
        guard pinned.ok else {
            // Nothing has been added, so the pending intent is withdrawn and
            // the previous claim is restored untouched.
            saveState(previous)
            return .failure("cannot pin the endpoint; aborting before any route change",
                            notes: journal.lines)
        }
        if pinned.detail != "already present" {
            // Only an addition this run made is ours to remove; a pre-existing
            // pin belonged to an earlier run and its own state entry.
            undos.append(Undo(kind: "host", target: endpoint) {
                deleteHost(endpoint)
            })
        }
        addedHosts.append(endpoint)

        var addedNets: [String] = []
        for cidr in ranges {
            let added = addNet(cidr, iface)
            note("  net \(cidr) -> \(iface): \(added.detail)")
            guard added.ok else {
                rollbackAndPersist(undos, iface: iface, previous: previous,
                                   reason: "could not add \(cidr)")
                return .failure("could not add \(cidr): \(added.detail)",
                                notes: journal.lines)
            }
            if added.detail != "already present" {
                undos.append(Undo(kind: "net", target: cidr) {
                    deleteNet(cidr)
                })
            }
            addedNets.append(cidr)
        }

        // Prove the transport survived. A route set that kills the handshake is
        // indistinguishable from a dead server, so the check has to happen
        // after the routes exist, not before. Judged by progress since the
        // baseline, because a just-completed handshake always looks "recent"
        // even when the transport died the moment the routes went in.
        note("  waiting for the transport to move (settle \(Int(settle))s)")
        let after = probeProgress(iface, baseline, settle)
        guard after.healthy else {
            rollbackAndPersist(undos, iface: iface, previous: previous,
                               reason: after.reason)
            return .failure("tunnel degraded after adding routes: \(after.reason)",
                            notes: journal.lines)
        }
        note("  still healthy (\(after.reason))")

        // Only now is the state a completed fact. The generation is bumped so a
        // `--revert-after` timer armed by an earlier run cannot act on this one.
        let generation = previous.generation + 1

        // Routes and pins from an earlier run that this one did not touch are
        // still installed, so they stay recorded. Dropping them from the file
        // was how a successful `up` could make an earlier mode's routes
        // unreachable by `down`: they were in the table and no longer in the
        // record.
        let extraRoutes = previous.routes.filter { !addedNets.contains($0) }
        let extraHosts = previous.hosts.filter { !addedHosts.contains($0) }

        saveState(RouteState(mode: mode.rawValue,
                             iface: iface,
                             routes: addedNets + extraRoutes,
                             hosts: addedHosts + extraHosts,
                             gateway: gateway,
                             profile: previous.profile,
                             pending: false,
                             generation: generation))
        // Armed after the success, not before: a timer from a run that failed
        // must not fire later and tear down a tunnel that now works.
        if let warning = armedRevert(seconds: revertAfter ?? 0, generation: generation) {
            note(warning)
        }
        note("mode=\(mode.rawValue) routes=\(addedNets.count) endpoint pinned")
        return ActionResult(ok: true, mode: mode.rawValue, iface: iface,
                            endpoint: endpoint, routes: addedNets,
                            notes: journal.lines)
    }

    // MARK: - down

    /// Remove exactly what the state file records.
    ///
    /// The WireGuard interface is deliberately left up. It is loaded with
    /// `Table = off`, so without our prefixes it carries no traffic; keeping
    /// it is what lets `up` re-route at once without a new wg-quick start and
    /// handshake, and the app shows that state as "off" rather than "down".
    /// `switch` and the uninstaller stop the tunnel itself.
    ///
    /// `ifGeneration` is the generation an armed `--revert-after` timer was
    /// created with. When it no longer matches, the timer belongs to a run that
    /// has been superseded, and doing nothing is the whole point: the old code
    /// had no way to cancel a timer, so `up --revert-after 300` that failed and
    /// was followed by a successful `up` at t=60 was torn down at t=300.
    @discardableResult
    public func down(ifGeneration: Int? = nil) -> ActionResult {
        let (loaded, corrupt) = RouteStateStore.loadChecked(path: statePath)
        if corrupt {
            return downFromCorruptState()
        }
        var state = loaded

        if let ifGeneration, ifGeneration != state.generation {
            note("stale revert timer (generation \(ifGeneration), state is \(state.generation)); ignoring")
            return ActionResult(ok: true, mode: state.mode, iface: state.iface,
                                notes: journal.lines)
        }

        state = dropUnusableEntries(state)

        // A pending file means a run died mid-apply. Its routes may or may not
        // be installed, and the safest reading is to remove everything listed:
        // a delete of something absent is a no-op, while keeping something
        // present and unrecorded is the black hole this file exists to prevent.
        if state.pending {
            note("state was pending (a run did not finish); removing everything it listed")
            return reconcilePendingState(state)
        }

        let nets = RouteManager.longestPrefixFirst(state.routes)

        var removed: [String] = []
        var failed: [String] = []
        for cidr in nets {
            if deleteNet(cidr) { removed.append(cidr) }
            else { failed.append(cidr) }
        }
        var hostsLeft: [String] = []
        for host in state.hosts {
            if !deleteHost(host) { hostsLeft.append(host) }
        }

        // Keep whatever could not be removed. Clearing the file regardless was
        // how a partially-failed teardown became unrecoverable: the routes were
        // still installed, but no command knew about them any more.
        if failed.isEmpty && hostsLeft.isEmpty {
            saveState(RouteState(mode: Mode.off.rawValue,
                                 iface: state.iface,
                                 generation: state.generation))
            note("removed \(removed.count)/\(nets.count) route(s)")
            return ActionResult(ok: true, mode: Mode.off.rawValue, iface: state.iface,
                                notes: journal.lines)
        }

        saveState(RouteState(mode: state.mode,
                                        iface: state.iface,
                                        routes: failed,
                                        hosts: hostsLeft,
                                        gateway: state.gateway,
                                        profile: state.profile,
                                        pending: false,
                                        generation: state.generation))
        note("removed \(removed.count)/\(nets.count) route(s); \(failed.count) still installed")
        return .failure("could not remove \(failed.count) route(s) and \(hostsLeft.count) host rule(s); they are kept in the state file for the next attempt",
                        notes: journal.lines)
    }

    // MARK: - teardown

    /// `down`, then stop Menfez's own WireGuard interface and delete the
    /// managed config (a copy of the profile, private key included).
    ///
    /// For when the server behind the tunnel is gone: its profile was deleted,
    /// the tunnel is an orphan, or the helper is being removed. `down` keeps
    /// the interface on purpose (a mode switch re-routes at once, with no new
    /// handshake), which left a deleted server's idle utun up forever.
    ///
    /// Only the managed interface is touched: `wg-quick down` is given the
    /// managed config, so another WireGuard client's utun is never stopped.
    @discardableResult
    public func teardown() -> ActionResult {
        let routes = down()
        guard routes.ok else { return routes }
        let stopped = stopTunnel(managedConfigPath)
        var state = loadState()
        if let ours = state.iface, probeInterfaces().contains(ours) {
            return .failure("could not stop the tunnel interface \(ours)", notes: journal.lines)
        }
        unlink(managedConfigPath)
        state.iface = nil
        saveState(state)
        note(stopped ? "tunnel interface stopped" : "no tunnel interface was running")
        return ActionResult(ok: true, mode: Mode.off.rawValue, notes: journal.lines)
    }

    /// `down` with an unreadable state file.
    ///
    /// The file used to load as an empty "off" state, so `down` removed
    /// nothing and the live routes were forgotten. Every prefix Menfez can add
    /// is deleted instead (a delete of an absent route is a no-op). Host pins
    /// cannot be known without the file, so they are reported, not guessed.
    /// The damaged file is kept beside the new one for inspection.
    private func downFromCorruptState() -> ActionResult {
        note("route state is unreadable; removing every prefix Menfez can add")
        let known = RouteManager.longestPrefixFirst(
            Array(Set(RouteManager.ranges(for: .all) + RouteManager.ranges(for: .discord))))
        let failed = known.filter { !deleteNet($0) }
        _ = rename(statePath, statePath + ".corrupt")
        saveState(RouteState(mode: Mode.off.rawValue, routes: failed))
        note("the endpoint host route, if any, is unknown and was not removed; "
             + "the damaged file is at \(statePath).corrupt")
        guard failed.isEmpty else {
            return .failure("could not remove \(failed.count) route(s); they are kept in the state file for the next attempt",
                            notes: journal.lines)
        }
        return ActionResult(ok: true, mode: Mode.off.rawValue, notes: journal.lines)
    }

    /// Drop entries that can never be a route, and say so.
    ///
    /// A state file is writable input as far as this process knows: it is
    /// written by root, but it is also the one persisted artefact an interrupted
    /// run can leave half-finished. A value that is not a CIDR or an address
    /// must not be handed to `route` — `route delete "-ifscope"` would be a flag
    /// — and keeping it in the file would make every later `down` fail forever.
    /// It is removed with a note rather than being silently carried.
    private func dropUnusableEntries(_ state: RouteState) -> RouteState {
        var cleaned = state
        let badNets = state.routes.filter { Validate.network($0) == nil }
        let badHosts = state.hosts.filter { Validate.ipAddress($0) == nil }
        guard !badNets.isEmpty || !badHosts.isEmpty else { return state }

        cleaned.routes = state.routes.filter { Validate.network($0) != nil }
        cleaned.hosts = state.hosts.filter { Validate.ipAddress($0) != nil }
        var notes: [String] = []
        if !badNets.isEmpty {
            notes.append("\(badNets.count) recorded prefix(es) were not valid CIDRs and were dropped")
        }
        if !badHosts.isEmpty {
            notes.append("\(badHosts.count) recorded host route(s) were not valid addresses and were dropped")
        }
        note("  " + notes.joined(separator: "; "))
        saveState(cleaned)
        return cleaned
    }

    /// Remove everything a pending state lists, then write "off".
    ///
    /// Used by `down` and by start-up reconciliation. A delete that fails here
    /// is left in the file: it is still an unrecorded route in the table, so
    /// the next attempt must see it.
    private func reconcilePendingState(_ state: RouteState) -> ActionResult {
        var failedNets: [String] = []
        for cidr in RouteManager.longestPrefixFirst(state.routes) {
            if !deleteNet(cidr) { failedNets.append(cidr) }
        }
        var failedHosts: [String] = []
        for host in state.hosts {
            if !deleteHost(host) { failedHosts.append(host) }
        }

        if failedNets.isEmpty && failedHosts.isEmpty {
            saveState(RouteState(mode: Mode.off.rawValue,
                                 iface: state.iface,
                                 generation: state.generation))
            note("pending intent cleared: \(state.routes.count) route(s) and \(state.hosts.count) host(s) removed")
            return ActionResult(ok: true, mode: Mode.off.rawValue, iface: state.iface,
                                notes: journal.lines)
        }

        saveState(RouteState(mode: state.mode,
                             iface: state.iface,
                             routes: failedNets,
                             hosts: failedHosts,
                             gateway: state.gateway,
                             profile: state.profile,
                             pending: false,
                             generation: state.generation))
        return ActionResult(ok: false,
                            error: "a previous run was interrupted and \(failedNets.count) of its route(s) could not be removed; they stay recorded for the next attempt",
                            mode: state.mode, iface: state.iface,
                            routes: failedNets, notes: journal.lines)
    }

    // MARK: - Start-up reconciliation

    /// Undo whatever an interrupted run left behind.
    ///
    /// Called by every command that reads the state before acting on it. Cheap
    /// when there is nothing to do — one file read — and the only place that
    /// can find unrecorded routes after a SIGKILL, since the normal `down`
    /// would treat the pending file as an ordinary claim.
    @discardableResult
    public func reconcile() -> ActionResult? {
        let state = loadState()
        guard state.pending else { return nil }
        note("found a pending state from an interrupted run; reconciling")
        return reconcilePendingState(state)
    }

    // MARK: - mode

    /// Swap the route set without touching the tunnel.
    @discardableResult
    public func changeMode(to mode: Mode, dryRun: Bool = false) -> ActionResult {
        // `mode off` is the teardown, same reasoning as `up --mode off`.
        if mode == .off && !dryRun {
            return down()
        }

        var state = loadState()
        let iface = probeInterfaces().first ?? state.iface
        guard let iface else {
            return .failure("tunnel is not up; use 'up' instead", notes: journal.lines)
        }

        let probe = probeHealth(iface)
        guard probe.healthy else {
            return .failure("refusing to change routes: \(probe.reason)",
                            notes: journal.lines)
        }

        let oldNets = Set(state.routes)
        let newNets = Set(wanted(mode))

        if dryRun {
            let remove = oldNets.subtracting(newNets).sorted()
            let add = newNets.subtracting(oldNets).sorted()
            note("dry-run, would remove: \(remove.isEmpty ? "nothing" : remove.joined(separator: ", "))")
            note("dry-run, would add:    \(add.isEmpty ? "nothing" : add.joined(separator: ", "))")
            return ActionResult(ok: true, mode: mode.rawValue, iface: iface, routes: add,
                                notes: journal.lines)
        }

        guard let gateway = probeGateway() else {
            return .failure("cannot determine the physical gateway; refusing to change routes",
                            notes: journal.lines)
        }
        guard let endpoint = probeEndpoint(iface) else {
            return .failure("the tunnel reports no endpoint; refusing to change routes",
                            notes: journal.lines)
        }

        // H2: the pin is probed, never taken from the state file.
        //
        // The old code skipped the pin when `state.hosts` claimed it, on the
        // theory that re-adding would "hide a pin that had been removed behind
        // our back". It hid the removal instead: the state file still said the
        // transport was exempted, so a wide prefix could be added with no live
        // pin. A probe costs one `route get` and answers the question the state
        // file was guessing at.
        let liveGateway = probeHostGateway(endpoint)
        let previous = state

        // Y5: record the intent BEFORE touching the table, as `up` does. A
        // crash mid-swap used to leave prefixes no file mentioned; a pending
        // union of the old and new sets lets the next command remove them.
        var intent = previous
        intent.mode = mode.rawValue
        intent.iface = iface
        intent.routes = previous.routes
            + newNets.sorted().filter { !previous.routes.contains($0) }
        if !intent.hosts.contains(endpoint) { intent.hosts.append(endpoint) }
        intent.gateway = gateway
        intent.pending = true
        saveState(intent)

        if liveGateway != gateway {
            let pinned = addHost(endpoint, gateway)
            note("  endpoint \(endpoint) -> \(gateway): \(pinned.detail)")
            guard pinned.ok else {
                saveState(previous)
                return .failure("cannot pin the endpoint; aborting", notes: journal.lines)
            }
        } else {
            note("  endpoint \(endpoint) already pinned via \(gateway)")
        }

        // The pin is never undone: a pin to the live gateway is right for both
        // route sets, and removing it on rollback would leave the restored set
        // unpinned. It therefore stays claimed whatever happens next.
        var base = previous
        if !base.hosts.contains(endpoint) { base.hosts.append(endpoint) }
        base.gateway = gateway

        var undos: [Undo] = []
        for cidr in RouteManager.longestPrefixFirst(Array(oldNets.subtracting(newNets))) {
            guard deleteNet(cidr) else {
                // Still installed and still claimed by `base`; ignoring this
                // used to record a route set the table did not have.
                rollbackAndPersist(undos, iface: iface, previous: base,
                                   reason: "could not remove \(cidr)")
                return .failure("could not remove \(cidr); restored the previous set",
                                notes: journal.lines)
            }
            note("  removed \(cidr)")
            // "restore" rather than "net": a reverted delete puts the route
            // back, so it must stay claimed rather than be dropped from state.
            undos.append(Undo(kind: "restore", target: cidr) {
                addNet(cidr, iface).ok
            })
        }

        var live: [String] = []
        for cidr in newNets.sorted() {
            let added = addNet(cidr, iface)
            note("  \(cidr): \(added.detail)")
            guard added.ok else {
                // The half-applied new prefixes are removed before the old set
                // is restored (reverse order), and what survives is recorded.
                rollbackAndPersist(undos, iface: iface, previous: base,
                                   reason: "could not add \(cidr)")
                return .failure("route add failed for \(cidr); restored the previous set",
                                notes: journal.lines)
            }
            if added.detail != "already present" {
                undos.append(Undo(kind: "net", target: cidr) { deleteNet(cidr) })
            }
            live.append(cidr)
        }

        Thread.sleep(forTimeInterval: min(settle, RouteManager.swapSettleSeconds))
        let after = probeHealth(iface)
        guard after.healthy else {
            rollbackAndPersist(undos, iface: iface, previous: base, reason: after.reason)
            return .failure("tunnel degraded after the swap (\(after.reason)); restored",
                            notes: journal.lines)
        }

        state = base
        state.mode = mode.rawValue
        state.iface = iface
        state.routes = live
        state.pending = false
        state.generation += 1
        saveState(state)
        note("mode=\(mode.rawValue) routes=\(live.count) (\(after.reason))")
        return ActionResult(ok: true, mode: mode.rawValue, iface: iface,
                            endpoint: endpoint, routes: live, notes: journal.lines)
    }

    // MARK: - repin

    /// Move the endpoint pin to the current physical gateway (K5).
    ///
    /// After a Wi-Fi switch or a wake on another network the pin still points
    /// at the old router, so the transport dies and "all" mode black-holes
    /// everything. Nothing else changes: the prefixes are on the utun and stay
    /// valid. A no-op when there is no tunnel, no routed mode, no physical
    /// gateway (offline: the old pin is left for when the network returns) or
    /// when the pin already uses the current gateway.
    ///
    /// No pending intent: the endpoint is claimed in `hosts` before the route
    /// changes, so a crash leaves a recorded pin, and a pending file would make
    /// the next command tear the whole route set down instead.
    @discardableResult
    public func repin() -> ActionResult {
        var state = loadState()
        guard Mode(rawValue: state.mode) != .off,
              let iface = probeInterfaces().first,
              let endpoint = probeEndpoint(iface) else {
            note("no routed tunnel; nothing to re-pin")
            return ActionResult(ok: true, mode: state.mode, notes: journal.lines)
        }
        guard let gateway = probeGateway() else {
            note("no physical gateway; leaving the pin as it is")
            return ActionResult(ok: true, mode: state.mode, iface: iface,
                                endpoint: endpoint, notes: journal.lines)
        }
        if probeHostGateway(endpoint) == gateway {
            note("endpoint \(endpoint) already pinned via \(gateway)")
            return ActionResult(ok: true, mode: state.mode, iface: iface,
                                endpoint: endpoint, routes: state.routes,
                                notes: journal.lines)
        }

        if !state.hosts.contains(endpoint) { state.hosts.append(endpoint) }
        state.gateway = gateway
        saveState(state)

        // `addHostRoute` replaces a stale pin to another gateway itself.
        let pinned = addHost(endpoint, gateway)
        note("  endpoint \(endpoint) -> \(gateway): \(pinned.detail)")
        guard pinned.ok else {
            return .failure("could not re-pin \(endpoint) via \(gateway): \(pinned.detail)",
                            notes: journal.lines)
        }
        return ActionResult(ok: true, mode: state.mode, iface: iface,
                            endpoint: endpoint, routes: state.routes,
                            notes: journal.lines)
    }

    // MARK: - sanity

    /// Remove recorded routes that a dead tunnel left behind.
    ///
    /// This is residue cleanup, not the safety mechanism: routes on a utun
    /// disappear with the interface. It matters when the interface name is
    /// reused or a route was added through a gateway and survived.
    ///
    /// A pending file is reconciled first even when an interface is up: the
    /// interrupted run's routes were added, not merely intended, so "an
    /// interface exists, nothing to clean" was exactly the check that let them
    /// survive.
    @discardableResult
    public func sanity() -> ActionResult {
        var state = loadState()

        if state.pending {
            note("state was pending (a run did not finish); reconciling")
            let reconciled = reconcilePendingState(state)
            if !reconciled.ok { return reconciled }
            state = loadState()
        }

        if let iface = RouteManager.interfaces().first,
           RouteManager.interfaceExists(iface) {
            note("tunnel \(iface) is up; nothing to clean")
            return ActionResult(ok: true, mode: state.mode, iface: iface,
                                notes: journal.lines)
        }

        guard !state.routes.isEmpty || !state.hosts.isEmpty else {
            note("no recorded routes; nothing to clean")
            return ActionResult(ok: true, mode: state.mode, notes: journal.lines)
        }

        note("tunnel is down but \(state.routes.count) route(s) and \(state.hosts.count) host(s) remain")
        // H5: a delete that failed leaves a route in the table, so it stays
        // recorded. Writing a blank "off" regardless forgot it for good.
        var failedNets: [String] = []
        for cidr in RouteManager.longestPrefixFirst(state.routes) {
            let removed = deleteNet(cidr)
            note("  \(removed ? "removed" : "FAILED ") \(cidr)")
            if !removed { failedNets.append(cidr) }
        }
        let failedHosts = state.hosts.filter { !deleteHost($0) }
        saveState(RouteState(mode: Mode.off.rawValue,
                             routes: failedNets,
                             hosts: failedHosts,
                             gateway: state.gateway,
                             generation: state.generation))
        guard failedNets.isEmpty && failedHosts.isEmpty else {
            return ActionResult(ok: false,
                                error: "could not remove \(failedNets.count) route(s) and \(failedHosts.count) host rule(s); they stay recorded for the next attempt",
                                mode: Mode.off.rawValue, routes: failedNets,
                                notes: journal.lines)
        }
        return ActionResult(ok: true, mode: Mode.off.rawValue, notes: journal.lines)
    }
}

// MARK: - State file

/// Which routes this app added, so `down` removes exactly those.
///
/// A half-written state file after a crash would make `down` forget routes that
/// are still in the table, so the write is atomic: a temporary file plus
/// rename, never a truncate.
public enum RouteStateStore {

    public static func load(path: String = Path.routeState) -> RouteState {
        loadChecked(path: path).state
    }

    /// The state plus whether a file existed that could not be decoded.
    ///
    /// "Corrupt" and "no file" both load as the empty "off" state, but only
    /// the second one means nothing is installed: `down` uses the flag to fall
    /// back to deleting every prefix Menfez can ever add.
    public static func loadChecked(path: String = Path.routeState) -> (state: RouteState, corrupt: Bool) {
        guard FileManager.default.fileExists(atPath: path) else { return (RouteState.empty, false) }
        guard let data = FileManager.default.contents(atPath: path),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return (RouteState.empty, true) }
        return (RouteState(mode: stored.mode ?? Mode.off.rawValue,
                          iface: stored.iface,
                          routes: stored.routes ?? [],
                          hosts: stored.hosts ?? [],
                          gateway: stored.gateway,
                          profile: stored.profile,
                          pending: stored.pending ?? false,
                          generation: stored.generation ?? 0), false)
    }

    @discardableResult
    public static func save(_ state: RouteState, path: String = Path.routeState) -> Bool {
        guard let text = StateFile.encode(state) else { return false }
        return StateFile.write(text, to: path)
    }

    /// Loosely typed mirror of RouteState.
    ///
    /// Python's loader returned `{}` for anything unreadable and then used
    /// `.get` with defaults, so a file missing `routes` still reported its
    /// mode. Decoding RouteState directly would throw those fields away and
    /// silently claim "off" while the routes were live.
    private struct Stored: Decodable {
        var mode: String?
        var iface: String?
        var routes: [String]?
        var hosts: [String]?
        var gateway: String?
        var profile: String?
        var pending: Bool?
        var generation: Int?
    }
}

// MARK: - Shared atomic write

/// Atomic JSON file helper, shared by the route and DNS state files.
enum StateFile {

    static func encode<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        // Sorted keys keep a diff of two state files readable. `withoutEscapingSlashes`
        // is not cosmetic: CIDRs would otherwise be written as "162.159.128.0\/18",
        // which decodes identically but no longer matches the file the Python
        // prototype produced. The trailing newline keeps `cat` from joining the
        // JSON with the shell prompt.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return nil }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return text + "\n"
    }

    /// Write `text` to `path` via a temporary file, fsync and rename.
    ///
    /// - Parameter mode: file permissions. The route state is 0644 because the
    ///   unprivileged app has to read it to render the route list; the DNS
    ///   state describes which network the user is on and is 0600.
    /// - Parameter dirMode: the parent directory's mode, stated by the caller.
    ///   It used to be derived from `mode`, so writing the 0600 DNS file into
    ///   /var/run/menfez flipped that shared directory to 0700 and hid the
    ///   route state from the app. 0755 keeps /var/run/menfez traversable.
    static func write(_ text: String, to path: String,
                      mode: mode_t = 0o644, dirMode: mode_t = 0o755) -> Bool {
        let directory = (path as NSString).deletingLastPathComponent
        guard Path.ensureDir(directory, mode: dirMode) else { return false }

        let temporary = path + ".tmp"
        unlink(temporary)
        // O_EXCL + O_NOFOLLOW: a planted link at the temporary name is refused.
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
        guard fd >= 0 else { return false }
        let bytes = Array(text.utf8)
        let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        // fchmod because open's mode is filtered by the umask. fsync before the
        // rename so a crash cannot leave a renamed but empty state file.
        let ok = written == bytes.count && fchmod(fd, mode) == 0 && fsync(fd) == 0
        close(fd)
        guard ok, rename(temporary, path) == 0 else {
            unlink(temporary)
            return false
        }
        // Persist the rename itself.
        let dirFD = open(directory, O_RDONLY)
        if dirFD >= 0 { fsync(dirFD); close(dirFD) }
        return true
    }
}

// MARK: - Small helpers

/// "24" from "162.159.128.0/24"; 0 when the string has no usable prefix.
private func prefixLength(_ cidr: String) -> Int {
    guard let slash = cidr.lastIndex(of: "/") else { return 0 }
    return Int(cidr[cidr.index(after: slash)...]) ?? 0
}

/// Quote one argument for /bin/sh.
///
/// Deliberately kept: the `--revert-after` timer is the one place a string
/// reaches a shell, and it interpolates only the helper's own absolute path and
/// an integer. Everything else goes through `Shell.run(tool, [args])`.
private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
