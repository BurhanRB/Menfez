// KillSwitch.swift — "block internet if the tunnel drops", with pf.
//
// WHAT IT TOUCHES
// One pf anchor, `com.apple/250.Menfez`. Apple's /etc/pf.conf, loaded at every
// boot, already says `anchor "com.apple/*"`, so rules loaded into a child of it
// are evaluated without editing pf.conf or the main ruleset. Menfez never runs
// `pfctl -f` without `-a`, never flushes anything but its own anchor, and
// enables pf by reference (`-E`, released with `-X <token>`), so a pf another
// program enabled is never switched off by us.
//
// HOW IT IS UNDONE
// `menfez-route killswitch off` flushes the anchor and releases the token. The
// anchor is not in pf.conf, so a restart clears it too. `teardown`,
// `install-helper.sh --remove`, `uninstall.sh` and quitting the app all clear
// it. By hand, from Terminal:
//     sudo /Library/PrivilegedHelperTools/menfez/menfez-route killswitch off
// and if the helper is gone:
//     sudo pfctl -a com.apple/250.Menfez -F all
//
// THE RULES
// Whole internet: loopback, the tunnel interface, the WireGuard endpoint, DHCP
// and the local network stay open; DNS anywhere but through the tunnel and
// everything else outbound is dropped. Discord only: Discord's ranges are
// dropped unless they leave through the tunnel; nothing else changes. Discord
// + chosen sites: the same, plus the sites' /32s and /128s the helper recorded
// in its own state file (`RouteState.sites`).
//
// The rules are built here from values the helper read itself (its own state
// file and `wg show`), never from the app's arguments: the app only says on or
// off. Each value is validated before it is written into pf syntax.

import Foundation

public enum KillSwitch {

    public static let anchor = "com.apple/250.Menfez"

    /// What the user can paste into Terminal when the app is not there.
    public static let terminalOff = Path.trustedHelper + " killswitch off"

    /// Root-written, world-readable like route-state.json: the app reads it
    /// as the user to know whether the block is on, with no sudo.
    public static var statePath: String {
        (Path.stateDir as NSString).appendingPathComponent("killswitch.json")
    }
    static var rulesPath: String {
        (Path.stateDir as NSString).appendingPathComponent("killswitch.conf")
    }

    /// The live block. Exists exactly while the anchor is loaded by Menfez.
    public struct State: Codable, Sendable, Equatable {
        /// `discord` or `all`: what the rules were built for.
        public var scope: String
        public var iface: String
        public var endpoints: [String]
        /// From `pfctl -E`; released with `pfctl -X`. Nil when pf gave none.
        public var token: String?

        public init(scope: String, iface: String, endpoints: [String], token: String? = nil) {
            self.scope = scope
            self.iface = iface
            self.endpoints = endpoints
            self.token = token
        }
    }

