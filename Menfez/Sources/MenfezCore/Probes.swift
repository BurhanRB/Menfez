// Probes.swift — everything that only looks at the machine.
//
// This is the read-only half of the Python helper (menfez-route.py:
// public_ip, geo_lookup, discord_probe, dns_latency, measure_dns,
// resolver_answers, looks_poisoned, _route_summary). Nothing here writes a
// route, changes a resolver or needs root, which is why it can live in the
// app process while the mutating half stays in the privileged helper.
//
// THE ONE RULE
// A probe that cannot run returns nil, or an empty array. Never a zero, never
// a guess. The UI draws nil as a dash, and a fabricated "0 ms" next to a
// resolver that is silently dropping packets is worse than no number at all:
// it looks like a measurement.
//
// Every timeout below is the same number the Python used. They are not tuned
// by feel: `--max-time` is curl's own deadline, and the outer `timeout:` is
// always a little larger so that curl exits first and we get its error text
// instead of a killed process with half a body.

import Foundation

public enum Probes {

    // MARK: - Public address and geo

    /// The address the world sees, or nil.
    ///
    /// ipify answers with a bare address and no newline handling worth
    /// trusting, so the body is validated before it is believed: no spaces,
    /// at most 45 characters (a 39-character IPv6 plus room). The Python did
    /// the same, and it caught the case where curl printed a proxy error
    /// message instead of an address.
    public static func publicIP(iface: String? = nil,
                                using runner: CommandRunner = SystemRunner()) -> String? {
        var args = ["-sS", "--max-time", "6"]
        if let iface, !iface.isEmpty {
            args += ["--interface", iface]
        }
        args.append("https://api.ipify.org")

        // 10 s outer budget: ipify's 6 s covers the transfer, the remaining
        // 4 s absorb a slow DNS lookup or a slow TLS handshake. Without that
        // headroom curl gets killed mid-run and we cannot tell a timeout from
        // "this network has no egress".
        let result = runner.run("curl", args, timeout: 10)
        let body = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.ok, !body.isEmpty,
              !body.contains(" "), body.count <= 45 else { return nil }
        return body
    }

    /// Country/city/ISP for an address, or nil when ipinfo is unreachable.
    ///
    /// Optional by design: the report is still useful offline, and ipinfo.io
    /// is a free service with no SLA. `ispShort` is derived here so the UI
    /// never has to know about the alias table.
    public static func geo(ip: String,
                           using runner: CommandRunner = SystemRunner()) -> Geo? {
        guard !ip.isEmpty else { return nil }
        let result = runner.run("curl",
                                ["-sS", "--max-time", "5",
                                 "https://ipinfo.io/\(ip)/json"],
                                timeout: 8)
        guard result.ok, let object = jsonObject(result.output) else { return nil }

        let org = stringValue(object["org"])
        return Geo(country: stringValue(object["country"]),
                   city: stringValue(object["city"]),
                   region: stringValue(object["region"]),
                   org: org,
                   ispShort: ShortISP.short(org))
    }

    // MARK: - Discord

    /// HTTP status and round trip for https://discord.com.
    ///
    /// `-o /dev/null` throws the body away and `-w` prints the two numbers we
    /// want, so a 2 MB page never enters the process. code 0 means the request
    /// never completed, and `failure` then says at which step.
    ///
    /// The name is resolved over DoH (the chosen `DoHProvider`), not the system resolver. Some
    /// networks drop or reset plain DNS for Discord's names on every resolver
    /// while DoH and the routed addresses work; Discord itself (Chromium)
    /// upgrades to DoH there, so a plain-DNS probe said "blocked" while the
    /// client worked.
    ///
    /// - Parameter proxyPort: the DPI proxy's port. Discord goes through it in
    ///   DPI mode, so the probe does too; the proxy resolves the name itself.
    public static func discord(proxyPort: Int? = nil,
                               doh: Bool = curlSupportsDoH,
                               maxTime: Int = 8,
                               using runner: CommandRunner = SystemRunner()) -> DiscordProbe {
        let result = runner.run("curl", discordArgs(proxyPort: proxyPort, doh: doh, maxTime: maxTime),
                                timeout: TimeInterval(maxTime + 4))
        // `-w` prints even when the request fails, after curl's error line, so
        // the numbers are on the last line either way.
        let last = result.output
            .split(separator: "\n")
            .last.map(String.init) ?? ""
        let parts = last.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard result.ok else {
            return DiscordProbe(code: 0, ms: nil,
                                failure: classify(exit: result.status,
                                                  timedOut: result.timedOut,
                                                  output: result.output))
        }

        let code = parts.first.flatMap { Int($0) } ?? 0
        // Python did int(float(...) * 1000) and would raise on garbage; here a
        // body we cannot parse simply leaves ms nil, which the UI draws as a
        // dash next to the status code.
        var ms: Int?
        if parts.count > 1, let seconds = Double(parts[1]) {
            ms = Int(seconds * 1000)
        }
        return DiscordProbe(code: code, ms: ms,
                            failure: code == 0 ? .blocked : nil)
    }

