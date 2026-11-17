// DPIStatus.swift — what the engine can honestly say about itself.
//
// THE RULE HERE
// -------------
// Every field is something the engine observed or counted. Nothing is inferred
// from the fact that the engine is running. "Running" is not "working": the
// split may be unnecessary because the block lifted, or useless because the DPI
// changed its rule. `reframed > 0` proves the proxy did its job on some
// connection; it does not prove the network needed it. Only the probe in
// `DPIProbe.swift` can say that, and only for the moment it ran.

import Foundation

public struct DPIStatus: Codable, Equatable, Sendable {

    /// The listener is bound and accepting.
    public var running: Bool

    /// Port the loopback listener owns. nil before the first successful start.
    public var port: Int?

    /// Connections being served right now.
    public var connections: Int

    /// Connections where a split happened.
    public var reframed: Int

    /// Connections with no TLS record (plain HTTP inside a CONNECT, or a
    /// client that never sent anything recognisable).
    public var passthrough: Int

    /// CONNECT requests refused by the engine itself: bad method, bad target,
    /// oversized header, upstream dial failure, or the concurrency cap.
    public var rejected: Int

    /// Refusals caused only by the concurrency cap.
    ///
    /// Separate from `rejected` because it is the one refusal that is a
    /// capacity problem rather than a bad request, and the UI should say
    /// "the proxy is saturated" differently from "that request was invalid".
    public var overCapacity: Int

    /// Seconds since the engine started, nil when it never has.
    public var uptimeS: Int?

    /// The value in force. Shown in the UI so a retuned build is visible
    /// without a log.
    public var splitAt: Int

    /// Human-readable last refusal, for the status line. Never contains bytes
    /// from the client: see `DPIEngine.describe`.
    public var lastError: String?

    public init(running: Bool = false,
                port: Int? = nil,
                connections: Int = 0,
                reframed: Int = 0,
                passthrough: Int = 0,
                rejected: Int = 0,
                overCapacity: Int = 0,
                uptimeS: Int? = nil,
                splitAt: Int = TLSRecordReframer.firstRecordPayloadLimit,
                lastError: String? = nil) {
        self.running = running
        self.port = port
        self.connections = connections
        self.reframed = reframed
        self.passthrough = passthrough
        self.rejected = rejected
        self.overCapacity = overCapacity
        self.uptimeS = uptimeS
        self.splitAt = splitAt
        self.lastError = lastError
    }

    /// One line for the UI: port and counters, no adjectives.
    ///
    /// English by default because `DPIStatus` lives in the core, which has no
    /// strings. The app builds its own localised line in `Model.statusLine`; this
    /// one is for logs and for a future helper that has no localisation either.
    public var summary: String {
        guard running, let port else { return "DPI proxy not running" }
        var parts = ["127.0.0.1:\(port)",
                     "\(connections) open",
                     "\(reframed) split",
                     "\(passthrough) passthrough"]
        if rejected > 0 { parts.append("\(rejected) refused") }
        return parts.joined(separator: " · ")
    }

    /// The same figures, in the app's language.
    ///
    /// Kept here rather than in the view so the two lines cannot drift: every
    /// number comes from one place, and a counter added to `summary` is a
    /// compile-time prompt to add it here too.
    public func summary(open: String, split: String, passthrough: String,
                        refused: String, off: String) -> String {
        guard running, let port else { return off }
        var parts = ["127.0.0.1:\(port)",
                     "\(connections) \(open)",
                     "\(reframed) \(split)",
                     "\(self.passthrough) \(passthrough)"]
        if rejected > 0 { parts.append("\(rejected) \(refused)") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Mode conflict

/// Why DPI mode and the WireGuard tunnel cannot both be on.
///
/// Both shapes want to be the thing that carries the user's traffic. The tunnel
/// does it by taking routes; the DPI proxy does it by being the proxy the app
/// talks to. They are not literally exclusive — a tunnel carrying `all` plus a
/// proxy on loopback would still work — but the combination is a trap: the
/// proxy's own upstream dial would enter the tunnel, so every CONNECT would be
/// encrypted twice and the user would be debugging a bypass that is being
/// bypassed. Worse, with `discord` mode routes the proxy would exit through the
/// tunnel for Discord and directly for everything else, so the counters would
/// describe two different networks and the probe would be meaningless.
///
/// The choice made here: **refuse, do not silently stop the tunnel.** Stopping
/// someone's tunnel to switch a mode they only clicked on is a larger action
/// than they asked for, and a refused click is recoverable while a torn-down
/// tunnel that fails to come back is not. The refusal message names the tunnel
/// and the fix.
public enum DPIConflict {

    public static let tunnelIsUpMessage =
        "The WireGuard tunnel is up. DPI mode and the tunnel cannot run at the "
        + "same time — switch the tunnel off first."

    /// Whether the current machine state blocks starting the engine.
    ///
    /// `busy` is the accurate answer: the tunnel is carrying this app's traffic
    /// (routes installed and mode not off). Passed in rather than read here so
    /// a test can drive it without a real tunnel, and so the one caller that
    /// knows the difference decides.
    ///
    /// KEYING ON INTERFACE PRESENCE ALONE WAS A BUG
    /// `wg show interfaces` lists any WireGuard interface: another client's, or
    /// the husk `wg-quick` leaves after `down`. Refusing on that made the
    /// rootless path unusable on such a machine — the app told the user to
    /// switch off a tunnel they could not switch off (no sudo grant) and did
    /// not need to switch off (it carried no routes). This overload exists so
    /// the old signature keeps its old, conservative meaning for callers that
    /// only have the interface list.
    public static func refusal(busy: Bool) -> String? {
        busy ? tunnelIsUpMessage : nil
    }

    /// The interface-list form, kept for callers that have nothing better.
    ///
    /// Prefer `refusal(busy:)`: presence is not interception.
    public static func refusal(interfaces: [String]) -> String? {
        refusal(busy: !interfaces.isEmpty)
    }
}
