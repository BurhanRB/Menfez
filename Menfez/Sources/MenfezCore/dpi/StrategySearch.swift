// StrategySearch.swift — "Find a setting" (1.0.8, feature 8).
//
// The engine has one knob, the first record's payload length
// (`dpi.firstRecordPayloadLimit`, docs/DPI-ENGINE.md §2). When the probe says
// DPI is not enough on this network, this tries a short fixed list of other
// lengths, one at a time, each through a throwaway engine on its own loopback
// port (the running proxy is never touched), against the same host the probe
// uses. The first that gets through is kept for this network.
//
// Sequential and capped (6 s each, 60 s in all): many failed handshakes in a
// row can get an address flagged on some networks, and parallel attempts
// would make the result impossible to attribute.

import Foundation

public enum StrategySearch {

    /// The lengths tried, in order. 40 is today's default.
    public static let values = [1, 2, 5, 40, 100]
    public static let perCandidate: TimeInterval = 6
    public static let total: TimeInterval = 60

    /// What to try on a network whose current length failed: the list
    /// without that length.
    public static func candidates(current: Int) -> [Int] {
        values.filter { $0 != current }
    }

    public enum Outcome: Equatable, Sendable {
        /// This length got through; saved for the network.
        case found(Int)
        /// The direct attempt worked: this network does not block.
        case notNeeded
        /// The name did not resolve; no length can fix that.
        case dnsBlocked
        /// Nothing worked (or the time ran out): try the tunnel.
        case noneWorked
    }

    /// Run the search. `direct` is one attempt without the proxy, `attempt`
    /// one through an engine cutting at the given length; `progress` gets
    /// (1-based index, count) before each candidate. Stops at the first
    /// success, at a DNS failure, or when `total` has passed.
    public static func run(current: Int,
                           direct: () -> DPIProbeOutcome.Attempt,
                           attempt: (Int) -> DPIProbeOutcome.Attempt,
                           progress: (Int, Int) -> Void = { _, _ in },
                           now: () -> Date = Date.init) -> Outcome {
        let start = now()
        let first = direct()
        if first.ok { return .notNeeded }
        if first.dnsFailed { return .dnsBlocked }
        let list = candidates(current: current)
        for (index, value) in list.enumerated() {
            // Leave room for a whole attempt inside the cap.
            guard now().timeIntervalSince(start) + perCandidate <= total else { break }
            progress(index + 1, list.count)
            let result = attempt(value)
            if result.ok { return .found(value) }
            if result.dnsFailed { return .dnsBlocked }
        }
        return .noneWorked
    }
}

/// Where a found length is kept: per network (feature 5's id), or the
/// global `dpi.firstRecordPayloadLimit` when the network cannot be told apart.
public struct DPITuning {
    public static let key = "dpi.splitByNetwork"
    /// Old entries go first beyond this; a dictionary of small ints.
    public static let maxNetworks = 64

    let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private var table: [String: Int] {
        (defaults.dictionary(forKey: Self.key) as? [String: Int]) ?? [:]
    }

    /// The length saved for this network, nil when none (or out of range).
    public func value(for network: String?) -> Int? {
        guard let network, let value = table[network], DPIEngine.splitRange.contains(value) else { return nil }
        return value
    }

    public func save(_ value: Int, for network: String?) {
        guard DPIEngine.splitRange.contains(value) else { return }
        guard let network else {
            defaults.set(value, forKey: DPIEngine.splitDefaultsKey)
            return
        }
        var t = table
        t[network] = value
        if t.count > Self.maxNetworks {
            // shortcut: no timestamps, so an arbitrary other entry goes; fine at 64 networks.
            if let drop = t.keys.first(where: { $0 != network }) { t[drop] = nil }
        }
        defaults.set(t, forKey: Self.key)
    }

    public func forget(_ network: String) {
        var t = table
        t[network] = nil
        defaults.set(t, forKey: Self.key)
    }

    /// The global length (`defaults write`, or saved on an unknown network).
    public var global: Int {
        let v = defaults.integer(forKey: DPIEngine.splitDefaultsKey)
        return DPIEngine.splitRange.contains(v) ? v : TLSRecordReframer.firstRecordPayloadLimit
    }

    /// What the engine should cut at on this network.
    public func effective(for network: String?) -> Int {
        value(for: network) ?? global
    }
}
