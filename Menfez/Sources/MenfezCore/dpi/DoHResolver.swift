// DoHResolver.swift — how the proxy finds an IP for a CONNECT host.
//
// WHY
// ---
// Some Turkish ISPs (seen on Vodafone TR) drop or reset plain DNS for Discord's
// names on every resolver: UDP to 1.1.1.1/8.8.8.8/9.9.9.9 times out and TCP DNS
// is reset, while the 162.159.x addresses themselves are reachable. An
// NWConnection given the hostname then sits in `.waiting` until the dial
// deadline and the proxy answers 504, so the split never even gets to run.
// DNS over HTTPS to Cloudflare by IP literal is not blocked there.
//
// The provider is the user's choice (`DoHProvider`); every one is asked by IP
// literal in RFC 8484 wire format, the only format all four serve (Quad9 has
// no JSON API on 443).
//
// NO LOOP
// -------
// The endpoints are IP literals, so the lookup needs no DNS of its own, and the
// session is told to use no proxy, so it can never be routed through the
// CONNECT proxy it serves. (That proxy is only ever handed to Discord with
// --proxy-server; it is never a system proxy. The setting is belt and braces.)

import Foundation

/// Finds addresses for a hostname. A protocol so tests can inject a fake.
public protocol HostResolver: Sendable {
    /// Calls `completion` once, on any queue, with the addresses (IPv4 text) or
    /// nil when the lookup failed and the caller should fall back.
    func resolve(_ host: String, completion: @escaping @Sendable ([String]?) -> Void)
}

/// The DoH service the proxy and the probes ask. Stored in UserDefaults.
public enum DoHProvider: String, CaseIterable, Sendable {
    case cloudflare, google, quad9, adguard

    public static let defaultsKey = "dohProvider"

    /// Bootstrap addresses. The endpoints are these IP literals (each
    /// provider's certificate names them), so no plain DNS is ever needed.
    public var addresses: [String] {
        switch self {
        case .cloudflare: return ["1.1.1.1", "1.0.0.1"]
        case .google:     return ["8.8.8.8", "8.8.4.4"]
        case .quad9:      return ["9.9.9.9", "149.112.112.112"]
        case .adguard:    return ["94.140.14.14", "94.140.15.15"]
        }
    }

    /// Tried in order; the second only when the first fails.
    public var endpoints: [String] { addresses.map { "https://\($0)/dns-query" } }

    public var name: String {
        switch self {
        case .cloudflare: return "Cloudflare"
        case .google:     return "Google"
        case .quad9:      return "Quad9"
        case .adguard:    return "AdGuard"
        }
    }

    /// The saved choice; Cloudflare when unset or unknown.
    public static func current(_ defaults: UserDefaults = .standard) -> DoHProvider {
        defaults.string(forKey: defaultsKey).flatMap(DoHProvider.init(rawValue:)) ?? .cloudflare
    }
}

public final class DoHResolver: HostResolver, @unchecked Sendable {

    public static let shared = DoHResolver()

    /// Read on every lookup, so a change in the picker applies at once.
    private let provider: @Sendable () -> DoHProvider

    /// Longest an answer is reused, whatever its TTL says.
    static let maxCacheSeconds = 300

    /// Per endpoint. Two of these still leave the 10 s dial deadline room for
    /// the system-DNS fallback.
    static let requestTimeout: TimeInterval = 3

    private let session: URLSession
    private let lock = NSLock()
    private var cache: [String: (addresses: [String], expires: Date)] = [:]

