import XCTest
@testable import MenfezCore

/// DoH provider choice and "route DNS through tunnel".
final class DNSRoutingTests: XCTestCase {

    private var root = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("menfez-dnsrouting-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if !root.isEmpty { try? FileManager.default.removeItem(atPath: root) }
        try super.tearDownWithError()
    }

    private func defaults() throws -> UserDefaults {
        let name = "menfez-test-\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { store.removePersistentDomain(forName: name) }
        return store
    }

    // MARK: - Provider

    func testProviderEndpointsAreIPLiterals() {
        XCTAssertEqual(DoHProvider.cloudflare.endpoints,
                       ["https://1.1.1.1/dns-query", "https://1.0.0.1/dns-query"])
        XCTAssertEqual(DoHProvider.google.endpoints,
                       ["https://8.8.8.8/dns-query", "https://8.8.4.4/dns-query"])
        XCTAssertEqual(DoHProvider.quad9.endpoints,
                       ["https://9.9.9.9/dns-query", "https://149.112.112.112/dns-query"])
        XCTAssertEqual(DoHProvider.adguard.endpoints,
                       ["https://94.140.14.14/dns-query", "https://94.140.15.15/dns-query"])
        for provider in DoHProvider.allCases {
            XCTAssertEqual(provider.addresses.count, 2, provider.name)
            for address in provider.addresses {
                XCTAssertNotNil(Validate.ipAddress(address), address)
            }
        }
    }

    func testProviderPersistsAndDefaultsToCloudflare() throws {
        let store = try defaults()
        XCTAssertEqual(DoHProvider.current(store), .cloudflare)
        store.set(DoHProvider.quad9.rawValue, forKey: DoHProvider.defaultsKey)
        XCTAssertEqual(DoHProvider.current(store), .quad9)
        store.set("bogus", forKey: DoHProvider.defaultsKey)
        XCTAssertEqual(DoHProvider.current(store), .cloudflare)
    }

    func testTunnelDNSSettingDefaultsOnAndPersists() throws {
        let store = try defaults()
        XCTAssertTrue(DNSManager.routesDNSThroughTunnel(store))
        store.set(false, forKey: DNSManager.tunnelDNSKey)
        XCTAssertFalse(DNSManager.routesDNSThroughTunnel(store))
    }

    // MARK: - Wire format

    func testQueryMessageIsRFC8484() throws {
        let message = try XCTUnwrap(DoHResolver.message(for: "discord.com"))
        XCTAssertEqual([UInt8](message), [0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0,
                                          7] + Array("discord".utf8) + [3] + Array("com".utf8)
                                          + [0, 0, 1, 0, 1])
        XCTAssertNil(DoHResolver.message(for: ""))
        XCTAssertNil(DoHResolver.message(for: "a..b"))
        XCTAssertNil(DoHResolver.message(for: String(repeating: "x", count: 64) + ".com"))
    }

    // MARK: - Resolver routes

    func testHelperArgumentAcceptsOnlyPublicIPv4() {
        XCTAssertEqual(RouteManager.dnsRoutes(argument: "195.175.39.39,8.8.8.8,8.8.8.8"),
                       ["195.175.39.39/32", "8.8.8.8/32"])
        for bad in ["", "192.168.1.1", "10.0.0.1", "127.0.0.1", "169.254.1.1", "100.64.0.1",
                    "8.8.8.8,192.168.1.1", "8.8.8.8/24", "-net", "2001:4860::8888",
                    "08.8.8.8", "8.8.8.8 ", "1.1.1.1,", String(repeating: "1.1.1.1,", count: 8) + "1.1.1.1"] {
            XCTAssertNil(RouteManager.dnsRoutes(argument: bad), bad)
        }
    }

    func testPrivateResolversAreSkipped() {
        let servers = ["192.168.1.1", "195.175.39.39", "fe80::1", "127.0.0.1", "8.8.8.8", "8.8.8.8"]
        XCTAssertEqual(RouteManager.publicResolvers(servers), ["195.175.39.39", "8.8.8.8"])
        XCTAssertEqual(RouteManager.dnsRouteArgs(enabled: true, resolvers: servers),
                       ["--dns-routes", "195.175.39.39,8.8.8.8"])
        XCTAssertEqual(RouteManager.dnsRouteArgs(enabled: false, resolvers: servers), [])
        XCTAssertEqual(RouteManager.dnsRouteArgs(enabled: true, resolvers: ["192.168.1.1"]), [])
    }

