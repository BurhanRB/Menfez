// main.swift — the privileged helper.
//
// Menfez runs this through passwordless sudo:
//
//     sudo -n /path/to/menfez-route <command>
//
// It is the only process that changes the routing table, WireGuard or DNS.
// Keeping every mutation behind one entry point is what makes the rollback
// guarantees in RouteManager meaningful: there is exactly one caller, it is
// short-lived, and it always prints a single JSON object so the app never has
// to parse prose.
//
// Subcommands
//     report            full observation for the UI (slow: two HTTPS probes)
//     report --fast     skip egress IP, geo and the Discord probe
//     facts             the privileged half of a report: one wg read
//     up [--mode M] [--revert-after N] [--dry-run]
//     down
//     teardown          down, then stop the interface and delete its config
//     version           protocol version, for the app's update notice
//     mode <discord|all>
//     switch <profile>
//     dns status | set <preset-id|ip> | auto
//     detail <ip|routes|dns|tunnel|discord> [--value V]
//     profiles
//     status            human-readable, for the shell
//     sanity            remove routes left behind by a dead tunnel
//     repin             move the endpoint pin to the current physical gateway
//     killswitch on|off|status   block traffic outside the tunnel (pf anchor)
//
// `facts` exists because the app's periodic refresh used to ask for a whole
// `report --fast` just to learn four numbers about the tunnel. Those four
// numbers are the only thing `wg show <iface>` can tell us and the only part of
// the report that cannot be read as the user, so they get their own tiny
// command and the app calls it far less often than it redraws. See
// docs/READ-PATH.md for the measurements behind that.
//
// Exit codes: 0 success, 1 failure, 2 usage error, 3 not root.

import Foundation
import MenfezCore

// MARK: - Output

/// Print one JSON object and terminate. The app always reads the last line, and
/// taking the last brace-line means a warning printed earlier cannot break it.
///
/// Written with FileHandle rather than `print` on purpose. `print` goes through
/// a buffered stdout, and `exit()` does not flush it in an optimised build; the
/// result was that `up`, `down`, `mode` and `sanity` reported success with an
/// empty stdout in Release while working correctly in Debug. A caller reading
/// the JSON saw nothing at all. Writing straight to the descriptor removes the
/// buffer from the path.
///
/// `value` is `Encodable` rather than a generic parameter on purpose. As
/// `emit<T: Encodable>`, every mutating command died with SIGTRAP and wrote
/// nothing: `sanity`, `down`, `up` and `mode <x>` trapped at a `brk #0x1`
/// (Swift's `unreachable`, EXC_BREAKPOINT) in the top-level switch, before the
/// body of `emit` ran, while the read-only commands that never reach this call
/// were fine. Taking an existential instead of a generic parameter removes the
/// `emit<…>_Tg5` specialisation the trap was attributed to, and with it the
/// crash — verified by building both ways and running each binary.
///
/// The lock was not the cause: `LockTests` covers the acquire/release cycle
/// that the crash was first blamed on.
func emit(_ value: Encodable, exit code: Int32 = 0) -> Never {
    let encoded = JSON.encode(value)
    let text = encoded + "\n"
    FileHandle.standardOutput.write(Data(text.utf8))
    exit(code)
}

func fail(_ message: String, exit code: Int32 = 1) -> Never {
    emit(ActionResult.failure(message), exit: code)
}

func usage() -> Never {
    let text = """
    usage: menfez-route <command>

      report [--fast]
      facts
      up [--mode discord|all|off|updates] [--revert-after N] [--dry-run] [--dns-routes IP,IP]
         [--host-routes IP,IP]   (updates mode only, and required there)
         [--tunnel-dns IP,IP]    (resolvers the system uses while mode is all)
      down [--if-generation N]
      teardown          down, then stop the tunnel interface and delete its config
      mode <discord|all|updates> [--dry-run] [--dns-routes IP,IP] [--host-routes IP,IP] [--tunnel-dns IP,IP]
      switch <profile-name> [--dns-routes IP,IP] [--tunnel-dns IP,IP]
      dns status | set <preset-id|address> | auto
      detail <ip|routes|dns|tunnel|discord> [--value V]
      profiles
      status
      sanity
      repin
      killswitch on|off|status   block traffic outside the tunnel if it drops
      version           the helper's protocol version (no root needed)

    Exits: 0 ok, 1 failure, 2 usage error, 3 not root.
    """
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(2)
}

// MARK: - Argument handling

/// Tiny manual parser. ArgumentParser would pull in a dependency for a helper
/// that has eight subcommands; a switch is easier to audit.
struct Args {
    private var flags: Set<String> = []
    private var values: [String: String] = [:]
    private(set) var positional: [String] = []

