// LeakTest.swift — "is everything really going through the tunnel?"
//
// Four rows: the address the world sees, where DNS goes, IPv6, and the kill
// switch. Everything is read as the user: the route table (`route -n get`),
// `scutil --dns`, the interface list, and one ipify request the app already
// makes for the card. No DNS-leak service, no new third party.
//
// `gather` reads; `classify` decides and is what the tests pin down.

import Foundation

public enum LeakTest {

    public enum Level: String, Sendable { case ok, warn, bad }
    public enum Row: String, CaseIterable, Sendable { case ip, dns, ipv6, killSwitch }

    /// One row: a colour, a localisation key (`leak_<key>`), and an optional
    /// value shown after it (an address).
    public struct Line: Equatable, Sendable {
        public var row: Row
        public var level: Level
        public var key: String
        public var detail: String?

        public init(_ row: Row, _ level: Level, _ key: String, _ detail: String? = nil) {
            self.row = row
            self.level = level
            self.key = key
            self.detail = detail
        }
    }

    public struct Input: Sendable {
        /// `discord` or `all` while our tunnel carries traffic; nil otherwise.
        public var scope: Mode?
        public var tunnelIface: String?
        public var egressIP: String?
        public var endpoint: String?
        /// Interface the scope's probe address leaves through: 1.1.1.1 for
        /// Whole internet, a Discord address for Discord only.
        public var probeRouteIface: String?
        /// Each system resolver and the interface it leaves through (nil when
        /// `route get` said nothing).
        public var resolvers: [(ip: String, iface: String?)]
        public var hasPublicIPv6: Bool
        /// Where a public IPv6 address goes: an interface, or "blocked" for a
        /// reject/blackhole route, or nil for no route at all.
        public var ipv6Route: String?
        /// Nil when the helper is too old to have one.
        public var killSwitch: Bool?

        public init(scope: Mode? = nil, tunnelIface: String? = nil, egressIP: String? = nil,
                    endpoint: String? = nil, probeRouteIface: String? = nil,
                    resolvers: [(ip: String, iface: String?)] = [], hasPublicIPv6: Bool = false,
                    ipv6Route: String? = nil, killSwitch: Bool? = nil) {
            self.scope = scope
            self.tunnelIface = tunnelIface
            self.egressIP = egressIP
            self.endpoint = endpoint
            self.probeRouteIface = probeRouteIface
            self.resolvers = resolvers
            self.hasPublicIPv6 = hasPublicIPv6
            self.ipv6Route = ipv6Route
            self.killSwitch = killSwitch
        }
    }

    /// The address each scope is checked against: one Discord voice/API
    /// address inside `discordRanges`, or a plain public one.
    static func probeAddress(_ scope: Mode) -> String {
        scope == .discord ? RouteManager.kickTarget : "1.1.1.1"
    }
    static let ipv6Probe = "2001:4860:4860::8888"

