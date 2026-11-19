import XCTest
@testable import MenfezCore

/// Discord only / Whole internet: the stored choice, when a switch re-routes,
/// what each scope routes (DNS and IPv6 included) and the resolver hand-over.
final class TunnelScopeTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        suite = "menfez-scope-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    // MARK: Persistence

    func testModeRowFollowsChosenSites() {
        XCTAssertEqual(TunnelScope.rowKey(routeMode: "discord", choice: .sites), "sites")
        XCTAssertEqual(TunnelScope.rowKey(routeMode: "discord", choice: .discord), "discord")
        XCTAssertEqual(TunnelScope.rowKey(routeMode: "all", choice: .all), "all")
        // Down or mid-switch: the helper's word wins, never a scope it is not in.
        XCTAssertEqual(TunnelScope.rowKey(routeMode: "off", choice: .sites), "off")
        XCTAssertEqual(TunnelScope.rowKey(routeMode: "all", choice: .sites), "all")
    }

    func testScopeDefaultsToDiscordAndPersists() {
        XCTAssertEqual(TunnelScope.current(defaults), .discord)
        TunnelScope.save(.all, defaults)
        XCTAssertEqual(TunnelScope.current(defaults), .all)
        TunnelScope.save(.discord, defaults)
        XCTAssertEqual(TunnelScope.current(defaults), .discord)
    }

    func testOnlyTheTwoScopesCanBeStored() {
        defaults.set("updates", forKey: TunnelScope.defaultsKey)
        XCTAssertEqual(TunnelScope.current(defaults), .discord)
        TunnelScope.save(.off, defaults)
        XCTAssertEqual(TunnelScope.current(defaults), .discord)
    }

    // MARK: Switching

    func testSwitchReroutesOnlyALiveTunnelInTheOtherScope() {
        XCTAssertTrue(TunnelScope.needsReroute(inTunnel: true, routeMode: "discord", to: .all))
        XCTAssertTrue(TunnelScope.needsReroute(inTunnel: true, routeMode: "all", to: .discord))
        XCTAssertFalse(TunnelScope.needsReroute(inTunnel: true, routeMode: "all", to: .all))
        // Not in Tunnel mode: the choice is only saved for the next start.
        XCTAssertFalse(TunnelScope.needsReroute(inTunnel: false, routeMode: "discord", to: .all))
        // The hybrid updates tunnel and an idle one are not a scope to swap.
        XCTAssertFalse(TunnelScope.needsReroute(inTunnel: true, routeMode: "updates", to: .all))
        XCTAssertFalse(TunnelScope.needsReroute(inTunnel: true, routeMode: "off", to: .all))
    }

    // MARK: Route sets

    func testWholeInternetCoversEveryV4AndV6AddressAndDNSRoutesAreDiscordOnly() {
        var manager = RouteManager()
        manager.dnsRoutes = ["1.1.1.1/32"]
        let all = manager.wanted(.all)
        // IPv6 halves go into the utun: carried with a v6 Address, black-holed
        // without one, never out through the ISP.
        XCTAssertEqual(Set(all), ["0.0.0.0/1", "128.0.0.0/1", "::/1", "8000::/1"])
        XCTAssertFalse(all.contains("1.1.1.1/32"), "the halves already cover the resolvers")

        let discord = manager.wanted(.discord)
        XCTAssertTrue(discord.contains("1.1.1.1/32"))
        XCTAssertFalse(discord.contains("0.0.0.0/1"))
        XCTAssertFalse(discord.contains { $0.contains(":") }, "Discord only leaves IPv6 alone")
    }

    // MARK: Resolvers

    func testProfileDNSWinsOverThePickedResolver() {
        XCTAssertEqual(TunnelScope.tunnelDNS(profileDNS: ["10.2.0.1"], fallback: ["1.1.1.1", "1.0.0.1"]),
                       ["10.2.0.1"])
        XCTAssertEqual(TunnelScope.tunnelDNS(profileDNS: nil, fallback: ["1.1.1.1", "1.0.0.1"]),
                       ["1.1.1.1", "1.0.0.1"])
        XCTAssertEqual(TunnelScope.tunnelDNS(profileDNS: ["junk"], fallback: ["9.9.9.9"]), ["9.9.9.9"])
    }

    func testScannerReadsTheDNSLineAsIPv4Only() {
        let text = """
        [Interface]
        PrivateKey = AAAA
        Address = 10.2.0.2/32
        DNS = 10.2.0.1, 2a07:b944::2:1, corp.example
        [Peer]
        Endpoint = 185.1.1.1:51820
        """
        XCTAssertEqual(WireGuardProfiles.scan(text).dns, ["10.2.0.1"])
        XCTAssertNil(WireGuardProfiles.scan("[Interface]\nAddress = 10.0.0.2/32\n").dns)
    }

    func testTunnelDNSArgumentIsValidated() {
        XCTAssertEqual(TunnelScope.dnsArgument("10.2.0.1"), ["10.2.0.1"])
        XCTAssertEqual(TunnelScope.dnsArgument("1.1.1.1,1.0.0.1"), ["1.1.1.1", "1.0.0.1"])
        XCTAssertNil(TunnelScope.dnsArgument(""))
        XCTAssertNil(TunnelScope.dnsArgument("1.1.1.1,"))
        XCTAssertNil(TunnelScope.dnsArgument("1.1.1.1,-flag"))
        XCTAssertNil(TunnelScope.dnsArgument("1.1.1.1,1.1.1.2,1.1.1.3,1.1.1.4,1.1.1.5"))
    }

    func testDNSStepHoldsTheResolverOnlyInWholeInternet() {
        XCTAssertEqual(TunnelScope.dnsStep(ok: true, mode: "all", stateMode: "all", servers: ["10.2.0.1"]),
                       .takeOver(["10.2.0.1"]))
        // An older app sends no resolvers: leave DNS alone.
        XCTAssertEqual(TunnelScope.dnsStep(ok: true, mode: "all", stateMode: "all", servers: []), .none)
        XCTAssertEqual(TunnelScope.dnsStep(ok: true, mode: "discord", stateMode: "discord", servers: ["1.1.1.1"]),
                       .release)
        XCTAssertEqual(TunnelScope.dnsStep(ok: true, mode: "off", stateMode: "off", servers: []), .release)
        // A stale revert timer reports the live mode: nothing changes.
        XCTAssertEqual(TunnelScope.dnsStep(ok: true, mode: "all", stateMode: "all", servers: []), .none)
        // A failed swap back to Discord left Whole internet in place: keep it.
        XCTAssertEqual(TunnelScope.dnsStep(ok: false, mode: nil, stateMode: "all", servers: []), .none)
        // A failed switch took the tunnel down: give the resolver back.
        XCTAssertEqual(TunnelScope.dnsStep(ok: false, mode: nil, stateMode: "off", servers: ["10.2.0.1"]),
                       .release)
    }

    // MARK: Resolver hand-over (no real networksetup)

    private func manager(_ path: String, current: [String], writes: Box) -> DNSManager {
        var dns = DNSManager()
        dns.statePath = path
        dns.legacyStatePath = nil
        dns.findService = { "Wi-Fi" }
        dns.readServers = { _ in current }
        dns.writeServers = { service, servers in writes.calls.append((service, servers)); return true }
        dns.listServices = { ["Wi-Fi"] }
        return dns
    }

    final class Box: @unchecked Sendable { var calls: [(String, [String])] = [] }

    private func tempPath() -> String {
        NSTemporaryDirectory() + "menfez-scope-dns-" + UUID().uuidString + ".json"
    }

    func testTakeOverThenReleaseRestoresDHCP() {
        let path = tempPath(), writes = Box()
        defer { unlink(path) }
        let dns = manager(path, current: [], writes: writes)
        XCTAssertTrue(dns.takeOverForTunnel(servers: ["10.2.0.1"]).ok)
        XCTAssertEqual(writes.calls.last?.1, ["10.2.0.1"])
        XCTAssertEqual(DNSStateStore.load(path: path).tunnelBefore, [])

        XCTAssertEqual(dns.releaseFromTunnel()?.ok, true)
        XCTAssertEqual(writes.calls.last?.1, [], "back to automatic")
        XCTAssertNil(DNSStateStore.load(path: path).tunnelBefore)
        XCTAssertNil(dns.releaseFromTunnel(), "a second release has nothing to do")
    }

    func testReleaseRestoresTheUsersEarlierPreset() {
        let path = tempPath(), writes = Box()
        defer { unlink(path) }
        let dns = manager(path, current: ["192.168.1.1"], writes: writes)
        XCTAssertTrue(dns.apply(target: "quad9").ok)
        XCTAssertTrue(dns.takeOverForTunnel(servers: ["10.2.0.1"]).ok)
        // A server switch inside Whole internet keeps the first "before".
        XCTAssertTrue(dns.takeOverForTunnel(servers: ["10.8.0.1"]).ok)
        XCTAssertEqual(DNSStateStore.load(path: path).tunnelBefore, ["9.9.9.9", "149.112.112.112"])

        XCTAssertEqual(dns.releaseFromTunnel()?.ok, true)
        XCTAssertEqual(writes.calls.last?.1, ["9.9.9.9", "149.112.112.112"])
        XCTAssertEqual(DNSStateStore.load(path: path).previous["Wi-Fi"], ["192.168.1.1"],
                       "the true original survives the round trip")
    }

    func testAUsersOwnChoiceEndsTheTakeOver() {
        let path = tempPath(), writes = Box()
        defer { unlink(path) }
        let dns = manager(path, current: [], writes: writes)
        XCTAssertTrue(dns.takeOverForTunnel(servers: ["10.2.0.1"]).ok)
        dns.forgetTunnelTakeover()
        XCTAssertNil(dns.releaseFromTunnel())
    }

    // MARK: Card

    func testWholeInternetCardUsesTheRealEgress() {
        let local = Geo(country: "TR", city: "İstanbul", org: nil, ispShort: "Türk Telekom")
        let exit = Geo(country: "NL", city: "Amsterdam", org: nil, ispShort: "Example")
        let server = Geo(country: "NL", city: "Amsterdam", org: nil, ispShort: "Example")
        let whole = CardIdentity.choose(runMode: .tunnel, routeMode: "all",
                                        egressIP: "185.9.9.9", egressGeo: exit,
                                        serverIP: "185.1.1.1", serverGeo: server)
        XCTAssertEqual(whole, CardIdentity(ip: "185.9.9.9", geo: exit, fromServer: false))
        let discord = CardIdentity.choose(runMode: .tunnel, routeMode: "discord",
                                          egressIP: "88.1.1.1", egressGeo: local,
                                          serverIP: "185.1.1.1", serverGeo: server)
        XCTAssertEqual(discord, CardIdentity(ip: "185.1.1.1", geo: server, fromServer: true))
    }
}