    init(_ raw: [String]) {
        var i = 0
        while i < raw.count {
            let item = raw[i]
            if item.hasPrefix("--") {
                let name = String(item.dropFirst(2))
                if i + 1 < raw.count, !raw[i + 1].hasPrefix("--") {
                    values[name] = raw[i + 1]
                    i += 2
                } else {
                    flags.insert(name)
                    i += 1
                }
            } else {
                positional.append(item)
                i += 1
            }
        }
    }

    func has(_ name: String) -> Bool { flags.contains(name) }
    func value(_ name: String) -> String? { values[name] }
    func int(_ name: String) -> Int? { values[name].flatMap(Int.init) }
    var first: String? { positional.first }
    var second: String? { positional.count > 1 ? positional[1] : nil }
}

// MARK: - Locking

/// Commands that change routing or DNS. They serialize on one flock; a second
/// invocation fails fast with a message naming the holder instead of
/// interleaving read-modify-write cycles and corrupting the state file.
let mutating: Set<String> = ["up", "down", "teardown", "mode", "switch", "dns", "sanity", "repin",
                              "killswitch"]

/// The lock for a mutating command, or nil for any other.
///
/// Returned rather than stored in a global `var` from here: a nonisolated
/// function writing a main-actor global is an error under strict concurrency.
/// Root is checked first, so a non-root caller gets exit 3 and never creates
/// or contends for the lock file.
func acquireLockIfNeeded(_ command: String) -> FileLock? {
    guard mutating.contains(command) else { return nil }
    requireRoot()
    switch Locking.acquireRouteLock() {
    case .success(let lock):
        return lock
    case .failure(let busy):
        fail(busy.message)
    }
}

// MARK: - Root check

func requireRoot() {
    guard geteuid() == 0 else {
        // Exit 3, not 0: a shell script that runs this to test a sudoers rule
        // would otherwise treat the refusal as success.
        FileHandle.standardError.write(Data("menfez-route must run as root\n".utf8))
        exit(3)
    }
}

// MARK: - Start-up reconciliation

/// Clear anything an interrupted run left in the route table.
///
/// A `pending` state file means a run died between "I am about to add these"
/// and "these are live". Its routes were probably installed, and no completed
/// run recorded them, so without this step the only command that could find
/// them is the one that already checks for the marker. Running it before every
/// mutating command means a crash is repaired by the next thing the user does.
func reconcileOrFail(_ manager: RouteManager) {
    if let result = manager.reconcile(), !result.ok {
        emit(result, exit: 1)
    }
}

// MARK: - Commands

let raw = Array(CommandLine.arguments.dropFirst())
guard let command = raw.first else { usage() }
let args = Args(Array(raw.dropFirst()))

// `dns status` and `report` are read-only; everything else mutates.
let readOnly = (command == "report" || command == "detail"
                || command == "profiles" || command == "status"
                || command == "facts" || command == "version"
                || (command == "dns" && (args.first ?? "status") == "status")
                || (command == "killswitch" && args.first == "status"))
/// Held for the rest of the process lifetime when acquired.
let routeLock = readOnly ? nil : acquireLockIfNeeded(command)

/// Parse a `--mode` value, refusing an explicit unknown one.
///
/// The decision lives in `Mode.argument` so it can be unit-tested; this wrapper
/// only turns a rejection into exit 2.
func parseMode(_ raw: String?, allowingOff: Bool = true) -> Mode {
    switch Mode.argument(raw, allowingOff: allowingOff) {
    case .success(let mode):
        return mode
    case .failure(let problem):
        fail(problem.message, exit: 2)
    }
}

/// `--dns-routes`: resolver /32s for Discord mode. Public IPv4 only; any
/// other entry refuses the command, since this value crosses into root.
func dnsRoutes() -> [String] {
    let problem = "--dns-routes needs a comma-separated list of public IPv4 addresses"
    guard let raw = args.value("dns-routes") else {
        if args.has("dns-routes") { fail(problem, exit: 2) }
        return []
    }
    guard let routes = RouteManager.dnsRoutes(argument: raw) else { fail(problem, exit: 2) }
    return routes
}

/// `--tunnel-dns`: the resolvers Whole internet points the system at. 1 to 4
/// IP addresses; anything else refuses the command before it runs.
func tunnelDNS() -> [String] {
    let problem = "--tunnel-dns needs 1 to \(TunnelScope.maxDNS) comma-separated IP addresses"
    guard let raw = args.value("tunnel-dns") else {
        if args.has("tunnel-dns") { fail(problem, exit: 2) }
        return []
    }
    guard let servers = TunnelScope.dnsArgument(raw) else { fail(problem, exit: 2) }
    return servers
}

