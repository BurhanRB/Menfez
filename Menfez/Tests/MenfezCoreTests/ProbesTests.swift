import XCTest
@testable import MenfezCore

/// The outbound probes: what they run, how they run, and what they conclude.
final class ProbesTests: XCTestCase {

    /// Answers every `curl` after a fixed delay and records each command line.
    final class SlowCurl: CommandRunner, @unchecked Sendable {
        let delay: TimeInterval
        private let lock = NSLock()
        private var _lines: [String] = []
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }

        init(delay: TimeInterval) { self.delay = delay }

        func run(_ tool: String, _ args: [String], timeout: TimeInterval) -> CommandResult {
            let line = ([tool] + args).joined(separator: " ")
            lock.lock(); _lines.append(line); lock.unlock()
            Thread.sleep(forTimeInterval: delay)
            if line.contains("api.ipify.org") { return CommandResult(status: 0, output: "203.0.113.7") }
            if line.contains("ipinfo.io") { return CommandResult(status: 0, output: #"{"country":"BG"}"#) }
            return CommandResult(status: 0, output: "200 0.050 0.200")
        }
    }

    /// ipify -> ipinfo and the Discord request are independent, so the run
    /// takes the longer chain (two calls), not the sum of all three.
    func testIPChainAndDiscordRunInParallel() {
        let runner = SlowCurl(delay: 0.4)
        let start = Date()
        let result = ReportBuilder.probes(using: runner)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(result.egressIP, "203.0.113.7")
        XCTAssertEqual(result.geo?.country, "BG")
        XCTAssertEqual(result.discord.code, 200)
        XCTAssertLessThan(elapsed, 1.1, "three sequential 0.4 s calls would take 1.2 s")
    }

    /// No probe asks for the address from inside the tunnel any more: nothing
    /// displayed it, and in `all` mode it cost two more HTTPS requests.
    func testProbesNeverAskThroughTheTunnelInterface() {
        let runner = SlowCurl(delay: 0)
        _ = ReportBuilder.probes(using: runner)
        XCTAssertFalse(runner.lines.contains { $0.contains("--interface") }, "\(runner.lines)")
        XCTAssertEqual(runner.lines.count, 3)
    }
}

/// The Discord row's verdict and the command behind it.
final class DiscordProbeTests: XCTestCase {

    func testFailedRequestIsClassifiedByCurlExitStatus() {
        XCTAssertEqual(Probes.classify(exit: 6, timedOut: false, output: ""), .dns)
        XCTAssertEqual(Probes.classify(exit: 28, timedOut: false,
                                       output: "curl: (28) Resolving timed out after 8005 milliseconds\n000 8.005"),
                       .dns)
        XCTAssertEqual(Probes.classify(exit: 28, timedOut: false,
                                       output: "curl: (28) Connection timed out after 8001 milliseconds"),
                       .blocked)
        XCTAssertEqual(Probes.classify(exit: 7, timedOut: false, output: ""), .connect)
        XCTAssertEqual(Probes.classify(exit: 35, timedOut: false, output: ""), .tls)
        XCTAssertEqual(Probes.classify(exit: 60, timedOut: false, output: ""), .tls)
        XCTAssertEqual(Probes.classify(exit: 56, timedOut: false, output: ""), .blocked)
        XCTAssertEqual(Probes.classify(exit: 6, timedOut: true, output: ""), .blocked)
    }

    /// The live failure this was written for: plain DNS for discord.com dropped.
    func testResolveTimeoutReadsAsDNSNotAsReachable() {
        let runner = Canned(CommandResult(
            status: 28, output: "curl: (28) Resolving timed out after 8005 milliseconds\n000 8.005499"))
        let probe = Probes.discord(doh: true, using: runner)
        XCTAssertEqual(probe.code, 0)
        XCTAssertEqual(probe.failure, .dns)
    }

    func testSuccessParsesCodeAndTime() {
        let probe = Probes.discord(doh: true, using: Canned(CommandResult(status: 0, output: "200 1.092 1.146")))
        XCTAssertEqual(probe, DiscordProbe(code: 200, ms: 54), "TLS done to first byte, not the 1 s DoH lookup")
        XCTAssertEqual(Probes.discord(doh: true, using: Canned(CommandResult(status: 0, output: "200 0.1"))).ms, nil)
        XCTAssertTrue(Probes.discordArgs(proxyPort: nil, doh: true).contains("%{http_code} %{time_appconnect} %{time_starttransfer}"))
    }

