// CardIdentity.swift — which address the card's IP / location / ISP rows describe.
//
// In tunnel mode the user wants to see the server they are going through. In
// Discord-only scope ordinary traffic does not use the tunnel, so the egress
// lookup (ipify -> ipinfo) still reports the local ISP. The rows therefore take
// the tunnel server's own address and its ipinfo answer in tunnel mode, in both
// scopes, and the egress values everywhere else.

import Foundation

public struct CardIdentity: Equatable, Sendable {
    public var ip: String?
    public var geo: Geo?
    /// True when the values describe the tunnel server, not this machine's exit.
    public var fromServer: Bool

    public init(ip: String?, geo: Geo?, fromServer: Bool) {
        self.ip = ip
        self.geo = geo
        self.fromServer = fromServer
    }

    /// - Parameters:
    ///   - serverIP: the active profile's endpoint address, nil when unknown.
    ///   - serverGeo: its ipinfo answer, nil while the lookup is pending.
    public static func choose(runMode: RunMode,
                              egressIP: String?, egressGeo: Geo?,
                              serverIP: String?, serverGeo: Geo?) -> CardIdentity {
        if runMode == .tunnel, let serverIP {
            return CardIdentity(ip: serverIP, geo: serverGeo, fromServer: true)
        }
        return CardIdentity(ip: egressIP, geo: egressGeo, fromServer: false)
    }

    /// The server address to look up: the live endpoint (wg reports it
    /// resolved) first, then the active profile's Endpoint host. Nil when
    /// neither is known. A name is returned as-is; the caller resolves it.
    public static func serverHost(liveEndpointHost: String?, profileHost: String?) -> String? {
        if let live = liveEndpointHost, Validate.ipAddress(live) != nil { return live }
        return profileHost ?? liveEndpointHost
    }
}
