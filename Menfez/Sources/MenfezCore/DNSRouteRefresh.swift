// DNSRouteRefresh.swift — keep Discord mode's resolver /32s in step with the
// network.
//
// `--dns-routes` is computed once, when the mode starts. After a Wi-Fi switch
// or a DHCP change the Mac asks other resolvers, which then go out the
// physical link (and to the ISP's DNS filter). The app feeds the public
// resolvers it sees on each check; this decides when the helper must be asked
// again. Pure state, so the tests drive it without a network.

import Foundation

public struct DNSRouteRefresh: Equatable, Sendable {
    /// The set the helper has now, as far as we know; nil until the first check.
    public private(set) var applied: [String]?
    private var pending: [String]?

    public init() {}

    /// Forget everything: tunnel down, another mode, toggle off, or the app
    /// just sent the helper a fresh set itself.
    public mutating func reset() {
        applied = nil
        pending = nil
    }

    /// Feed the public resolvers seen now. Returns the set to send, or nil.
    ///
    /// The first check after a reset is the baseline: the mode was started
    /// with that set. A different set must be seen on two checks in a row, so
    /// a list caught halfway through DHCP does not cost a root call. An empty
    /// set never replaces a real one: nothing would be routed, and the old
    /// /32s are harmless.
    public mutating func observe(_ current: [String]) -> [String]? {
        guard let applied else {
            self.applied = current
            return nil
        }
        guard !current.isEmpty, Set(current) != Set(applied) else {
            pending = nil
            return nil
        }
        if let pending, Set(pending) == Set(current) {
            self.applied = current
            self.pending = nil
            return current
        }
        pending = current
        return nil
    }

    /// True when the toggle is on but no resolver can go through the tunnel:
    /// every one is a LAN router, loopback or otherwise private address.
    public static func resolversStayOutside(enabled: Bool, resolvers: [String]) -> Bool {
        enabled && !resolvers.isEmpty && RouteManager.publicResolvers(resolvers).isEmpty
    }
}
