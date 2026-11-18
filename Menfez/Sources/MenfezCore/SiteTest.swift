// SiteTest.swift — "does this site open, and which way?"
//
// The user types a site; Menfez tries it the ways that exist right now
// (directly, through a DPI proxy, or through the tunnel when the tunnel
// carries everything), all at once with short deadlines, and says in one
// sentence what worked.
//
// Same rules as the DPI proxy: only a public name on port 443 is tried. The
// name is resolved over DoH first; an answer that points into the LAN or
// loopback stops the test, and the direct attempt is pinned (`--resolve`) to
// the address that was checked, so a second lookup cannot swap it.
// Nothing is stored and nothing is logged; the test runs only when asked.

import Foundation

public enum SiteTest {

    // MARK: - Input

    public enum InputError: String, Error, Sendable {
        case empty
        /// Not a web address we can read.
        case notAName
        /// An IP address: a site name is what the user means (AS-26).
        case address
        /// localhost, .local, a LAN name: the same refusal as the proxy.
        case local
        /// A port other than the web's own.
        case port
    }

    /// The host to test, from what the user typed: `discord.com`,
    /// `https://www.example.com/a?b`, `ÇAY.com.tr` (sent as punycode).
    public static func host(from input: String) -> Result<String, InputError> {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }
        guard text.count <= 2048, !text.contains(where: { $0.isWhitespace }) else { return .failure(.notAName) }
        guard let parts = URLComponents(string: text.contains("://") ? text : "https://" + text),
              let scheme = parts.scheme?.lowercased(), scheme == "https" || scheme == "http",
              parts.user == nil, parts.password == nil,
              var name = parts.encodedHost?.lowercased(), !name.isEmpty else { return .failure(.notAName) }
        if let port = parts.port, port != 443, port != 80 { return .failure(.port) }
        while name.hasSuffix(".") { name.removeLast() }