/// Move the system resolver onto the tunnel in Whole internet, and give it
/// back when any other mode settles. A DNS failure does not undo the routes;
/// it is added to the result's notes so the user sees it.
func withTunnelDNS(_ result: ActionResult, servers: [String]) -> ActionResult {
    var result = result
    let outcome: ActionResult?
    switch TunnelScope.dnsStep(ok: result.ok, mode: result.mode,
                               stateMode: RouteStateStore.load().mode, servers: servers) {
    case .takeOver(let list): outcome = DNSManager().takeOverForTunnel(servers: list)
    case .release: outcome = DNSManager().releaseFromTunnel()
    case .none: outcome = nil
    }
    if let outcome, !outcome.ok {
        result.notes.append("DNS: \(outcome.error ?? "could not be changed")")
    }
    return result
}

/// `--host-routes`: the /32s updates mode carries. Required in updates mode
/// and refused in every other, so a stray flag cannot widen a route set.
func hostRoutes(for mode: Mode) -> [String] {
    let problem = "--host-routes needs a comma-separated list of at most "
        + "\(RouteManager.maxHostRoutes) public IPv4 addresses, and only with updates mode"
    guard mode == .updates else {
        if args.has("host-routes") || args.value("host-routes") != nil { fail(problem, exit: 2) }
        return []
    }
    guard let raw = args.value("host-routes"),
          let routes = RouteManager.hostRoutes(argument: raw) else { fail(problem, exit: 2) }
    return routes
}

/// After a command that may move the interface, endpoint or scope: rebuild
/// the kill switch rules if the block is on. A failure is a note, not an error.
func withKillSwitch(_ result: ActionResult) -> ActionResult {
    guard result.ok, let note = KillSwitch.refreshIfOn() else { return result }
    var result = result
    result.notes.append(note)
    return result
}