    public init(provider: @escaping @Sendable () -> DoHProvider = { DoHProvider.current() }) {
        self.provider = provider
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Self.requestTimeout
        config.timeoutIntervalForResource = Self.requestTimeout
        config.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: false,
            kCFNetworkProxiesHTTPSEnable as String: false,
        ]
        session = URLSession(configuration: config)
    }

    public func resolve(_ host: String, completion: @escaping @Sendable ([String]?) -> Void) {
        resolve(host, ipv6: false, completion: completion)
    }

    /// `ipv6` asks for AAAA records instead of A (chosen sites route both).
    public func resolve(_ host: String, ipv6: Bool,
                        completion: @escaping @Sendable ([String]?) -> Void) {
        let name = host.lowercased()
        let key = ipv6 ? name + "|aaaa" : name
        lock.lock()
        if let hit = cache[key], hit.expires > Date() {
            lock.unlock()
            completion(hit.addresses)
            return
        }
        lock.unlock()
        query(name, key: key, type: ipv6 ? 28 : 1, endpoints: provider().endpoints, index: 0,
              completion: completion)
    }

    private func query(_ name: String, key: String, type: UInt8, endpoints: [String], index: Int,
                       completion: @escaping @Sendable ([String]?) -> Void) {
        guard index < endpoints.count,
              let message = Self.message(for: name, type: type),
              var parts = URLComponents(string: endpoints[index]) else {
            completion(nil)
            return
        }
        let dns = message.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        parts.queryItems = [URLQueryItem(name: "dns", value: dns)]
        guard let url = parts.url else { completion(nil); return }
        var request = URLRequest(url: url)
        request.setValue("application/dns-message", forHTTPHeaderField: "Accept")

        session.dataTask(with: request) { [weak self] data, response, _ in
            guard let self else { completion(nil); return }
            if (response as? HTTPURLResponse)?.statusCode == 200,
               let data, let answer = Self.parse(data, type: type) {
                let ttl = min(max(answer.ttl, 0), Self.maxCacheSeconds)
                self.lock.lock()
                self.cache[key] = (answer.addresses, Date().addingTimeInterval(TimeInterval(ttl)))
                self.lock.unlock()
                completion(answer.addresses)
            } else {
                self.query(name, key: key, type: type, endpoints: endpoints, index: index + 1,
                           completion: completion)
            }
        }.resume()
    }

    /// An RFC 8484 query for the A (type 1) or AAAA (type 28) record of
    /// `name`, or nil for a name that cannot be one (empty or over-long label,
    /// over 253 bytes). The proxy asks A only; chosen sites ask both.
    static func message(for name: String, type: UInt8 = 1) -> Data? {
        var trimmed = name
        while trimmed.hasSuffix(".") { trimmed.removeLast() }
        let labels = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 253 else { return nil }
        // ID 0 (RFC 8484 §4.1), RD set, one question.
        var out = Data([0, 0, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0])
        for label in labels {
            let bytes = Array(label.utf8)
            guard (1...63).contains(bytes.count) else { return nil }
            out.append(UInt8(bytes.count))
            out.append(contentsOf: bytes)
        }
        out.append(contentsOf: [0, 0, type, 0, 1])   // root, QTYPE, QCLASS IN
        return out
    }

    /// The A (or AAAA, `type` 28) records and the lowest TTL of a wire-format
    /// answer, or nil when there is no usable one (NXDOMAIN, CNAME only,
    /// truncated, junk).
    static func parse(_ data: Data, type wanted: UInt8 = 1) -> (addresses: [String], ttl: Int)? {
        let b = [UInt8](data)
        guard b.count >= 12, b[3] & 0x0f == 0 else { return nil }
        let questions = Int(b[4]) << 8 | Int(b[5])
        let answers = Int(b[6]) << 8 | Int(b[7])
        var at = 12

        /// Moves past a name; a compression pointer ends it in two bytes.
        func skipName() -> Bool {
            while at < b.count {
                let length = Int(b[at])
                if length & 0xc0 == 0xc0 { at += 2; return at <= b.count }
                at += 1 + length
                if length == 0 { return at <= b.count }
            }
            return false
        }

        for _ in 0..<questions {
            guard skipName() else { return nil }
            at += 4
        }
        var addresses: [String] = []
        var ttl = Int.max
        for _ in 0..<answers {
            guard skipName(), at + 10 <= b.count else { return nil }
            let type = Int(b[at]) << 8 | Int(b[at + 1])
            let recordTTL = Int(b[at + 4]) << 24 | Int(b[at + 5]) << 16 | Int(b[at + 6]) << 8 | Int(b[at + 7])
            let length = Int(b[at + 8]) << 8 | Int(b[at + 9])
            at += 10
            guard at + length <= b.count else { return nil }
            if wanted == 1, type == 1, length == 4 {
                addresses.append(b[at..<at + 4].map(String.init).joined(separator: "."))
                ttl = min(ttl, recordTTL)
            } else if wanted == 28, type == 28, length == 16,
                      let text = Self.ipv6Text(Array(b[at..<at + 16])) {
                addresses.append(text)
                ttl = min(ttl, recordTTL)
            }
            at += length
        }
        return addresses.isEmpty ? nil : (addresses, ttl)
    }

    /// Sixteen bytes in canonical text ("2606:4700::1111").
    static func ipv6Text(_ bytes: [UInt8]) -> String? {
        var addr = in6_addr()
        withUnsafeMutableBytes(of: &addr) { $0.copyBytes(from: bytes) }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &addr, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: buffer)
    }
}