    /// The local network: printers, AirPlay, the router's own page. Not the
    /// internet, so not a leak; blocking it would surprise more than protect.
    static let localV4 = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
                          "169.254.0.0/16", "224.0.0.0/4", "255.255.255.255"]
    static let localV6 = ["fe80::/10", "ff00::/8"]

    /// pf rules for the anchor, or nil when any input is not what it claims to
    /// be (the text goes to pfctl as root).
    public static func rules(scope: Mode, iface: String, endpoints: [String],
                             sites: [String] = []) -> String? {
        guard isTunnelInterface(iface) else { return nil }
        let header = "# Menfez kill switch (\(scope.rawValue)). Remove: sudo \(terminalOff)\n"
        switch scope {
        case .discord:
            let nets = RouteManager.discordRanges + sites
            guard nets.allSatisfy({ Validate.network($0) != nil }) else { return nil }
            let v4 = nets.filter { !$0.contains(":") }, v6 = nets.filter { $0.contains(":") }
            var text = header + "block drop out quick on ! \(iface) inet to { \(v4.joined(separator: ", ")) }\n"
            if !v6.isEmpty {
                text += "block drop out quick on ! \(iface) inet6 to { \(v6.joined(separator: ", ")) }\n"
            }
            return text
        case .all:
            let ips = endpoints.compactMap(Validate.ipAddress)
            guard !ips.isEmpty, ips.count == endpoints.count else { return nil }
            var lines = [
                "pass out quick on lo0 all",
                "pass out quick on \(iface) all",
            ]
            for ip in ips {
                lines.append("pass out quick \(ip.contains(":") ? "inet6" : "inet") to \(ip)")
            }
            lines += [
                "pass out quick inet proto udp from any port 68 to any port 67",
                // Before the local network: a resolver on the LAN is the ISP's.
                "block drop out quick proto { tcp udp } to any port 53",
                "pass out quick inet to { \(localV4.joined(separator: ", ")) }",
                "pass out quick inet6 to { \(localV6.joined(separator: ", ")) }",
                "block drop out quick all",
            ]
            return header + lines.joined(separator: "\n") + "\n"
        case .off, .updates:
            return nil
        }
    }

    static func isTunnelInterface(_ name: String) -> Bool {
        name.range(of: #"^utun[0-9]{1,3}$"#, options: .regularExpression) != nil
    }

    /// `pfctl -E` prints "Token : 1234567890".
    static func token(enableOutput text: String) -> String? {
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces) == "Token" else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if !value.isEmpty, value.allSatisfy(\.isNumber) { return value }
        }
        return nil
    }

    /// The main ruleset evaluates `com.apple/*`, so our child anchor is live.
    /// Without it the rules would load and silently do nothing.
    static func mainRulesetReachesAnchor(_ text: String) -> Bool {
        text.split(separator: "\n").contains {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("anchor \"com.apple/*\"")
        }
    }

    // MARK: - State file

    public static func load(path: String = statePath) -> State? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    static func save(_ state: State) -> Bool {
        StateFile.write(JSON.encode(state), to: statePath)
    }

    // MARK: - Root side (the helper)

    /// Build the rules for the tunnel that is up now and load them. Idempotent:
    /// a second call rebuilds them for a new interface, endpoint or scope.
    /// Any failure leaves the anchor as it was before the call.
    public static func on(using runner: CommandRunner = SystemRunner()) -> ActionResult {
        let route = RouteStateStore.load()
        guard let scope = Mode(rawValue: route.mode), scope == .discord || scope == .all else {
            return .failure("the kill switch needs the tunnel on, in Discord or Whole internet scope")
        }
        guard let iface = RouteManager.interfaceList(using: runner)?.first, iface == route.iface else {
            return .failure("no Menfez tunnel is up")
        }
        guard let endpoint = RouteManager.endpoint(iface: iface, using: runner) else {
            return .failure("the tunnel reports no endpoint")
        }
        guard let text = rules(scope: scope, iface: iface, endpoints: [endpoint],
                               sites: route.sites ?? []) else {
            return .failure("could not build the kill switch rules")
        }
        let previous = load()
        guard StateFile.write(text, to: rulesPath, mode: 0o600) else {
            return .failure("could not write the kill switch rules")
        }
        let loaded = runner.run("pfctl", ["-a", anchor, "-f", rulesPath], timeout: 15)
        guard loaded.ok else {
            if previous == nil { flush(using: runner) }
            return .failure("pfctl refused the rules: \(loaded.tail(2))")
        }
        let main = runner.run("pfctl", ["-s", "rules"], timeout: 15)
        guard main.ok, mainRulesetReachesAnchor(main.output) else {
            off(using: runner)
            return .failure("pf's main ruleset does not include Apple's anchor; nothing was blocked")
        }
        var token = previous?.token
        if previous == nil {
            let enabled = runner.run("pfctl", ["-E"], timeout: 15)
            guard enabled.ok else {
                flush(using: runner)
                return .failure("could not enable pf: \(enabled.tail(2))")
            }
            token = self.token(enableOutput: enabled.output)
        }
        let state = State(scope: scope.rawValue, iface: iface, endpoints: [endpoint], token: token)
        guard save(state) else {
            off(using: runner, token: token)
            return .failure("could not record the kill switch; it was removed")
        }
        return ActionResult(ok: true, mode: route.mode, iface: iface,
                            notes: ["kill switch on (\(scope.rawValue))"])
    }

    /// Remove the block. Always flushes the anchor, with or without a record,
    /// so it also clears what a crashed or older run left.
    @discardableResult
    public static func off(using runner: CommandRunner = SystemRunner(),
                           token: String? = nil) -> ActionResult {
        let release = token ?? load()?.token
        let flushed = flush(using: runner)
        if let release {
            _ = runner.run("pfctl", ["-X", release], timeout: 15)
        }
        unlink(statePath)
        unlink(rulesPath)
        return flushed
            ? ActionResult(ok: true, notes: ["kill switch off"])
            : .failure("could not flush the pf anchor \(anchor)")
    }

    /// After `up`, `mode`, `switch` and `repin`: follow the new interface,
    /// endpoint or scope. Nothing to do when the block is off. A rebuild that
    /// fails keeps the old rules: blocking too much beats leaking.
    public static func refreshIfOn(using runner: CommandRunner = SystemRunner()) -> String? {
        guard load() != nil else { return nil }
        let result = on(using: runner)
        return result.ok ? nil : "kill switch kept its previous rules: \(result.error ?? "")"
    }

    @discardableResult
    static func flush(using runner: CommandRunner) -> Bool {
        runner.run("pfctl", ["-a", anchor, "-F", "all"], timeout: 15).ok
    }
}
