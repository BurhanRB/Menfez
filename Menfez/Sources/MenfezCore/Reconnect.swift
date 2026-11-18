// Reconnect.swift — when and how to bring a dropped tunnel back (feature 4).
//
// Pure: the app feeds it one observation per tick and runs whatever step it
// returns with the helper's existing commands (`repin`, `switch`). Nothing
// here spawns a process or touches the kill switch; the block stays on while
// this works (the helper's `switch` re-installs it, `repin` keeps it).
//
// Order: re-pin the endpoint, then restart the same server (`switch` to
// itself is a full down + up), then — only with "Switch server if needed" —
// the next server by the last latency ranking. Waits 5 s, 15 s, 60 s, then
// 5 min between attempts, never while the network is down, and gives up
// after `maxAttempts` (AS-12).

import Foundation

public struct Reconnect: Equatable, Sendable {

    /// "Reconnect automatically", default on (AS-10).
    public static let autoKey = "reconnect.auto"
    /// "Switch server if needed", default off: it changes the exit country (AS-10).
    public static let switchKey = "reconnect.switchServer"

    public static func isAuto(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: autoKey) as? Bool ?? true
    }

    public static func allowsSwitch(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: switchKey)
    }

    /// Wait before attempt n+1 (index n); after the list, `laterDelay`.
    public static let delays: [TimeInterval] = [5, 15, 60]
    public static let laterDelay: TimeInterval = 5 * 60
    /// Attempts before giving up: about 16 minutes in all (AS-12).
    public static let maxAttempts = 6

    public static func delay(before index: Int) -> TimeInterval {
        index < delays.count ? delays[index] : laterDelay
    }

    public enum Step: Equatable, Sendable {
        /// Move the endpoint pin to the current gateway.
        case repin
        /// Take the same server down and up (`switch <same>`).
        case restart(String)
        /// Go to another server (`switch <other>`); only with the setting on.
        case switchTo(String)
    }

    public enum Decision: Equatable, Sendable {
        case none
        case attempt(Step)
        /// Healthy again after at least one attempt.
        case recovered
        /// `maxAttempts` used up; nothing more until the tunnel is healthy
        /// again or the user acts.
        case gaveUp
    }

    /// One tick's view of the world.
    public struct Input: Equatable, Sendable {
        /// Setting on and Tunnel is the user's mode. False stops the machine.
        public var active: Bool
        /// `TunnelLoss.isLost` (gone, down, or handshake older than 180 s).
        public var lost: Bool
        /// The report says the tunnel is measured healthy.
        public var healthy: Bool
        /// The physical path is up (`NWPathMonitor` `.satisfied`).
        public var pathSatisfied: Bool
        /// The server the tunnel should run.
        public var current: String?
        /// All servers, fastest first (or in list order when unmeasured).
        public var ranked: [String]
        /// "Switch server if needed".
        public var allowSwitch: Bool

        public init(active: Bool, lost: Bool, healthy: Bool, pathSatisfied: Bool,
                    current: String?, ranked: [String], allowSwitch: Bool) {
            self.active = active
            self.lost = lost
            self.healthy = healthy
            self.pathSatisfied = pathSatisfied
            self.current = current
            self.ranked = ranked
            self.allowSwitch = allowSwitch
        }
    }

    public private(set) var attempts = 0
    public private(set) var nextAt: Date?
    public private(set) var gaveUp = false

    public init() {}

    /// The user changed mode, stopped the tunnel or pressed Reconnect.
    public mutating func reset() { self = Reconnect() }

    public mutating func observe(_ input: Input, now: Date = Date()) -> Decision {
        guard input.active else {
            reset()
            return .none
        }
        if !input.lost {
            // Not lost but not measured healthy either (settling after our own
            // attempt, no handshake yet): keep the count and wait.
            guard input.healthy else { return .none }
            let recovered = attempts > 0 && !gaveUp
            reset()
            return recovered ? .recovered : .none
        }
        if gaveUp { return .none }
        guard input.pathSatisfied else { return .none }
        guard let due = nextAt else {
            nextAt = now.addingTimeInterval(Self.delay(before: 0))
            return .none
        }
        guard now >= due else { return .none }
        guard attempts < Self.maxAttempts else {
            gaveUp = true
            nextAt = nil
            return .gaveUp
        }
        let step = Self.step(index: attempts, current: input.current,
                             ranked: input.ranked, allowSwitch: input.allowSwitch)
        attempts += 1
        nextAt = now.addingTimeInterval(Self.delay(before: attempts))
        return .attempt(step)
    }

    /// Attempt `index` (0-based): repin, then the same server, then the next
    /// one when allowed, cycling through the others by speed. A single-server
    /// user, or the setting off, keeps restarting the same server.
    public static func step(index: Int, current: String?, ranked: [String],
                            allowSwitch: Bool) -> Step {
        guard index > 0 else { return .repin }
        if index >= 2, allowSwitch {
            let others = ranked.filter { $0 != current }
            if !others.isEmpty { return .switchTo(others[(index - 2) % others.count]) }
        }
        return current.map { .restart($0) } ?? .repin
    }
}
