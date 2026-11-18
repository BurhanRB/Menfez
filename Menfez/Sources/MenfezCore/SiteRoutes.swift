// SiteRoutes.swift — "Discord + chosen sites": which addresses go through the
// tunnel besides Discord's ranges.
//
// The user's list holds site names (and, rarely, an address). The helper never
// sees a name: the app resolves each one with DoH (the encrypted resolver the
// DPI proxy uses, so the ISP's DNS filter cannot answer for it) and sends only
// public IPv4 /32s and IPv6 /128s with `--site-routes`. The helper checks them
// again (`RouteManager.siteRoutes(argument:)`), since that value crosses into
// root.
//
// CDN sites change addresses. The app re-resolves every minute (the DoH cache
// keeps the answer for its TTL, at most 5 minutes) and on a network change; a
// new set is sent only after two checks in a row agree (`Refresh`), and the
// previous set rides along once so open connections are not cut (AS-4).

import Foundation

public enum SiteRoutes {

    /// Most names in the list (AS-3).
    public static let maxSites = 32

    /// Most addresses one `--site-routes` may carry (AS-3). A CDN name answers
    /// with 2 to 8 addresses per family; 32 names with `www.` fit with room for
    /// the previous set.
    public static let maxRoutes = 256

    // MARK: - The user's entries

    /// The entry as stored ("example.com", "1.2.3.4"), or nil when it is
    /// neither a site name nor a public address. Accepts what people paste:
    /// a URL, upper case, a trailing dot.
    public static func normalize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for scheme in ["https://", "http://"] where text.hasPrefix(scheme) {
            text.removeFirst(scheme.count)
        }
        if let cut = text.firstIndex(where: { "/?#".contains($0) }) { text = String(text[..<cut]) }
        while text.hasSuffix(".") { text.removeLast() }
        if let ip = publicAddress(text) { return ip }
        return isHostname(text) ? text : nil
    }

    /// Letters, digits and hyphens in 1–63-byte labels, at least two labels,
    /// 253 bytes at most, and a top-level label that is not all digits (so a
    /// mistyped address is not taken for a name). Punycode (`xn--`) is fine.
    public static func isHostname(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf8.count <= 253 else { return false }
        let labels = text.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, let top = labels.last, !top.allSatisfy(\.isNumber) else { return false }
        return labels.allSatisfy { label in
            (1...63).contains(label.utf8.count)
                && label.first != "-" && label.last != "-"
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    /// The names to look up for one entry: the name itself and its `www.`
    /// twin, which is where most sites actually load. Nothing for an address.
    public static func lookupNames(_ entry: String) -> [String] {
        guard publicAddress(entry) == nil else { return [] }
        return entry.hasPrefix("www.") ? [entry] : [entry, "www." + entry]
    }

    // MARK: - Addresses

    /// `text` in canonical form when it is a public unicast address, else nil.
    /// IPv4: not private, loopback, CGNAT, link-local or multicast. IPv6:
    /// global unicast (2000::/3) only. The helper applies the same rule.
    public static func publicAddress(_ text: String) -> String? {
        if let quad = ConnectRequest.dottedQuad(text) {
            return ConnectRequest.isPrivate(v4: quad) ? nil : text
        }
        guard text.contains(":"), let canonical = Validate.ipAddress(text) else { return nil }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, canonical, &v6) == 1 else { return nil }
        let first = withUnsafeBytes(of: &v6) { $0[0] }
        return first & 0xe0 == 0x20 ? canonical : nil
    }

    /// The route prefix for an address: /32 for IPv4, /128 for IPv6.
    public static func prefix(_ address: String) -> String {
        address + (address.contains(":") ? "/128" : "/32")
    }

    /// Answers flattened to public addresses, without repeats, capped.
    public static func addresses(_ answers: [[String]]) -> [String] {
        var out: [String] = []
        for raw in answers.joined() {
            guard let ip = publicAddress(raw), !out.contains(ip) else { continue }
            out.append(ip)
        }
        return Array(out.prefix(maxRoutes))
    }

    /// AS-4: the new set first, then addresses of the previous set that left
    /// it, so a connection opened a minute ago keeps its route until the next
    /// change. Capped; the new set wins the room.
    public static func merge(new: [String], kept: [String]) -> [String] {
        Array((new + kept.filter { !new.contains($0) }).prefix(maxRoutes))
    }

    /// The helper arguments for `addresses`: empty when there are none.
    public static func argument(_ addresses: [String]) -> [String] {
        addresses.isEmpty ? [] : ["--site-routes", addresses.joined(separator: ",")]
    }

    // MARK: - Resolving

    public struct Resolution: Equatable, Sendable {
        /// Everything to route, for `--site-routes`.
        public var addresses: [String]
        /// Per entry, how many addresses it gave; 0 means it did not resolve.
        public var counts: [String: Int]

        public init(addresses: [String] = [], counts: [String: Int] = [:]) {
            self.addresses = addresses
            self.counts = counts
        }
    }

    /// One DoH lookup: name, IPv6 or not, and the completion it calls once.
    public typealias Lookup = @Sendable (String, Bool, @escaping @Sendable ([String]?) -> Void) -> Void

    public static let doh: Lookup = { name, ipv6, done in
        DoHResolver.shared.resolve(name, ipv6: ipv6, completion: done)
    }

    /// Resolve every entry, A and AAAA, in parallel. Blocking: run it off the
    /// main thread. A lookup that has not answered by `timeout` counts as none.
    public static func resolve(_ entries: [String], lookup: Lookup = doh,
                               timeout: TimeInterval = 8) -> Resolution {
        final class Answers: @unchecked Sendable {
            let lock = NSLock()
            var byEntry: [String: [String]] = [:]
        }
        let answers = Answers()
        let group = DispatchGroup()
        for entry in entries {
            answers.lock.lock()
            answers.byEntry[entry] = publicAddress(entry).map { [$0] } ?? []
            answers.lock.unlock()
            for name in lookupNames(entry) {
                for ipv6 in [false, true] {
                    group.enter()
                    lookup(name, ipv6) { found in
                        answers.lock.lock()
                        answers.byEntry[entry, default: []] += found ?? []
                        answers.lock.unlock()
                        group.leave()
                    }
                }
            }
        }
        _ = group.wait(timeout: .now() + timeout)
        answers.lock.lock(); let snapshot = answers.byEntry; answers.lock.unlock()
        var counts: [String: Int] = [:]
        for entry in entries { counts[entry] = addresses([snapshot[entry] ?? []]).count }
        return Resolution(addresses: addresses(entries.map { snapshot[$0] ?? [] }), counts: counts)
    }

    // MARK: - When to ask the helper again

    /// The `DNSRouteRefresh` rule, judged against what the helper reports live
    /// (route-state.json), so a mismatch left by an older run heals too.
    public struct Refresh: Equatable, Sendable {
        private var pending: [String]?
        /// The last set this app sent; joins the next one once (AS-4).
        public private(set) var sent: [String] = []

        public init() {}

        public mutating func reset() { pending = nil }

        /// The app just sent `addresses` itself (start, edit, scope change).
        public mutating func didSend(_ addresses: [String]) {
            sent = addresses
            pending = nil
        }

        /// Feed the fresh lookup and the live site routes (addresses, no
        /// suffix). Returns the set to send, or nil. Nothing to do while every
        /// fresh address is live; an empty lookup never replaces live routes.
        public mutating func observe(resolved: [String], live: [String]) -> [String]? {
            guard !resolved.isEmpty, !Set(resolved).isSubset(of: Set(live)) else {
                pending = nil
                return nil
            }
            guard let pending, Set(pending) == Set(resolved) else {
                self.pending = resolved
                return nil
            }
            let out = SiteRoutes.merge(new: resolved, kept: sent)
            didSend(resolved)
            return out
        }
    }
}