    /// The curl command line for `discord`, separate so a test can read it.
    static func discordArgs(proxyPort: Int?, doh: Bool, maxTime: Int = 8) -> [String] {
        var args = ["-sS", "-o", "/dev/null",
                    "-w", "%{http_code} %{time_total}",
                    "--max-time", "\(maxTime)"]
        if let proxyPort {
            args += ["-x", "http://127.0.0.1:\(proxyPort)"]
        } else if doh {
            args += ["--doh-url", DoHProvider.current().endpoints[0]]
        }
        args.append("https://discord.com")
        return args
    }

    /// Which step a failed curl stopped at, from its exit status.
    ///
    /// 28 is curl's generic timeout; only its "Resolving timed out" text says
    /// the name never resolved, so that one case reads the message.
    public static func classify(exit: Int32, timedOut: Bool,
                                output: String) -> DiscordProbe.Failure {
        if timedOut { return .blocked }
        switch exit {
        case 6:
            return .dns
        case 28 where output.contains("Resolving timed out"):
            return .dns
        case 7:
            return .connect
        case 56 where output.contains("CONNECT tunnel failed"):
            return .proxy
        case 35, 51, 53, 54, 58, 59, 60, 64, 66, 77, 80, 82, 83, 90, 91:
            return .tls
        default:
            return .blocked
        }
    }

    /// True when the system curl knows `--doh-url` (added in 7.62.0).
    ///
    /// Asked once per process: the version cannot change under a running app.
    public static let curlSupportsDoH: Bool = {
        let result = SystemRunner().run("curl", ["--version"], timeout: 5)
        return result.ok && supportsDoH(versionOutput: result.output)
    }()

    /// Parse "curl 8.7.1 (x86_64-apple-darwin…) …" and compare with 7.62.
    static func supportsDoH(versionOutput: String) -> Bool {
        let words = versionOutput.split(separator: " ")
        guard words.count > 1, words[0] == "curl" else { return false }
        let numbers = words[1].split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        guard let major = numbers.first else { return false }
        let minor = numbers.count > 1 ? numbers[1] : 0
        return major > 7 || (major == 7 && minor >= 62)
    }

    // MARK: - DNS

    /// Median round trip in milliseconds for one resolver, or nil.
    ///
    /// Three samples, not one. The Python had two near-identical probems: a
    /// single query for the popup and three for the resolver picker, and the
    /// single sample was visibly unstable on Wi-Fi (the same resolver read
    /// 3 ms and 300 ms within a second). One number everywhere, taken from the
    /// middle of three sorted samples, is both cheaper to reason about and
    /// closer to what a person feels.
    public static func dnsLatency(server: String,
                                  using runner: CommandRunner = SystemRunner()) -> Int? {
        guard !server.isEmpty else { return nil }
        let args = ["+time=2", "+tries=1", "@" + server, "example.com", "A"]

        var samples: [Int] = []
        for _ in 0..<3 {
            let result = runner.run("dig", args, timeout: 6)
            // A resolver that fails any of the three is reported as "no
            // answer" rather than averaged over the samples that survived: a
            // half-broken resolver must not look healthy.
            guard result.ok else { return nil }
            if let ms = queryTime(result.output) { samples.append(ms) }
        }
        guard !samples.isEmpty else { return nil }
        samples.sort()
        return samples[samples.count / 2]
    }

