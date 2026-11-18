// DNSManager.swift — the system resolver, and the promise that `auto` puts
// back what was there before.
//
// WHY THIS EXISTS AT ALL
// A split tunnel is only half a fix for a blocked network. If the ISP resolver
// answers Discord's names with a private address — a captive portal or a
// transparent interceptor does exactly that — the client never reaches the
// tunnel's side of the world no matter what the route table says. So the app
// offers public resolvers, measures them live, and can hand control back.
//
// THE RULE THAT MATTERS
// Writing the resolver settings is a change to the user's machine that survives
// a crash, so the previous value is read and stored BEFORE the first write, and
// `restoreAutomatic` puts it back. Losing that saved value leaves the user on a
// resolver they did not choose, which is why the state file is written
// atomically and why `set` never overwrites an existing saved entry for the
// same service: the first observation is the true original.
//
// networksetup works on service names ("Wi-Fi"), not interface names ("en0"),
// so every entry point starts by mapping the interface that carries the default
// route onto its service. When that mapping fails, nothing is changed.
//
// NOTHING IS HARD-CODED ABOUT SPEED
// Latency comes from a live `dig` against each resolver. A cached or guessed
// number would be wrong the moment the user moves between networks, and the
// picker's whole value is ranking resolvers for *this* connection.

import Foundation

public struct DNSManager {

    // MARK: - Presets

    /// Public resolvers, in the order they appear in the Python picker.
    ///
    /// `v4` is what gets applied; the pair matters because a single resolver is
    /// a single point of failure. Latency is never stored here — see `report`.
    public static let presets: [DNSPreset] = [
        DNSPreset(id: "cloudflare", name: "Cloudflare", note: "fast, privacy-first",
                  v4: ["1.1.1.1", "1.0.0.1"]),
        DNSPreset(id: "google", name: "Google", note: "very reliable, logs queries",
                  v4: ["8.8.8.8", "8.8.4.4"]),
        DNSPreset(id: "quad9", name: "Quad9", note: "blocks malware domains",
                  v4: ["9.9.9.9", "149.112.112.112"]),
        DNSPreset(id: "adguard", name: "AdGuard", note: "blocks ads and trackers",
                  v4: ["94.140.14.14", "94.140.15.15"]),
        DNSPreset(id: "opendns", name: "OpenDNS", note: "family filter option",
                  v4: ["208.67.222.222", "208.67.220.220"]),
        DNSPreset(id: "yandex", name: "Yandex", note: "good reachability in TR",
                  v4: ["77.88.8.8", "77.88.8.1"]),
        // An empty `v4` means "automatic": picking this row is the same as
        // `auto`, which is why it is an ordinary row in the picker rather than
        // a separate button.
        DNSPreset(id: "system", name: "Automatic", note: "from DHCP, restored on stop",
                  v4: []),
    ]

    /// Rank for an entry with no measurement, so unreachable resolvers sort last.
    private static let noLatency = 9999

    // Seams for `apply` and `restoreAutomatic`, so a test can drive them
    // without touching this machine's resolver or root-owned state.
    var statePath = Path.dnsState
    var legacyStatePath: String? = Path.legacyDNSState
    var findService: () -> String? = { DNSManager.activeService() }
    var readServers: (String) -> [String]? = { DNSManager.currentChecked(service: $0) }
    var writeServers: (String, [String]) -> Bool = { DNSManager.set(service: $0, servers: $1) }
    var listServices: () -> [String]? = { DNSManager.allServices() }

    public init() {}

    // MARK: - Service resolution

    /// Network service name behind the interface that carries the default route.
    ///
    /// Two commands because macOS keeps the two namespaces apart: `route` knows
    /// "en0", networksetup knows "Wi-Fi", and only
    /// `-listnetworkserviceorder` links them.
    public static func activeService(using runner: CommandRunner = SystemRunner())
        -> String? {
        activeService(interface: RouteManager.primaryInterface(using: runner),
                      using: runner)
    }