/// The last lookup, readable from any thread: `Model.dnsRouteArgs` is built on
/// the main thread and must not wait for DoH there.
public final class SiteAddressCache: @unchecked Sendable {
    public static let shared = SiteAddressCache()
    private let lock = NSLock()
    private var value: [String] = []

    public init() {}

    public var addresses: [String] {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

/// The user's list, `~/Library/Application Support/Menfez/sites.json` (0600).
/// A file that cannot be read is kept as `sites.json.bak` and the list starts
/// empty (§6.2); `load` says so, and the app tells the user.
public struct SiteList: Codable, Equatable, Sendable {
    public var version: Int
    public var sites: [String]

    public init(sites: [String] = []) {
        self.version = 1
        self.sites = sites
    }

    public static var path: String {
        (Path.support as NSString).appendingPathComponent("sites.json")
    }

    /// "Use in browsers too" (1.0.8): a separate list in the same format.
    public static var browserPath: String {
        (Path.support as NSString).appendingPathComponent("browser-sites.json")
    }

    public static func load(path: String = SiteList.path) -> (list: SiteList, recovered: Bool) {
        guard let data = FileManager.default.contents(atPath: path) else { return (SiteList(), false) }
        if let list = try? JSONDecoder().decode(SiteList.self, from: data), list.version == 1 {
            // A hand-edited file is cleaned the same way the editor would.
            var clean: [String] = []
            for raw in list.sites {
                if let entry = SiteRoutes.normalize(raw), !clean.contains(entry) { clean.append(entry) }
            }
            return (SiteList(sites: Array(clean.prefix(SiteRoutes.maxSites))), false)
        }
        let backup = path + ".bak"
        unlink(backup)
        _ = try? FileManager.default.moveItem(atPath: path, toPath: backup)
        return (SiteList(), true)
    }

    @discardableResult
    public func save(path: String = SiteList.path) -> Bool {
        StateFile.write(JSON.encode(self), to: path, mode: 0o600, dirMode: 0o700)
    }
}