    /// A/AAAA answers for one name from one resolver.
    ///
    /// `+short` prints one address per line and nothing else. Anything that is
    /// not a dotted IPv4 address is dropped, which is how the Python filtered
    /// the "communications error" chatter dig puts on the same stream.
    public static func dnsAnswers(server: String,
                                  name: String = "example.com",
                                  using runner: CommandRunner = SystemRunner()) -> [String] {
        guard !server.isEmpty else { return [] }
        let result = runner.run("dig",
                                ["+short", "+time=3", "+tries=1",
                                 "@" + server, name],
                                timeout: 7)
        guard result.ok else { return [] }
        return result.output
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter(isDottedIPv4)
    }

    /// A/AAAA answers from the *system* resolver, i.e. dig with no `@server`.
    ///
    /// This is what the Discord popup needs: the question is not "does a
    /// public resolver know this name" but "can this Mac resolve it right
    /// now", which is exactly what breaks when the tunnel's routes are wrong
    /// but the resolver was left pointing at the ISP.
    public static func systemAnswers(_ name: String,
                                     using runner: CommandRunner = SystemRunner()) -> [String] {
        let result = runner.run("dig",
                                ["+short", "+time=3", "+tries=1", name],
                                timeout: 8)
        guard result.ok else { return [] }
        // The Python took every line whose first character was a digit. That
        // keeps IPv6 answers, which a dotted-quad check would silently drop,
        // and still discards dig's ";; communications error" chatter.
        return result.output
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { line in
                guard let first = line.first else { return false }
                return first.isNumber
            }
    }

    /// True when a resolver's answer is a private or otherwise bogus address.
    ///
    /// An empty answer counts as poisoned: a resolver that will not answer
    /// example.com is not a resolver. The rest is Python's test — is_private,
    /// is_loopback, is_link_local, is_multicast, or 0.0.0.0 — because a
    /// captive portal or a transparent interceptor typically answers with one
    /// of those instead of failing the query outright.
    public static func looksPoisoned(_ ips: [String]) -> Bool {
        guard !ips.isEmpty else { return true }
        for ip in ips {
            // An unparsable address is as suspicious as a private one: no
            // real answer to example.com is ever "not an address".
            guard let bogus = isBogusAddress(ip) else { return true }
            if bogus { return true }
        }
        return false
    }

    // MARK: - Routing