        if name.contains(":") || name.hasPrefix("[") { return .failure(.address) }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        if let tld = labels.last, tld.allSatisfy({ $0.isNumber }) {
            return .failure(ConnectRequest.dottedQuad(name) != nil ? .address : .notAName)
        }
        if name == "localhost" || name.hasSuffix(".localhost") || name.hasSuffix(".local") {
            return .failure(.local)
        }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        guard labels.count >= 2, name.utf8.count <= 253,
              labels.allSatisfy({ (1...63).contains($0.count) && $0.allSatisfy(allowed.contains)
                                  && $0.first != "-" && $0.last != "-" }) else { return .failure(.notAName) }
        if ConnectRequest(host: name, port: 443).policyRefusal != nil { return .failure(.local) }
        return .success(name)
    }

    // MARK: - Paths and results

    public enum Path: String, CaseIterable, Sendable {
        case direct, dpi, tunnel
    }

    /// The ways that mean something now. With Whole internet on, direct and
    /// proxied requests leave through the tunnel too, so the tunnel is the
    /// only way there is; otherwise the site is outside the tunnel and is
    /// tried directly and through DPI (which needs no setup).
    public static func paths(tunnelCarriesEverything: Bool) -> [Path] {
        tunnelCarriesEverything ? [.tunnel] : [.direct, .dpi]
    }

    public enum Outcome: String, Sendable {
        case opens, fails, timedOut, notFound
    }

    public static func outcome(_ a: DPIProbeOutcome.Attempt) -> Outcome {
        if a.ok { return .opens }
        if a.dnsFailed { return .notFound }
        if a.exit == 28 { return .timedOut }
        return .fails
    }

    /// The sentence under the rows.
    public enum Summary: String, Sendable {
        case opensDirect, opensWithDPI, opensWithTunnel
        /// Nothing worked and no tunnel was tried: the tunnel is the next step.
        case opensNowhere
        /// Nothing worked, the tunnel included: the site itself may be down.
        case opensNowhereTunnel
        case notFound
        /// The name points at a local address; nothing was tried.
        case refused
        /// The chosen DoH service blocks the name (0.0.0.0 or no answer)
        /// while another one finds it. Filters such as AdGuard do this.
        case dnsFiltered
    }

    public static func summary(_ results: [Path: Outcome]) -> Summary {
        if results.isEmpty || results.values.allSatisfy({ $0 == .notFound }) { return .notFound }
        if results[.direct] == .opens { return .opensDirect }
        if results[.dpi] == .opens { return .opensWithDPI }
        if results[.tunnel] == .opens { return .opensWithTunnel }
        return results[.tunnel] == nil ? .opensNowhere : .opensNowhereTunnel
    }

    /// One line for a DPI-only run (the browser list, 1.0.8): the DPI row,
    /// or not found / fails when nothing was tried.
    public static func dpiOutcome(_ r: Report) -> Outcome {
        if let o = r.results[.dpi] { return o }
        return r.summary == .notFound ? .notFound : .fails
    }

    public struct Report: Equatable, Sendable {
        public var host: String
        public var results: [Path: Outcome]
        public var summary: Summary
        public init(host: String, results: [Path: Outcome], summary: Summary) {
            self.host = host
            self.results = results
            self.summary = summary
        }
    }

    // MARK: - Running

    /// Try `host` on every path, in parallel. `proxyPort` is a DPI proxy the
    /// caller started for the test (needed only when `paths` has `.dpi`).
    /// Blocks for at most ~DoH plus one `DPIProbe.outerTimeout`; call it off
    /// the main thread.
    /// `others` are asked only when `resolver` gives nothing or a filter's
    /// 0.0.0.0: an answer there means the chosen DNS filters the name, and
    /// the direct attempt uses that answer so the row still says something.
    public static func run(host: String, paths: [Path], proxyPort: Int?,
                           resolver: HostResolver = DoHResolver.shared,
                           others: [HostResolver] = DoHResolver.otherProviders(),
                           runner: CommandRunner = SystemRunner()) -> Report {
        var addresses = resolve(host, with: resolver)
        var filtered = false
        if addresses.isEmpty || isFilterAnswer(addresses) {
            if let found = firstAnswer(host, from: others) {
                addresses = found
                filtered = true
            } else {
                addresses = []
            }
        }
        guard let first = addresses.first else {
            return Report(host: host, results: Dictionary(uniqueKeysWithValues: paths.map { ($0, .notFound) }),
                          summary: .notFound)
        }
        if addresses.contains(where: { ConnectRequest(host: $0, port: 443).policyRefusal != nil }) {
            return Report(host: host, results: [:], summary: .refused)
        }

        var results: [Path: Outcome] = [:]
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: paths.count) { i in
            let path = paths[i]
            let attempt: DPIProbeOutcome.Attempt
            switch path {
            case .direct, .tunnel:
                attempt = DPIProbe.attempt(host: host, proxyPort: nil, pin: first, using: runner)
            case .dpi:
                attempt = proxyPort.map { DPIProbe.attempt(host: host, proxyPort: $0, using: runner) }
                    ?? .init(exit: 7, error: "proxy not running")
            }
            lock.lock()
            results[path] = outcome(attempt)
            lock.unlock()
        }
        return Report(host: host, results: results, summary: filtered ? .dnsFiltered : summary(results))
    }

    /// All of 0.0.0.0/8: what AdGuard and family filters answer for a name
    /// they block. Not a place anything can be reached.
    static func isFilterAnswer(_ addresses: [String]) -> Bool {
        !addresses.isEmpty && addresses.allSatisfy { ConnectRequest.dottedQuad($0)?.first == 0 }
    }

    /// The first usable answer from `resolvers`, asked at the same time.
    private static func firstAnswer(_ host: String, from resolvers: [HostResolver]) -> [String]? {
        guard !resolvers.isEmpty else { return nil }
        var answers = [[String]](repeating: [], count: resolvers.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: resolvers.count) { i in
            let found = resolve(host, with: resolvers[i])
            lock.lock()
            answers[i] = found
            lock.unlock()
        }
        return answers.first { !$0.isEmpty && !isFilterAnswer($0) }
    }

    private static func resolve(_ host: String, with resolver: HostResolver) -> [String] {
        let done = DispatchSemaphore(value: 0)
        let box = AddressBox()
        resolver.resolve(host) { found in
            box.set(found ?? [])
            done.signal()
        }
        guard done.wait(timeout: .now() + DPIProbe.curlTimeout) == .success else { return [] }
        return box.get()
    }

    private final class AddressBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [String] = []
        func set(_ v: [String]) { lock.lock(); value = v; lock.unlock() }
        func get() -> [String] { lock.lock(); defer { lock.unlock() }; return value }
    }
}