    /// The same lookup with the interface already known.
    ///
    /// The report has just read the default route to get the gateway, so asking
    /// for the interface again would be a second `route -n get default` in the
    /// same refresh — a process for a value already in hand.
    public static func activeService(interface: String?,
                                     using runner: CommandRunner = SystemRunner())
        -> String? {
        guard let iface = interface, !iface.isEmpty else { return nil }

        let result = runner.run("networksetup", ["-listnetworkserviceorder"], timeout: 15)
        guard result.ok else { return nil }

        var current: String?
        for line in result.output.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)

            // Service headers look like "(1) Wi-Fi"; the hardware line under
            // them starts with "(Hardware Port:". Skipping the latter is what
            // keeps `current` pointing at the service name.
            if text.hasPrefix("("), text.contains(")"),
               !text.hasPrefix("(Hardware") {
                current = after(")", in: text)
            } else if text.contains("Device:") {
                // "… Device: en0)" — the trailing paren is part of the format.
                var device = after("Device:", in: text)
                while device.hasSuffix(")") { device.removeLast() }
                if device == iface, let current, !current.isEmpty {
                    return current
                }
            }
        }
        return nil
    }

    // MARK: - Reading and writing

    /// Every network service name, disabled ones included; nil when
    /// networksetup failed. The first line is the "An asterisk (*) denotes"
    /// legend, and a leading "*" marks a disabled (but existing) service.
    public static func allServices(using runner: CommandRunner = SystemRunner()) -> [String]? {
        let result = runner.run("networksetup", ["-listallnetworkservices"], timeout: 15)
        guard result.ok else { return nil }
        return result.output.split(separator: "\n").dropFirst().map {
            var name = $0.trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") { name.removeFirst() }
            return name
        }
    }

    /// Resolvers currently configured for a service; empty means DHCP.
    public static func current(service: String,
                              using runner: CommandRunner = SystemRunner()) -> [String] {
        currentChecked(service: service, using: runner) ?? []
    }

    /// The same read, but nil when networksetup failed instead of answering.
    ///
    /// `current` folds a failure into "automatic", which is fine for display
    /// but not for recording the original: a failed read saved as [] would
    /// make `auto` reset a user's static resolvers to DHCP. networksetup
    /// often exits 0 on error ("** Error: ..."), so any line that is neither
    /// an address nor the "There aren't any DNS Servers set" sentence counts
    /// as a failure.
    public static func currentChecked(service: String,
                                      using runner: CommandRunner = SystemRunner()) -> [String]? {
        guard !service.isEmpty else { return nil }
        let result = runner.run("networksetup", ["-getdnsservers", service], timeout: 15)
        guard result.ok else { return nil }
        var servers: [String] = []
        for line in result.output.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty || text.hasPrefix("There aren") { continue }
            guard let ip = Validate.ipAddress(text) else { return nil }
            servers.append(ip)
        }
        return servers
    }

    /// UserDefaults key: route the system resolvers into the tunnel in Discord
    /// mode. On when unset.
    public static let tunnelDNSKey = "dnsThroughTunnel"

    public static func routesDNSThroughTunnel(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: tunnelDNSKey) as? Bool ?? true
    }

    /// The resolvers the system is using now, from `scutil --dns`, in order.
    /// networksetup only knows resolvers set by hand; a DHCP one shows up here.
    public static func systemResolvers(using runner: CommandRunner = SystemRunner()) -> [String] {
        let result = runner.run("scutil", ["--dns"], timeout: 5)
        return result.ok ? resolvers(scutil: result.output) : []
    }

    static func resolvers(scutil text: String) -> [String] {
        var out: [String] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces).hasPrefix("nameserver[") else { continue }
            let server = parts[1].trimmingCharacters(in: .whitespaces)
            if !out.contains(server) { out.append(server) }
        }
        return out
    }

    /// Apply resolvers to a service and flush the cache.
    ///
    /// An empty list is written as "Empty", networksetup's word for "back to
    /// DHCP". Without the flush the old answers survive in the mDNSResponder
    /// cache for minutes and the user concludes the change did not work.
    @discardableResult
    public static func set(service: String, servers: [String]) -> Bool {
        guard !service.isEmpty else { return false }
        let targets = servers.isEmpty ? ["Empty"] : servers
        let result = Shell.run("networksetup", ["-setdnsservers", service] + targets)
        guard result.ok else { return false }

        _ = Shell.run("dscacheutil", ["-flushcache"])
        // killall reports 1 when the daemon is not running; launchd will start
        // it on the next query, so that is not a failure of the change.
        _ = Shell.run("killall", ["-HUP", "mDNSResponder"])
        return true
    }

    // MARK: - Measurement

    /// Median latency in milliseconds for one resolver, or nil.
    ///
    /// Delegates to the shared probe so the resolver picker and the DNS detail
    /// popup can never disagree about what a resolver costs.
    public static func latency(server: String,
                               using runner: CommandRunner = SystemRunner()) -> Int? {
        Probes.dnsLatency(server: server, using: runner)
    }

    /// A/AAAA answers for one name from one resolver.
    public static func answers(server: String, name: String = "example.com",
                               using runner: CommandRunner = SystemRunner()) -> [String] {
        Probes.dnsAnswers(server: server, name: name, using: runner)
    }

    /// A poisoned resolver typically answers with a private or bogus address.
    public static func looksPoisoned(_ ips: [String]) -> Bool {
        Probes.looksPoisoned(ips)
    }

    // MARK: - Report

    /// Everything the DNS sheet needs, with the presets ranked for this link.
    public func report() -> DNSReport {
        report(using: SystemRunner())
    }

    /// The same report, with the process launcher injected.
    ///
    /// The sheet is opened by a click, so its cost is paid once; injection is
    /// here so a test can prove which commands it would run without touching
    /// the network.
    public func report(using runner: CommandRunner) -> DNSReport {
        let service = DNSManager.activeService(using: runner)
        let current = service.map { DNSManager.current(service: $0, using: runner) } ?? []

        var ranked: [DNSPreset] = []
        var order: [String: Int] = [:]
        for (index, preset) in DNSManager.presets.enumerated() {
            var entry = preset
            // `active` needs a non-empty match: an empty `current` (DHCP) must
            // not read as "Automatic is selected but has no servers".
            entry.active = !current.isEmpty && !preset.v4.isEmpty && current == preset.v4

            if let primary = preset.v4.first {
                let ms = DNSManager.latency(server: primary, using: runner)
                entry.ms = ms
                // A resolver that answers quickly with a private address is
                // worse than one that times out, so both count as not OK.
                entry.ok = ms != nil && !DNSManager.looksPoisoned(
                    DNSManager.answers(server: primary, using: runner))
            }
            ranked.append(entry)
            order[entry.id] = index
        }

        // Unreachable last, then fastest first. Python's key was
        // `(ms is None, ms or 9999)`, and its `or` also pushed a literal 0 ms
        // to the end; 0 ms is not a measurement anyone trusts, so that stays.
        // Ties fall back to the preset order, so two refreshes a second apart
        // cannot reshuffle the list under the pointer.
        ranked.sort { lhs, rhs in
            let leftMissing = lhs.ms == nil
            let rightMissing = rhs.ms == nil
            if leftMissing != rightMissing { return !leftMissing }

            let leftRank = DNSManager.rank(lhs.ms)
            let rightRank = DNSManager.rank(rhs.ms)
            if leftRank != rightRank { return leftRank < rightRank }
            return (order[lhs.id] ?? 0) < (order[rhs.id] ?? 0)
        }

        return DNSReport(service: service, current: current, presets: ranked)
    }

    private static func rank(_ ms: Int?) -> Int {
        guard let ms, ms != 0 else { return noLatency }
        return ms
    }

    // MARK: - Actions

    /// Apply a preset id, the "system" preset, or literal addresses.
    ///
    /// `target` is a preset id ("cloudflare"), "system", or one or more
    /// addresses separated by commas or spaces. Presets are looked up first,
    /// which is the order the Python parser used.
    @discardableResult
    public func apply(target: String) -> ActionResult {
        // A target that cannot be applied is refused before `activeService()`
        // runs: the message is about what the user typed, not about the network,
        // and nothing is written for a request that could never be honoured.
        if let problem = DNSManager.targetProblem(target) {
            return .failure(problem)
        }

        guard let service = findService() else {
            return .failure("no active network service")
        }

        // "Automatic" is not a resolver to write; it is the restore path. It is
        // routed here rather than going through `set(servers: [])` so the saved
        // original is consumed the same way `auto` consumes it. (The Python
        // rejected `set system` as an unknown resolver; the picker offers this
        // row, so accepting it is the fix.)
        if target == "system" {
            return restoreAutomatic()
        }

        let servers = DNSManager.resolve(target: target)
        guard !servers.isEmpty else {
            // `targetProblem` already covered every case that reaches here, so
            // this is the empty-input path; the wording still names the user's
            // input rather than pretending the network failed.
            return .failure(DNSManager.targetProblem(target) ?? "no resolver given")
        }

        var (state, corrupt) = DNSStateStore.loadChecked(path: statePath, legacy: legacyStatePath)
        if corrupt {
            // The file existed but could not be read, so any "original" it once
            // held may still be in those bytes. Writing now would replace the
            // only record of it, so refuse and leave the file for inspection.
            return .failure("the saved resolver state at \(statePath) is unreadable; "
                            + "refusing to change DNS until it is checked and removed")
        }
        // Only the first observation is recorded: a second `set` without an
        // intervening `restoreAutomatic` would otherwise store the resolver we
        // applied, and `auto` would "restore" the user to our own choice.
        if state.previous[service] == nil {
            // A failed read must not be recorded as "automatic": `auto` would
            // then reset a user's static resolvers to DHCP.
            guard let original = readServers(service) else {
                return .failure("could not read the current DNS of \(service); nothing was changed")
            }
            state.previous[service] = original
        }

        // Persist the original before changing anything. Crash safety beat
        // tidiness here: writing the resolver first meant a kill in between
        // left the machine on a resolver whose predecessor was never recorded,
        // so `auto` restored DHCP instead of the user's static servers.
        guard DNSStateStore.save(state, path: statePath, legacy: legacyStatePath) else {
            return .failure("could not save the current DNS before changing it; nothing was changed")
        }

        guard writeServers(service, servers) else {
            return .failure("networksetup refused to set DNS on \(service)")
        }
        // Recorded only once it is true: a failed set left the old resolver.
        state.applied = servers
        DNSStateStore.save(state, path: statePath, legacy: legacyStatePath)
        return ActionResult(ok: true, servers: servers)
    }

    /// Apply by preset id, under the name the task sheet uses.
    @discardableResult
    public func apply(presetId: String) -> ActionResult {
        apply(target: presetId)
    }

    /// Put the saved resolvers back and forget them.
    ///
    /// A corrupt state file must not be turned into a write. "Corrupt" here
    /// means the file exists but could not be decoded; the only safe reading is
    /// "we have no saved value", so "automatic" is applied and the corruption
    /// is reported, rather than either crashing or writing the mangled content
    /// back. The load is read-only either way, so the damaged file is left for
    /// a human to inspect.
    @discardableResult
    public func restoreAutomatic() -> ActionResult {
        let active = findService()
        var (state, corrupt) = DNSStateStore.loadChecked(path: statePath, legacy: legacyStatePath)
        if corrupt {
            // Nothing saved can be trusted, so only the active service goes back
            // to DHCP, and the damaged file is neither rewritten nor removed.
            guard let active else { return .failure("no active network service") }
            let note = "the saved resolver state was unreadable; falling back to automatic "
                + "and leaving the damaged file for inspection"
            guard writeServers(active, []) else {
                return .failure("networksetup refused to restore DNS on \(active)", notes: [note])
            }
            return ActionResult(ok: true, servers: [], notes: [note])
        }

        // Every service we changed goes back, not only the one that carries
        // the default route now: after a switch from Wi-Fi to Ethernet the
        // Wi-Fi override would otherwise outlive `auto` with nothing to undo it.
        // With nothing saved, "automatic" on the active service is the no-op
        // the user asked for.
        var targets = state.previous
        if targets.isEmpty {
            guard let active else { return .failure("no active network service") }
            targets[active] = []
        }

        var failed: [String] = []
        var notes: [String] = []
        for (service, servers) in targets.sorted(by: { $0.key < $1.key }) {
            if writeServers(service, servers) {
                state.previous.removeValue(forKey: service)
            } else if let names = listServices(), !names.contains(service) {
                // Gone (an unplugged USB adapter): nothing left to restore. A
                // failed listing keeps the record, since absence is unproven.
                state.previous.removeValue(forKey: service)
                notes.append("\(service) no longer exists; dropped its saved DNS")
            } else {
                // Keep the record: the original is still what this service
                // should return to on the next attempt.
                failed.append(service)
            }
        }
        if state.previous.isEmpty { state.applied = [] }
        DNSStateStore.save(state, path: statePath, legacy: legacyStatePath)

        guard failed.isEmpty else {
            return .failure("networksetup refused to restore DNS on "
                            + failed.joined(separator: ", "), notes: notes)
        }
        return ActionResult(ok: true, servers: active.flatMap { targets[$0] } ?? [], notes: notes)
    }

    // MARK: - Whole internet

    /// Point the system at the tunnel's resolvers, remembering what Menfez had
    /// applied before so `releaseFromTunnel` can put it back. The marker is
    /// saved before the write, so a crash in between still leaves a way back.
    @discardableResult
    public func takeOverForTunnel(servers: [String]) -> ActionResult {
        let (state, corrupt) = DNSStateStore.loadChecked(path: statePath, legacy: legacyStatePath)
        if corrupt { return apply(target: servers.joined(separator: ",")) }
        if state.tunnelBefore == nil {
            var marked = state
            marked.tunnelBefore = state.applied
            guard DNSStateStore.save(marked, path: statePath, legacy: legacyStatePath) else {
                return .failure("could not save the current DNS before changing it; nothing was changed")
            }
        }
        return apply(target: servers.joined(separator: ","))
    }

    /// Undo `takeOverForTunnel`: re-apply the user's earlier choice, or go back
    /// to the original resolver. Nil when the tunnel never took it over.
    @discardableResult
    public func releaseFromTunnel() -> ActionResult? {
        guard let before = DNSStateStore.loadChecked(path: statePath, legacy: legacyStatePath).state.tunnelBefore
        else { return nil }
        let result = before.isEmpty ? restoreAutomatic() : apply(target: before.joined(separator: ","))
        if result.ok { forgetTunnelTakeover() }
        return result
    }

    /// The user picked a resolver themselves: theirs wins, nothing to undo later.
    public func forgetTunnelTakeover() {
        var (state, corrupt) = DNSStateStore.loadChecked(path: statePath, legacy: legacyStatePath)
        guard !corrupt, state.tunnelBefore != nil else { return }
        state.tunnelBefore = nil
        DNSStateStore.save(state, path: statePath, legacy: legacyStatePath)
    }

    /// Preset id first, then literal addresses.
    ///
    /// Every literal must parse as an IP address. The old filter was a
    /// character-class check (`[0-9a-f:.]+`), which let "cafe" or "1.2.3"
    /// through to `networksetup -setdnsservers`; that tool then wrote whatever
    /// it was given into the system resolver configuration. Parsing first means
    /// a malformed token is refused by us, with a sentence, instead of being
    /// handed to a privileged tool that might interpret it.
    static func resolve(target: String) -> [String] {
        if let preset = presets.first(where: { $0.id == target }) {
            return preset.v4
        }
        return literalResolvers(target)
    }

    /// The tokens of a literal resolver list, validated and canonicalised.
    static func literalResolvers(_ target: String) -> [String] {
        target
            .replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .compactMap { Validate.ipAddress($0) }
    }

    /// Why `target` cannot be applied, or nil when it can.
    ///
    /// Kept separate from `resolve` so the CLI can print the offending token
    /// rather than a generic "unknown resolver", and so `apply` refuses before
    /// any state file is touched.
    public static func targetProblem(_ target: String) -> String? {
        if presets.contains(where: { $0.id == target }) { return nil }
        if target == "system" { return nil }

        let tokens = target
            .replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !tokens.isEmpty else { return "no resolver given" }
        for token in tokens where Validate.ipAddress(token) == nil {
            return "'\(token)' is not an IP address; expected a preset id or addresses like 1.1.1.1"
        }
        return nil
    }
}