    /// "en0 via 192.168.1.1" for a destination, from `route -n get`.
    ///
    /// The "?" placeholders are Python's behaviour and they are informative:
    /// a destination reached over a directly connected subnet has an
    /// interface but no gateway, and showing "en0 via ?" is honest about the
    /// missing half.
    public static func routeSummary(ip: String,
                                    using runner: CommandRunner = SystemRunner()) -> String {
        let result = runner.run("route", ["-n", "get", ip], timeout: 10)
        guard result.ok else { return "unreachable" }

        var iface = "?"
        var gateway = "?"
        for line in result.output.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("interface:") {
                iface = value(after: "interface:", in: text)
            } else if text.hasPrefix("gateway:") {
                gateway = value(after: "gateway:", in: text)
            }
        }
        return "\(iface) via \(gateway)"
    }

    // MARK: - Formatting

    /// 1023 -> "1023 B", 1024 -> "1.0 KB", 5 GiB -> "5.0 GB".
    ///
    /// Binary divisors with decimal-looking units, which is what the Python
    /// printed and what the user has already seen in this app.
    public static func humanBytes(_ bytes: Int) -> String {
        var value = Double(max(0, bytes))
        for unit in ["B", "KB", "MB", "GB"] {
            if value < 1024 {
                return unit == "B"
                    ? String(format: "%.0f B", value)
                    : String(format: "%.1f %@", value, unit)
            }
            value /= 1024
        }
        return String(format: "%.1f TB", value)
    }

    // MARK: - Small helpers

    /// The JSON object in a tool's output, or nil.
    ///
    /// Shell merges stdout and stderr, and curl writes its diagnostics to
    /// stderr, so a warning line can end up in front of a perfectly good body.
    /// We therefore accept either the whole trimmed text or the last line that
    /// opens with a brace — the same rule Types.JSON.decode uses, so the two
    /// cannot disagree about what counts as a body.
    static func jsonObject(_ text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: String
        if trimmed.hasPrefix("{") {
            candidate = trimmed
        } else if let line = text
            .split(separator: "\n")
            .last(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("{") }) {
            candidate = String(line)
        } else {
            return nil
        }

        guard let data = candidate.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let object = raw as? [String: Any] else { return nil }
        return object
    }

    /// A non-empty string from a JSON value, accepting numbers too (ipinfo
    /// returns `postal` as a number for some countries).
    static func stringValue(_ value: Any?) -> String? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    /// The milliseconds from dig's ";; Query time: 12 msec" line.
    static func queryTime(_ text: String) -> Int? {
        guard let anchor = text.range(of: "Query time:") else { return nil }
        let rest = text[anchor.upperBound...].drop(while: { $0 == " " })
        let digits = rest.prefix(while: { $0.isNumber })
        return digits.isEmpty ? nil : Int(digits)
    }

    /// Everything after "key:" on an `route -n get` line.
    private static func value(after key: String, in line: String) -> String {
        guard let range = line.range(of: key) else { return line }
        return line[range.upperBound...].trimmingCharacters(in: .whitespaces)
    }

    /// Python's `^\d+\.\d+\.\d+\.\d+$`, deliberately without range checks: the
    /// point is to drop dig's prose, and a bogus address is caught later by
    /// `looksPoisoned`.
    private static func isDottedIPv4(_ text: String) -> Bool {
        let groups = text.split(separator: ".", omittingEmptySubsequences: false)
        guard groups.count == 4 else { return false }
        return groups.allSatisfy { group in
            !group.isEmpty && group.count <= 3 && group.allSatisfy(\.isNumber)
        }
    }

    /// nil = not an address at all; true = private, loopback, link-local,
    /// multicast, unspecified, or an IPv4 address wearing an IPv6 mask.
    private static func isBogusAddress(_ text: String) -> Bool? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)

        var v4 = in_addr()
        if inet_pton(AF_INET, trimmed, &v4) == 1 {
            let bytes = withUnsafeBytes(of: &v4.s_addr) { Array($0) }
            return bogusIPv4(bytes)
        }

        var v6 = in6_addr()
        if inet_pton(AF_INET6, trimmed, &v6) == 1 {
            let bytes = withUnsafeBytes(of: &v6) { Array($0) }
            return bogusIPv6(bytes)
        }

        return nil
    }

    /// The ranges Python's is_private / is_loopback / is_link_local /
    /// is_multicast cover for IPv4.
    private static func bogusIPv4(_ b: [UInt8]) -> Bool {
        guard b.count == 4 else { return true }
        let a = Int(b[0]), c = Int(b[1]), d = Int(b[2])

        switch a {
        case 0:                     return true   // 0.0.0.0/8, includes the bare 0.0.0.0
        case 10:                     return true   // private
        case 127:                    return true   // loopback
        case 169:                    return c == 254          // link-local
        case 172:                    return (16...31).contains(c)   // private
        case 192:                    return c == 168           // private
            || (c == 0 && d == 0)                              // 192.0.0.0/24
        case 198:                    return c == 18 || c == 19  // benchmarking
        case 224...239:              return true   // multicast
        case 240...255:              return true   // reserved, incl. 255.255.255.255
        default:                     return false
        }
    }

    /// The IPv6 equivalents, plus IPv4-mapped addresses unwrapped so that
    /// ::ffff:192.168.1.1 is caught as private rather than slipping through.
    private static func bogusIPv6(_ b: [UInt8]) -> Bool {
        guard b.count == 16 else { return true }

        // ::ffff:a.b.c.d
        if b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xff, b[11] == 0xff {
            return bogusIPv4(Array(b[12..<16]))
        }

        if b.allSatisfy({ $0 == 0 }) { return true }              // ::
        if b[0..<15].allSatisfy({ $0 == 0 }), b[15] == 1 { return true }  // ::1
        if b[0] == 0xfe, (b[1] & 0xc0) == 0x80 { return true }    // fe80::/10 link-local
        if b[0] == 0xff { return true }                           // ff00::/8 multicast
        if (b[0] & 0xfe) == 0xfc { return true }                  // fc00::/7 unique local
        return false
    }
}