switch command {

case "report":
    requireRoot()
    let full = !args.has("fast")
    emit(ReportBuilder().build(full: full))

case "facts":
    // The narrow privileged read. No `report`, no probes, no state file: four
    // `wg` invocations and one JSON object. A missing interface is not an
    // error here — it is `tunnel: null`, which the app merges as "no tunnel".
    requireRoot()
    let iface = RouteManager.interfaceList()?.first
    emit(iface.map { RouteManager.facts(iface: $0) } ?? RouteManager.TunnelFacts())

case "up":
    requireRoot()
    let mode = parseMode(args.value("mode"))
    var manager = RouteManager()
    manager.dnsRoutes = dnsRoutes()
    manager.hostRoutes = hostRoutes(for: mode)
    let servers = tunnelDNS()
    // A previous run that did not finish is repaired before a new one starts:
    // otherwise its route set is merged with this one and neither `down` nor
    // the health check can tell which routes came from where.
    reconcileOrFail(manager)
    let dryRun = args.has("dry-run")
    var result = manager.up(mode: mode,
                            revertAfter: args.int("revert-after"),
                            dryRun: dryRun)
    if !dryRun { result = withKillSwitch(withTunnelDNS(result, servers: servers)) }
    emit(result, exit: result.ok ? 0 : 1)

case "down":
    requireRoot()
    // `--if-generation` is how an armed `--revert-after` timer identifies the
    // run it was created for. A timer whose generation has been superseded does
    // nothing, so an old timer cannot tear down a tunnel installed later.
    // No reconcile step: `down` is what performs the reconciliation.
    // An unparsable value used to become nil, i.e. an unconditional `down`.
    var ifGeneration: Int?
    if args.has("if-generation") || args.value("if-generation") != nil {
        guard let generation = Validate.generation(args.value("if-generation")) else {
            fail("--if-generation needs a non-negative integer", exit: 2)
        }
        ifGeneration = generation
    }
    // A revert timer ends here too, so this is where a held resolver goes back.
    let result = withTunnelDNS(RouteManager().down(ifGeneration: ifGeneration), servers: [])
    emit(result, exit: result.ok ? 0 : 1)

case "teardown":
    // For a deleted or orphaned server and for removal: unlike `down`, the
    // interface goes too. Takes no arguments.
    requireRoot()
    guard args.positional.isEmpty else { fail("teardown takes no arguments", exit: 2) }
    // The server is gone or the helper is being removed: nothing left to protect.
    KillSwitch.off()
    let result = withTunnelDNS(RouteManager().teardown(), servers: [])
    emit(result, exit: result.ok ? 0 : 1)

case "version":
    // Read by the app as the user, to offer an update of an older helper.
    emit(HelperVersion.Reply(version: HelperVersion.current))

case "mode":
    requireRoot()
    guard let name = args.first else {
        fail("mode must be 'discord' or 'all'", exit: 2)
    }
    guard case .success(let mode) = Mode.argument(name, allowingOff: false) else {
        fail("mode must be 'discord', 'all' or 'updates'", exit: 2)
    }
    var manager = RouteManager()
    manager.dnsRoutes = dnsRoutes()
    manager.hostRoutes = hostRoutes(for: mode)
    let servers = tunnelDNS()
    reconcileOrFail(manager)
    let dryRun = args.has("dry-run")
    var result = manager.changeMode(to: mode, dryRun: dryRun)
    if !dryRun { result = withKillSwitch(withTunnelDNS(result, servers: servers)) }
    emit(result, exit: result.ok ? 0 : 1)

case "switch":
    requireRoot()
    guard let name = args.first else { fail("switch needs a profile name", exit: 2) }
    let routes = dnsRoutes()
    let servers = tunnelDNS()
    reconcileOrFail(RouteManager())
    let result = withKillSwitch(withTunnelDNS(WireGuardProfiles.switchTo(name: name, dnsRoutes: routes),
                                              servers: servers))
    emit(result, exit: result.ok ? 0 : 1)

case "dns":
    requireRoot()
    let action = args.first ?? "status"
    switch action {
    case "status", "test":
        emit(DNSManager().report())
    case "auto":
        // The user's own choice replaces a resolver Whole internet was holding.
        DNSManager().forgetTunnelTakeover()
        emit(DNSManager().restoreAutomatic())
    case "set":
        guard let target = args.second else {
            fail("dns set needs a preset id or an address", exit: 2)
        }
        // Validated before anything is written: a resolver must parse as an IP
        // address, and the message names the token that failed.
        if let problem = DNSManager.targetProblem(target) {
            fail(problem, exit: 2)
        }
        DNSManager().forgetTunnelTakeover()
        emit(DNSManager().apply(target: target))
    default:
        fail("unknown dns action '\(action)'", exit: 2)
    }

case "detail":
    requireRoot()
    guard let what = args.first else { fail("detail needs a kind", exit: 2) }
    emit(Details.build(what: what, value: args.value("value")))

case "profiles":
    requireRoot()
    // `resolveLiveHost: true` keeps this output identical to what it was: the
    // helper is root, so reading the live endpoint here costs nothing and the
    // `active` flag stays accurate. The app's own picker uses the
    // non-resolving overload instead.
    emit(ProfilesResponse(profiles: WireGuardProfiles.list(liveHost: nil,
                                                          resolveLiveHost: true),
                          activeIface: RouteManager.interfaceList()?.first))

case "sanity":
    requireRoot()
    // Off after a dead tunnel: a resolver still held for it is given back.
    let result = withTunnelDNS(RouteManager().sanity(), servers: [])
    emit(result, exit: result.ok ? 0 : 1)

case "repin":
    // Takes no arguments; anything extra is a caller bug, not something to
    // guess about while holding the route lock.
    requireRoot()
    guard args.positional.isEmpty else { fail("repin takes no arguments", exit: 2) }
    let manager = RouteManager()
    reconcileOrFail(manager)
    let result = withKillSwitch(manager.repin())
    emit(result, exit: result.ok ? 0 : 1)

case "killswitch":
    // Only on or off comes from the caller; the rules are built from this
    // helper's own state and `wg show`, never from arguments.
    requireRoot()
    switch args.first {
    case "on":
        let result = KillSwitch.on()
        emit(result, exit: result.ok ? 0 : 1)
    case "off":
        let result = KillSwitch.off()
        emit(result, exit: result.ok ? 0 : 1)
    case "status":
        emit(KillSwitch.load().map { ActionResult(ok: true, mode: $0.scope, iface: $0.iface) }
             ?? ActionResult(ok: true, mode: Mode.off.rawValue))
    default:
        fail("killswitch needs on, off or status", exit: 2)
    }

case "status":
    // Human-readable, for a terminal; the app never calls this.
    requireRoot()
    let report = ReportBuilder().build(full: false)
    print("tunnel:  \(report.tunnel ?? "down")")
    if report.tunnel != nil {
        print("health:  \(report.health.ok ? "ok" : "BROKEN") (\(report.health.code.rawValue))")
        if let endpoint = report.endpoint { print("peer:    \(endpoint)") }
    }
    print("mode:    \(report.mode)")
    // A structural inconsistency is the only thing `error` carries, and a
    // terminal is the one place a user can see it without the UI.
    if let error = report.error { print("warning: \(error)") }
    print("routes:  \(report.routes.count)")
    for route in report.routes {
        print("  \(route.cidr)  \(route.present ? "present" : "MISSING")")
    }
    for host in report.hosts {
        print("  host \(host)")
    }
    // print() is buffered; exit() does not flush it.
    fflush(stdout)

default:
    usage()
}
