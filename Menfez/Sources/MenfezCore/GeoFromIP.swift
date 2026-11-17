// GeoFromIP.swift — which country does an exit address belong to?
//
// WHY A SEPARATE FILE
// A user-supplied WireGuard config often carries no country anywhere: the file
// may be called "work.conf" with an endpoint of `203.0.113.7:51820`. The only
// honest way to show a flag is to ask an address service what country that IP
// belongs to.
//
// This costs one HTTPS request per unknown server, so the rules are:
//
//   * never on the refresh timer and never on the main thread;
//   * cached on disk, keyed by IP, so a second open is free;
//   * a failed lookup yields nil, is remembered for `failureTTL`, and the row
//     shows no flag. It never guesses from the endpoint's first octet or from
//     the AS name.
//
// Nothing here reads or writes a config file, so it cannot leak key material.

import Foundation

public enum GeoFromIP {

    // MARK: - Cache

    /// Where lookups are remembered. A file rather than memory because the
    /// picker is opened and closed; re-asking on every open would be one
    /// request per server every time.
    public static var cachePath: String {
        (Path.support as NSString).appendingPathComponent("geo-cache.json")
    }

    /// How long a cached answer is trusted.
    ///
    /// IP allocations move between providers over months, not days. A week is
    /// short enough that a moved address is corrected without the user noticing
    /// and long enough that normal use never re-asks.
    static let maxAge: TimeInterval = 7 * 24 * 3600

    /// How long a failed lookup is remembered.
    ///
    /// Without this, every profile listing re-asked ipinfo for each unknown
    /// server and waited out the timeout again when offline. An hour is short
    /// enough that a flaky request is retried soon, long enough that one launch
    /// never pays for the same failure twice.
    static let failureTTL: TimeInterval = 3600

    /// At most this many `curl`s at once: N unknown servers cost about
    /// ceil(N/4) timeouts instead of N when the network is down.
    static let maxConcurrent = 4

    struct Entry: Codable {
        var country: String?
        var city: String?
        var lookedUp: Date

        /// A remembered failure: no answer at all.
        var isFailure: Bool { country == nil && city == nil }
    }

    static func loadCache(path: String, now: Date = Date()) -> [String: Entry] {
        guard let data = FileManager.default.contents(atPath: path),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return decoded.filter {
            now.timeIntervalSince($0.value.lookedUp) < ($0.value.isFailure ? failureTTL : maxAge)
        }
    }

    static func saveCache(_ cache: [String: Entry], path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(cache)
        Path.ensureDir((path as NSString).deletingLastPathComponent, mode: 0o700)
        // The cache is not secret but it does say which servers the user has,
        // so it gets the same 0600 treatment as the profiles.
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        let ok = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) } == data.count
        close(fd)
        if !ok { throw CocoaError(.fileWriteUnknown) }
    }

    // MARK: - Lookup

    /// Country and city for an address, using the cache when possible.
    ///
    /// - Parameter runner: injected so a test can answer without a network.
    public static func lookup(ip: String,
                              cachePath: String = GeoFromIP.cachePath,
                              using runner: CommandRunner = SystemRunner(),
                              now: Date = Date())
        -> (country: String?, city: String?) {
        let entry = resolve([ip], cachePath: cachePath, using: runner, now: now)[ip]
        return (entry?.country, entry?.city)
    }

    /// Resolve countries for several hosts in one pass.
    ///
    /// Hosts that are already cached cost nothing. Hosts that are not IP
    /// literals are skipped: ipinfo answers for addresses, and a DNS name would
    /// be asked about on every listing for nothing.
    public static func countries(forIPs ips: [String],
                                 cachePath: String = GeoFromIP.cachePath,
                                 using runner: CommandRunner = SystemRunner(),
                                 now: Date = Date())
        -> [String: String] {
        resolve(ips, cachePath: cachePath, using: runner, now: now)
            .compactMapValues(\.country)
    }

    /// The shared path: one cache read, concurrent misses, one cache write.
    static func resolve(_ ips: [String], cachePath: String,
                        using runner: CommandRunner, now: Date) -> [String: Entry] {
        let wanted = Set(ips.filter { Validate.ipAddress($0) != nil })
        guard !wanted.isEmpty else { return [:] }
        var cache = loadCache(path: cachePath, now: now)
        let misses = wanted.filter { cache[$0] == nil }.sorted()

        if !misses.isEmpty {
            let lock = NSLock()
            var fetched: [String: Entry] = [:]
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = maxConcurrent
            for ip in misses {
                queue.addOperation {
                    // A failure is remembered too (both fields nil), so the next
                    // listing within `failureTTL` does not wait on it again.
                    let entry = fetch(ip: ip, using: runner, now: now)
                        ?? Entry(country: nil, city: nil, lookedUp: now)
                    lock.lock(); fetched[ip] = entry; lock.unlock()
                }
            }
            queue.waitUntilAllOperationsAreFinished()
            cache.merge(fetched) { _, new in new }
            try? saveCache(cache, path: cachePath)
        }
        return cache.filter { wanted.contains($0.key) && !$0.value.isFailure }
    }

    /// One ipinfo request. Nil when it failed or said nothing usable.
    static func fetch(ip: String, using runner: CommandRunner, now: Date) -> Entry? {
        // ipinfo's free endpoint: no key, no account, returns JSON including a
        // two-letter country. A single `curl` through the injected runner keeps
        // this testable and keeps the timeout policy in one place.
        let result = runner.run("/usr/bin/curl",
                                ["-sS", "--max-time", "6",
                                 "https://ipinfo.io/\(ip)/json"],
                                timeout: 10)
        guard result.ok,
              let object = try? JSONSerialization.jsonObject(with: Data(result.output.utf8))
                  as? [String: Any]
        else { return nil }

        let country = (object["country"] as? String).flatMap { code -> String? in
            let upper = code.uppercased()
            guard upper.count == 2, upper.allSatisfy({ $0.isASCII && $0.isLetter })
            else { return nil }
            return upper
        }
        let city = object["city"] as? String
        guard country != nil || city != nil else { return nil }
        return Entry(country: country, city: city, lookedUp: now)
    }
}
