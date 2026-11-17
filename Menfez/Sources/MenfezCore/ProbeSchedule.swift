// ProbeSchedule.swift — when the egress/geo/Discord probes may run, and
// whether a result that just landed still describes the current path.
//
// The probes cost three HTTPS requests and up to ~20 s, so they do not run
// on the tick. They run at launch, after every mode or server change once it
// has settled, on the Refresh button, and on window activation only when the
// last result is older than `ttl`.

import Foundation

public struct ProbeSchedule: Equatable, Sendable {
    public let ttl: TimeInterval
    /// Bumped on every mode or server change; a result from an older
    /// generation measured a path that no longer exists.
    public private(set) var generation = 0
    /// When the last current-generation result landed.
    public private(set) var landedAt: Date?
    /// The generation of the probe that is running, if any.
    public private(set) var inFlight: Int?
    /// A probe is owed (a change happened, or one was asked for while
    /// settling) and should start as soon as nothing is settling.
    public private(set) var pending = false

    public init(ttl: TimeInterval = 60) {
        self.ttl = ttl
    }

    /// A mode or server change began: old results are void, a probe is owed.
    public mutating func invalidate() {
        generation += 1
        landedAt = nil
        pending = true
    }

    /// The token for a probe to start now, or nil when it must not.
    ///
    /// - settling: a switch is running or its routes are still appearing; a
    ///   probe now would measure a half-applied path, so it is deferred.
    /// - force: a user action (Refresh); ignores the TTL, not the settling.
    public mutating func start(now: Date, settling: Bool, force: Bool = false) -> Int? {
        if settling {
            pending = true
            return nil
        }
        if inFlight == generation { return nil }
        if !force, !pending, let landedAt, now.timeIntervalSince(landedAt) < ttl {
            return nil
        }
        inFlight = generation
        pending = false
        return generation
    }

    /// A probe finished. True when its result may be published.
    public mutating func land(_ token: Int, now: Date) -> Bool {
        if inFlight == token { inFlight = nil }
        guard token == generation else { return false }
        landedAt = now
        return true
    }
}