// MARK: - State file

/// The resolver that was active before we changed it.
///
/// A missing or unreadable file means "we never changed anything", which is the
/// only safe interpretation: claiming a saved value we cannot read would make
/// `restoreAutomatic` write a wrong resolver.
public enum DNSStateStore {

    public static func load(path: String = Path.dnsState) -> DNSState {
        loadChecked(path: path).state
    }

    /// The state plus whether a file existed that could not be decoded.
    ///
    /// Returned rather than kept in a static flag: only the two actions that
    /// *write* need to tell "no file" from "unreadable file", and a shared
    /// mutable global is a data race under strict concurrency.
    ///
    /// - Parameter legacy: read when `path` does not exist yet, so a record
    ///   written by an older release (in /var/run) is not lost on upgrade.
    public static func loadChecked(path: String = Path.dnsState,
                                   legacy: String? = nil) -> (state: DNSState, corrupt: Bool) {
        var source = path
        if !FileManager.default.fileExists(atPath: path),
           let legacy, FileManager.default.fileExists(atPath: legacy) {
            source = legacy
        }
        guard FileManager.default.fileExists(atPath: source) else { return (DNSState(), false) }
        guard let data = FileManager.default.contents(atPath: source),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else {
            // The file exists and cannot be read. It is not deleted and not
            // rewritten: the damaged bytes may be the only record of a
            // resolver the user chose, and guessing at them is exactly what
            // `restoreAutomatic` must not do.
            return (DNSState(), true)
        }
        return (DNSState(previous: stored.previous ?? [:], applied: stored.applied ?? [],
                         tunnelBefore: stored.tunnelBefore), false)
    }

    /// Write the state; once it is safely at `path`, drop the `legacy` copy.
    @discardableResult
    public static func save(_ state: DNSState, path: String = Path.dnsState,
                            legacy: String? = nil) -> Bool {
        guard let text = StateFile.encode(state) else { return false }
        // 0600 in a 0700 directory: the file names the network services the
        // user has configured, and only root needs it.
        guard StateFile.write(text, to: path, mode: 0o600, dirMode: 0o700) else { return false }
        if let legacy { unlink(legacy) }
        return true
    }

    /// Loosely typed mirror, so a file with only one of the two fields still
    /// yields the other instead of being discarded wholesale.
    private struct Stored: Decodable {
        var previous: [String: [String]]?
        var applied: [String]?
        var tunnelBefore: [String]?
    }
}

// MARK: - Small helpers

/// Everything after `separator` on a line, trimmed.
private func after(_ separator: String, in line: String) -> String {
    guard let range = line.range(of: separator) else { return "" }
    return line[range.upperBound...].trimmingCharacters(in: .whitespaces)
}
