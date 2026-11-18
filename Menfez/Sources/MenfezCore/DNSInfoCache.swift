// DNSInfoCache.swift — the active network service and its resolvers, kept
// between ticks.
//
// Two `networksetup` processes per 2 s tick read values that change only when
// the network changes or someone sets DNS. The cache is keyed by the primary
// interface (read every tick anyway), dropped by the app on a network change,
// a mode switch or a DNS action, and expires after `ttl` so a change made in
// System Settings still shows up. The interface's own address rides along
// (one `ipconfig` per tick saved): it changes with the network too.

import Foundation

public final class DNSInfoCache: @unchecked Sendable {
    public struct Info: Equatable, Sendable {
        public var service: String?
        public var servers: [String]
        public var localIP: String?

        public init(service: String?, servers: [String], localIP: String? = nil) {
            self.service = service
            self.servers = servers
            self.localIP = localIP
        }
    }

    public let ttl: TimeInterval
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var entry: (interface: String?, info: Info, at: Date)?

    public init(ttl: TimeInterval = 30, now: @escaping @Sendable () -> Date = { Date() }) {
        self.ttl = ttl
        self.now = now
    }

    /// The cached info for this primary interface, or nil when it must be read.
    public func lookup(interface: String?) -> Info? {
        lock.lock(); defer { lock.unlock() }
        guard let entry, entry.interface == interface,
              now().timeIntervalSince(entry.at) < ttl else { return nil }
        return entry.info
    }

    public func store(_ info: Info, interface: String?) {
        lock.lock(); defer { lock.unlock() }
        entry = (interface, info, now())
    }

    /// Forget the entry: the next tick reads `networksetup` again.
    public func invalidate() {
        lock.lock(); defer { lock.unlock() }
        entry = nil
    }
}