    func testScutilParse() {
        let text = """
        DNS configuration

        resolver #1
          search domain[0] : lan
          nameserver[0] : 192.168.1.1
          nameserver[1] : 195.175.39.39
          if_index : 15 (en0)

        resolver #2
          domain   : local
          options  : mdns

        DNS configuration (for scoped queries)

        resolver #1
          nameserver[0] : 192.168.1.1
          nameserver[1] : 2001:4860:4860::8888
        """
        XCTAssertEqual(DNSManager.resolvers(scutil: text),
                       ["192.168.1.1", "195.175.39.39", "2001:4860:4860::8888"])
    }

    func testWantedAddsResolversInDiscordModeOnly() {
        var manager = RouteManager(settle: 0, statePath: (root as NSString).appendingPathComponent("s.json"))
        manager.dnsRoutes = ["8.8.8.8/32"]
        XCTAssertEqual(manager.wanted(.discord), RouteManager.discordRanges + ["8.8.8.8/32"])
        XCTAssertEqual(manager.wanted(.all), RouteManager.ranges(for: .all))
        XCTAssertEqual(manager.wanted(.off), [])
    }

    // MARK: - Install and teardown

    private func makeManager(_ statePath: String, added: @escaping (String) -> Void,
                             removed: @escaping (String) -> Void) -> RouteManager {
        var manager = RouteManager(settle: 0, statePath: statePath)
        manager.probeInterfaces = { ["utun9"] }
        manager.probeHealth = { _ in (true, "ok") }
        manager.probeEndpoint = { _ in "203.0.113.69" }
        manager.probeGateway = { "192.168.1.1" }
        manager.probeHostGateway = { _ in "192.168.1.1" }
        manager.probeBaseline = { _ in RouteManager.Baseline(epoch: 1_000, rx: 0, tx: 0) }
        manager.probeProgress = { _, _, _ in (true, "moved") }
        manager.addHost = { _, _ in RouteManager.Mutation(ok: true, detail: "added") }
        manager.addNet = { cidr, _ in added(cidr); return RouteManager.Mutation(ok: true, detail: "added") }
        manager.deleteNet = { removed($0); return true }
        manager.deleteHost = { _ in true }
        return manager
    }

    func testResolverRoutesAreInstalledRecordedAndRemovedOnDown() {
        let statePath = (root as NSString).appendingPathComponent("route-state.json")
        var added: [String] = []
        var removed: [String] = []
        var manager = makeManager(statePath, added: { added.append($0) }, removed: { removed.append($0) })
        manager.dnsRoutes = ["195.175.39.39/32"]

        let result = manager.apply(mode: .discord, iface: "utun9", gateway: "192.168.1.1",
                                   endpoint: "203.0.113.69", revertAfter: nil)
        XCTAssertTrue(result.ok, "\(result.error ?? "")")
        XCTAssertEqual(added, RouteManager.discordRanges + ["195.175.39.39/32"])
        XCTAssertTrue(RouteStateStore.load(path: statePath).routes.contains("195.175.39.39/32"))

        // `down` takes no setting: the record alone removes the resolver route.
        let downer = makeManager(statePath, added: { _ in }, removed: { removed.append($0) })
        XCTAssertTrue(downer.down().ok)
        XCTAssertEqual(Set(removed), Set(RouteManager.discordRanges + ["195.175.39.39/32"]))
        XCTAssertTrue(RouteStateStore.load(path: statePath).routes.isEmpty)
    }

    func testModeChangeDropsResolverRoutes() {
        let statePath = (root as NSString).appendingPathComponent("route-state.json")
        XCTAssertTrue(RouteStateStore.save(
            RouteState(mode: "discord", iface: "utun9",
                       routes: RouteManager.discordRanges + ["195.175.39.39/32"],
                       hosts: ["203.0.113.69"], gateway: "192.168.1.1", generation: 1),
            path: statePath))
        var removed: [String] = []
        // Toggle turned off: the same mode with no resolvers removes only the /32.
        let manager = makeManager(statePath, added: { _ in }, removed: { removed.append($0) })
        XCTAssertTrue(manager.changeMode(to: .discord).ok)
        XCTAssertEqual(removed, ["195.175.39.39/32"])
        XCTAssertEqual(Set(RouteStateStore.load(path: statePath).routes), Set(RouteManager.discordRanges))
    }
}
