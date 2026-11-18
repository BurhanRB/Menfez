// ServerLatency.swift — how far each server is, measured with ping (feature 4).
//
// WireGuard's UDP port answers nothing to a stranger, so the only thing the
// user can measure without root and without bringing a tunnel up is ICMP to
// the endpoint host: `/sbin/ping -c 3 -t 3 <host>`, as the user. Some
// providers drop ICMP; that server shows "no reply" and ranks last (AS-11).
//
// Runs only when the user presses "Pick the fastest", never on the refresh
// tick. Hosts come from the profile's parsed `[Peer] Endpoint` (`Profile.host`);
// the private key is never read here.

import Foundation

public enum ServerLatency {

    /// One server's answer: average round trip in ms, or nothing came back.
    public enum Result: Equatable, Sendable {
        case ms(Int)
        case noReply

        public var ms: Int? {
            if case .ms(let value) = self { return value }
            return nil
        }
    }

    /// A measurement older than this is taken again.
    public static let cacheTTL: TimeInterval = 5 * 60
    /// At most this many pings run at once.
    public static let maxParallel = 4

    /// The average from macOS ping's summary line
    /// ("round-trip min/avg/max/stddev = 11.1/12.3/13.4/0.9 ms"; ping6 says
    /// "std-dev"), rounded, at least 1. Nil for 100% loss, an unknown host or
    /// anything else without that line. Partial loss still has the line.
    public static func parse(_ output: String) -> Int? {
        guard let line = output.split(separator: "\n").last(where: { $0.contains("min/avg/max") }),
              let eq = line.firstIndex(of: "=") else { return nil }
        let numbers = line[line.index(after: eq)...]
            .trimmingCharacters(in: .whitespaces)
            .split(separator: " ").first?
            .split(separator: "/") ?? []
        guard numbers.count >= 2, let avg = Double(numbers[1]), avg.isFinite, avg >= 0 else { return nil }
        return max(1, Int(avg.rounded()))
    }

    /// The host as ping may take it, or nil. The argument goes in an argv
    /// array, never a shell, but a leading "-" would still read as a flag.
    /// IPv6 brackets ("[2001:db8::1]") are removed.
    public static func safeHost(_ raw: String?) -> String? {
        guard var host = raw else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:")
        guard !host.isEmpty, host.count <= 253, !host.hasPrefix("-"),
              host.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return host
    }

    /// The command for one host: `ping6` for an IPv6 literal (macOS 13's
    /// `ping` has no IPv6), which has no `-t`, so the runner's timeout bounds it.
    public static func command(for host: String) -> (tool: String, args: [String]) {
        host.contains(":") ? ("/sbin/ping6", ["-c", "3", host])
                           : ("/sbin/ping", ["-c", "3", "-t", "3", host])
    }

    /// Ping every profile's host, `maxParallel` at a time. Keyed by profile
    /// name; a profile with no usable host is "no reply". Blocking: call off
    /// the main thread.
    public static func measure(_ hosts: [String: String?],
                               using runner: CommandRunner = SystemRunner()) -> [String: Result] {
        let box = Box()
        let gate = DispatchSemaphore(value: maxParallel)
        let group = DispatchGroup()
        for (name, raw) in hosts {
            guard let host = safeHost(raw) else {
                box.set(name, .noReply)
                continue
            }
            gate.wait()
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let cmd = command(for: host)
                let out = runner.run(cmd.tool, cmd.args, timeout: 5)
                box.set(name, parse(out.output).map { .ms($0) } ?? .noReply)
                gate.signal()
                group.leave()
            }
        }
        group.wait()
        return box.results
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String: Result] = [:]
        func set(_ name: String, _ value: Result) { lock.lock(); stored[name] = value; lock.unlock() }
        var results: [String: Result] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    /// Names fastest first; "no reply" and unmeasured last, each group in the
    /// order given (stable), so equal servers keep the list's order.
    public static func rank(_ names: [String], _ results: [String: Result]) -> [String] {
        let indexed = names.enumerated().map { ($0.offset, $0.element, results[$0.element]?.ms) }
        return indexed.sorted { a, b in
            switch (a.2, b.2) {
            case let (x?, y?): return x != y ? x < y : a.0 < b.0
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.0 < b.0
            }
        }.map(\.1)
    }

    /// The fastest server that answered, or nil when none did (AS-11: a
    /// silent server is never picked by this button).
    public static func fastest(_ names: [String], _ results: [String: Result]) -> String? {
        rank(names, results).first { results[$0]?.ms != nil }
    }
}

/// The last measurement, kept `ServerLatency.cacheTTL`.
public struct LatencyCache: Equatable, Sendable {
    public private(set) var results: [String: ServerLatency.Result] = [:]
    public private(set) var measuredAt: Date?

    public init() {}

    public func isFresh(now: Date = Date()) -> Bool {
        guard let measuredAt else { return false }
        return now.timeIntervalSince(measuredAt) < ServerLatency.cacheTTL
    }

    /// Results still worth showing (empty once stale).
    public func current(now: Date = Date()) -> [String: ServerLatency.Result] {
        isFresh(now: now) ? results : [:]
    }

    public mutating func store(_ new: [String: ServerLatency.Result], at now: Date = Date()) {
        results = new
        measuredAt = now
    }
}
