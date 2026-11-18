// TunnelScope.swift — what Tunnel mode carries: Discord only, or the whole internet.
//
// The route sets themselves are `Mode.discord` and `Mode.all` in RouteManager.
// This file holds the stored choice and the one extra thing Whole internet
// needs: the system resolver moved onto the tunnel. Without it, lookups go to
// the router (a LAN address, more specific than the /1 halves) and from there
// to the ISP in clear, while the traffic itself leaves through the server.

import Foundation

public enum TunnelScope {

    public static let defaultsKey = "tunnelScope"

    /// The saved choice; Discord only when unset or unknown.
    public static func current(_ defaults: UserDefaults = .standard) -> Mode {
        defaults.string(forKey: defaultsKey) == Mode.all.rawValue ? .all : .discord
    }

    public static func save(_ scope: Mode, _ defaults: UserDefaults = .standard) {
        defaults.set(scope == .all ? Mode.all.rawValue : Mode.discord.rawValue, forKey: defaultsKey)
    }

    /// True when a scope change must re-route the live tunnel (`mode <scope>`):
    /// Tunnel mode is on, it carries one of the two scopes, and not this one.
    public static func needsReroute(inTunnel: Bool, routeMode: String, to scope: Mode) -> Bool {
        inTunnel && routeMode != scope.rawValue
            && (routeMode == Mode.discord.rawValue || routeMode == Mode.all.rawValue)
    }

    /// Whole internet's resolvers: the profile's own `DNS =` line when it has
    /// one (the server's resolver), else the public resolver picked in the DNS
    /// sheet. Both are reached through the tunnel, never the ISP.
    public static func tunnelDNS(profileDNS: [String]?, fallback: [String]) -> [String] {
        let own = (profileDNS ?? []).compactMap { Validate.ipAddress($0) }
        return Array((own.isEmpty ? fallback : own).prefix(maxDNS))
    }

    public static let maxDNS = 4

    /// `--tunnel-dns`: 1 to 4 IP addresses, comma-separated. Private addresses
    /// are allowed (a server's resolver is often 10.x inside the tunnel). Nil
    /// for anything else, since this value crosses into root.
    public static func dnsArgument(_ raw: String) -> [String]? {
        let parts = raw.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard (1...maxDNS).contains(parts.count) else { return nil }
        let ips = parts.compactMap { Validate.ipAddress($0) }
        return ips.count == parts.count ? ips : nil
    }

    public enum DNSStep: Equatable, Sendable {
        case takeOver([String])
        case release
        case none
    }

    /// What the helper does with the resolver after a route command.
    /// Whole internet with resolvers holds it; any other mode lets go. After a
    /// failure the mode the state file settled on decides: a failed switch can
    /// leave the tunnel down, and a resolver inside it would then answer nothing.
    public static func dnsStep(ok: Bool, mode: String?, stateMode: String,
                               servers: [String]) -> DNSStep {
        if ok, mode == Mode.all.rawValue { return servers.isEmpty ? .none : .takeOver(servers) }
        let settled = ok ? (mode ?? stateMode) : stateMode
        return settled == Mode.all.rawValue ? .none : .release
    }
}