    public static func classify(_ input: Input) -> [Line] {
        guard let scope = input.scope, scope == .discord || scope == .all,
              let tunnel = input.tunnelIface else {
            return [Line(.ip, .warn, "off")]
        }
        let all = scope == .all
        let viaTunnel = input.probeRouteIface == tunnel
        var lines: [Line] = []

        // IP
        if !viaTunnel {
            lines.append(Line(.ip, .bad, all ? "ip_leak" : "ip_discord_leak", input.egressIP))
        } else if !all {
            lines.append(Line(.ip, .ok, "ip_discord"))
        } else if let egress = input.egressIP {
            lines.append(egress == input.endpoint
                         ? Line(.ip, .ok, "ip_server", egress)
                         : Line(.ip, .ok, "ip_exit", egress))
        } else {
            lines.append(Line(.ip, .ok, "ip_tunnel"))
        }

        // DNS
        let local = input.resolvers.filter { isLoopback($0.ip) }
        let outside = input.resolvers.filter { !isLoopback($0.ip) && $0.iface != tunnel }
        if input.resolvers.isEmpty {
            lines.append(Line(.dns, .warn, "dns_unknown"))
        } else if !outside.isEmpty {
            lines.append(Line(.dns, all ? .bad : .warn, all ? "dns_leak" : "dns_discord",
                              outside.map(\.ip).joined(separator: ", ")))
        } else if !local.isEmpty {
            lines.append(Line(.dns, .warn, "dns_local"))
        } else {
            lines.append(Line(.dns, .ok, "dns_tunnel"))
        }

        // IPv6
        if !input.hasPublicIPv6 {
            lines.append(Line(.ipv6, .ok, "v6_none"))
        } else if input.ipv6Route == tunnel {
            lines.append(Line(.ipv6, .ok, "v6_tunnel"))
        } else if input.ipv6Route == nil || input.ipv6Route == "blocked" {
            lines.append(Line(.ipv6, .ok, "v6_blocked"))
        } else {
            lines.append(Line(.ipv6, all ? .bad : .warn, all ? "v6_leak" : "v6_discord"))
        }

        // Kill switch
        switch input.killSwitch {
        case .some(true): lines.append(Line(.killSwitch, .ok, "ks_on"))
        case .some(false): lines.append(Line(.killSwitch, .warn, "ks_off"))
        case .none: lines.append(Line(.killSwitch, .warn, "ks_unknown"))
        }
        return lines
    }

    static func isLoopback(_ ip: String) -> Bool {
        ip.hasPrefix("127.") || ip == "::1"
    }

    /// A global IPv6 address: not loopback, link-local (fe80::/10) or
    /// unique-local (fc00::/7). Those never reach the internet.
    static func isGlobalIPv6(_ ip: String) -> Bool {
        guard Validate.ipAddress(ip) != nil, ip.contains(":"), ip != "::1" else { return false }
        let head = ip.lowercased()
        return !(head.hasPrefix("fe8") || head.hasPrefix("fe9") || head.hasPrefix("fea")
                 || head.hasPrefix("feb") || head.hasPrefix("fc") || head.hasPrefix("fd"))
    }

    /// "blocked" for a reject or blackhole route, else its interface.
    static func routeTarget(_ values: [String: String]) -> String? {
        let flags = values["flags"] ?? ""
        if flags.contains("REJECT") || flags.contains("BLACKHOLE") || values["interface"] == "lo0" {
            return "blocked"
        }
        return values["interface"]
    }

    // MARK: - Reads (as the user)

    /// Slow: one HTTPS request and a handful of `route get`. Off the main thread.
    public static func gather(scope: Mode?, tunnelIface: String?, endpoint: String?,
                              killSwitch: Bool?,
                              using runner: CommandRunner = SystemRunner()) -> Input {
        var input = Input(scope: scope, tunnelIface: tunnelIface, endpoint: endpoint,
                          killSwitch: killSwitch)
        guard let scope, tunnelIface != nil else { return input }
        input.egressIP = Probes.publicIP(using: runner)
        input.probeRouteIface = RouteManager.routeGetValues([probeAddress(scope)], using: runner)["interface"]
        input.resolvers = DNSManager.systemResolvers(using: runner).map { ip in
            let query = ip.contains(":") ? ["-inet6", ip] : [ip]
            return (ip, RouteManager.routeGetValues(query, using: runner)["interface"])
        }
        input.hasPublicIPv6 = localAddresses().contains(where: isGlobalIPv6)
        if input.hasPublicIPv6 {
            input.ipv6Route = routeTarget(RouteManager.routeGetValues(["-inet6", ipv6Probe], using: runner))
        }
        return input
    }

    /// IPv6 addresses on non-tunnel interfaces.
    static func localAddresses() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var found: [String] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET6),
                  !String(cString: entry.pointee.ifa_name).hasPrefix("utun") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                found.append(String(cString: host))
            }
        }
        return found
    }
}