    func testDirectProbeResolvesOverDoH() {
        let args = Probes.discordArgs(proxyPort: nil, doh: true)
        XCTAssertEqual(args.firstIndex(of: "--doh-url").map { args[$0 + 1] }, "https://1.1.1.1/dns-query")
        XCTAssertFalse(args.contains("-x"))
        XCTAssertFalse(Probes.discordArgs(proxyPort: nil, doh: false).contains("--doh-url"))
    }

    /// In DPI mode the probe takes Discord's path: through the local proxy.
    func testDPIProbeGoesThroughTheProxy() {
        let args = Probes.discordArgs(proxyPort: 51234, doh: true)
        XCTAssertEqual(args.firstIndex(of: "-x").map { args[$0 + 1] }, "http://127.0.0.1:51234")
        XCTAssertFalse(args.contains("--doh-url"), "the proxy resolves the name itself")
    }

    func testDoHSupportFollowsTheCurlVersion() {
        XCTAssertTrue(Probes.supportsDoH(versionOutput: "curl 8.7.1 (x86_64-apple-darwin26.0) libcurl/8.7.1"))
        XCTAssertTrue(Probes.supportsDoH(versionOutput: "curl 7.62.0 (x86_64-apple-darwin)"))
        XCTAssertFalse(Probes.supportsDoH(versionOutput: "curl 7.54.0 (x86_64-apple-darwin)"))
        XCTAssertFalse(Probes.supportsDoH(versionOutput: ""))
    }

    struct Canned: CommandRunner {
        let result: CommandResult
        init(_ result: CommandResult) { self.result = result }
        func run(_ tool: String, _ args: [String], timeout: TimeInterval) -> CommandResult { result }
    }
}

/// The 2 s tick's cheaper reads.
final class TickCostTests: XCTestCase {

    let table = """
    Routing tables

    Internet:
    Destination        Gateway            Flags               Netif Expire
    default            192.168.1.1        UGScg                 en0
    0/1                10.2.0.2           UGSc                utun5
    127                127.0.0.1          UCS                   lo0
    128.0/1            10.2.0.2           UGSc                utun5
    162.159.128/18     link#21            USc                 utun5
    162.159.192/24     link#21            USc                 utun10
    192.168.1          link#11            UCS                   en0      !

    Internet6:
    Destination                             Gateway                                 Flags               Netif Expire
    default                                 fe80::%utun0                            UGcIg               utun0
    ::/1                                    fe80::%utun5                            UGSc                utun5
    8000::/1                                fe80::%utun5                            UGSc                utun5
    fe80::%lo0/64                           fe80::1%lo0                             UcI                   lo0
    """

    func testNetstatPrefixesMatchRecordedCIDRsExactly() {
        let entries = RouteManager.parseRouteTable(table)
        XCTAssertTrue(RouteManager.routeExists("162.159.128.0/18", iface: "utun5", in: entries))
        XCTAssertTrue(RouteManager.routeExists("0.0.0.0/1", iface: "utun5", in: entries))
        XCTAssertTrue(RouteManager.routeExists("128.0.0.0/1", iface: "utun5", in: entries))
        XCTAssertTrue(RouteManager.routeExists("::/1", iface: "utun5", in: entries))
        XCTAssertTrue(RouteManager.routeExists("8000::/1", iface: "utun5", in: entries))
        XCTAssertTrue(RouteManager.routeExists("192.168.1.0/24", iface: nil, in: entries))
        // utun1 must not match utun10, and a covering route is not the prefix.
        XCTAssertFalse(RouteManager.routeExists("162.159.192.0/24", iface: "utun1", in: entries))
        XCTAssertFalse(RouteManager.routeExists("162.159.0.0/16", iface: nil, in: entries))
        XCTAssertFalse(RouteManager.routeExists("not a cidr", iface: nil, in: entries))
    }

    /// One table read per tick, whatever the number of recorded prefixes.
    func testLocalReportReadsTheTableOnceAndCachesDNS() throws {
        let dir = NSTemporaryDirectory() + "menfez-tick-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/route-state.json"
        XCTAssertTrue(RouteStateStore.save(
            RouteState(mode: "all", iface: "utun5", routes: RouteManager.ranges(for: .all),
                       hosts: [], gateway: "192.168.1.1", profile: "p", generation: 1),
            path: path))

        let runner = SpawnBudgetTests.Counter()
        let cache = DNSInfoCache()
        _ = ReportBuilder().buildLocal(statePath: path, dnsCache: cache, using: runner)
        let first = runner.calls
        XCTAssertEqual(first.filter { $0.tool == "netstat" }.count, 1)
        XCTAssertEqual(first.filter { $0.tool == "route" }.count, 1, "only `route -n get default`")
        XCTAssertEqual(first.filter { $0.tool == "networksetup" }.count, 2)

        _ = ReportBuilder().buildLocal(statePath: path, dnsCache: cache, using: runner)
        let second = runner.calls.dropFirst(first.count)
        XCTAssertEqual(second.filter { $0.tool == "networksetup" }.count, 0, "cached")
        XCTAssertEqual(first.filter { $0.tool == "ipconfig" }.count, 1)
        XCTAssertEqual(second.filter { $0.tool == "ipconfig" }.count, 0, "local address cached too")

        // A DNS action invalidates: the very next tick reads the new resolvers.
        cache.invalidate()
        _ = ReportBuilder().buildLocal(statePath: path, dnsCache: cache, using: runner)
        XCTAssertEqual(runner.calls.dropFirst(first.count + second.count)
            .filter { $0.tool == "networksetup" }.count, 2)
    }

    /// The app's tick: with a warm cache and an in-process interface check it
    /// starts only `wg show interfaces` and `route -n get default`.
    func testWarmTickSpawnsTwoCommands() {
        let dir = NSTemporaryDirectory() + "menfez-tick-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/route-state.json"
        let runner = SpawnBudgetTests.Counter()
        let cache = DNSInfoCache()
        var asked: [String] = []
        let first = ReportBuilder().buildLocal(statePath: path, dnsCache: cache,
                                               interfaceExists: { asked.append($0); return true }, using: runner)
        XCTAssertEqual(first.localIP, "192.168.1.2")
        let before = runner.calls.count
        let second = ReportBuilder().buildLocal(statePath: path, dnsCache: cache,
                                                interfaceExists: { asked.append($0); return true }, using: runner)
        XCTAssertEqual(runner.calls.dropFirst(before).map(\.tool), ["wg", "route"])
        XCTAssertEqual(second.localIP, "192.168.1.2", "from the cache")
        XCTAssertEqual(second.health.code, .unknown, "interface known, handshake not read")
        XCTAssertEqual(asked, ["utun9", "utun9"])
        XCTAssertFalse(runner.calls.contains { $0.tool == "ifconfig" })
    }

    func testDNSCacheExpiresAndFollowsTheInterface() {
        final class Clock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 0) }
        let clock = Clock()
        let cache = DNSInfoCache(ttl: 30, now: { clock.t })
        cache.store(.init(service: "Wi-Fi", servers: ["1.1.1.1"]), interface: "en0")
        XCTAssertEqual(cache.lookup(interface: "en0")?.servers, ["1.1.1.1"])
        XCTAssertNil(cache.lookup(interface: "en7"), "a different primary interface")
        clock.t += 31
        XCTAssertNil(cache.lookup(interface: "en0"), "expired")
    }

    func testCarryingTrafficIsReadFromTheReport() {
        let tunnel = HelperTunnel(client: HelperClient(helper: "/nonexistent"),
                                  interfaces: { XCTFail("must not re-list interfaces"); return [] })
        var report = Report()
        report.tunnel = "utun5"
        report.mode = "discord"
        report.routes = [RouteInfo(cidr: "162.159.128.0/18", present: true)]
        XCTAssertTrue(tunnel.isCarryingTraffic(seen: report))
        report.mode = "off"
        XCTAssertFalse(tunnel.isCarryingTraffic(seen: report))
        report.mode = "discord"
        report.tunnel = nil
        XCTAssertFalse(tunnel.isCarryingTraffic(seen: report))
        XCTAssertFalse(NoTunnel().isCarryingTraffic(seen: report))
    }
}
