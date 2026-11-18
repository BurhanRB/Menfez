import XCTest
@testable import MenfezCore

/// Discord + chosen sites (1.0.5): what the user may type, what the helper
/// accepts as root, the refresh rule, the kill switch, and the saved list.
final class SiteRoutesTests: XCTestCase {

    // MARK: The user's entries

    func testNormalizeAcceptsWhatPeoplePaste() {
        XCTAssertEqual(SiteRoutes.normalize("Example.COM"), "example.com")
        XCTAssertEqual(SiteRoutes.normalize("  https://www.example.com/a/b?c#d "), "www.example.com")
        XCTAssertEqual(SiteRoutes.normalize("http://sub.example.co.uk."), "sub.example.co.uk")
        XCTAssertEqual(SiteRoutes.normalize("xn--mnchen-3ya.de"), "xn--mnchen-3ya.de")
        XCTAssertEqual(SiteRoutes.normalize("93.184.216.34"), "93.184.216.34")
        XCTAssertEqual(SiteRoutes.normalize("2606:4700:0:0::1111"), "2606:4700::1111")
    }

    func testNormalizeRefusesNonSites() {
        for bad in ["", "localhost", "example", "-a.com", "a-.com", "exa mple.com", "a..com",
                    "1.2.3", "1.2.3.4.5", "192.168.1.1", "10.0.0.1", "127.0.0.1", "100.64.0.1",
                    "fd00::1", "fe80::1", "::1", "::ffff:8.8.8.8", "ff02::1", "örnek.com",
                    "a.com;rm -rf /", "$(id).com", String(repeating: "a", count: 64) + ".com",
                    String(repeating: "a.", count: 127) + "com"] {
            XCTAssertNil(SiteRoutes.normalize(bad), bad)
        }
    }

    func testLookupNamesAddTheWwwTwinOnly() {
        XCTAssertEqual(SiteRoutes.lookupNames("example.com"), ["example.com", "www.example.com"])
        XCTAssertEqual(SiteRoutes.lookupNames("www.example.com"), ["www.example.com"])
        XCTAssertEqual(SiteRoutes.lookupNames("1.1.1.1"), [])
    }

    // MARK: Addresses

    func testAddressesArePublicUniqueAndCapped() {
        XCTAssertEqual(SiteRoutes.addresses([["1.1.1.1", "10.0.0.1"], ["1.1.1.1", "2606:4700::1111", "fd00::1"]]),
                       ["1.1.1.1", "2606:4700::1111"])
        let many = (0..<300).map { "8.8.\($0 / 250).\($0 % 250 + 1)" }
        XCTAssertEqual(SiteRoutes.addresses([many]).count, SiteRoutes.maxRoutes)
        XCTAssertEqual(SiteRoutes.prefix("1.1.1.1"), "1.1.1.1/32")
        XCTAssertEqual(SiteRoutes.prefix("2606:4700::1111"), "2606:4700::1111/128")
    }

    func testMergeKeepsThePreviousSetOnce() {
        XCTAssertEqual(SiteRoutes.merge(new: ["1.1.1.1", "2.2.2.2"], kept: ["2.2.2.2", "3.3.3.3"]),
                       ["1.1.1.1", "2.2.2.2", "3.3.3.3"])
        XCTAssertEqual(SiteRoutes.argument([]), [])
        XCTAssertEqual(SiteRoutes.argument(["1.1.1.1", "2.2.2.2"]), ["--site-routes", "1.1.1.1,2.2.2.2"])
    }

    func testResolveCountsEachEntryAndAsksBothFamilies() {
        let asked = Asked()
        let lookup: SiteRoutes.Lookup = { name, ipv6, done in
            asked.add("\(name)|\(ipv6)")
            switch (name, ipv6) {
            case ("example.com", false): done(["93.184.216.34"])
            case ("www.example.com", false): done(["93.184.216.34", "93.184.216.35"])
            case ("example.com", true): done(["2606:2800:220:1::1"])
            case ("poisoned.com", false): done(["10.10.10.10"])   // a private answer is not a route
            default: done(nil)
            }
        }
        let found = SiteRoutes.resolve(["example.com", "poisoned.com", "8.8.8.8"], lookup: lookup)
        XCTAssertEqual(found.counts, ["example.com": 3, "poisoned.com": 0, "8.8.8.8": 1])
        XCTAssertEqual(Set(found.addresses),
                       ["93.184.216.34", "93.184.216.35", "2606:2800:220:1::1", "8.8.8.8"])
        XCTAssertTrue(asked.list.contains("www.example.com|true"))
        XCTAssertFalse(asked.list.contains { $0.hasPrefix("8.8.8.8") }, "an address is not looked up")
    }

    // MARK: Refresh rule

    func testRefreshNeedsTwoAgreeingChecksAndCarriesThePreviousSet() {
        var refresh = SiteRoutes.Refresh()
        refresh.didSend(["1.1.1.1"])
        XCTAssertNil(refresh.observe(resolved: ["1.1.1.1"], live: ["1.1.1.1"]), "nothing moved")
        XCTAssertNil(refresh.observe(resolved: ["2.2.2.2"], live: ["1.1.1.1"]), "first sighting waits")
        XCTAssertEqual(refresh.observe(resolved: ["2.2.2.2"], live: ["1.1.1.1"]), ["2.2.2.2", "1.1.1.1"])
        XCTAssertEqual(refresh.sent, ["2.2.2.2"])
        XCTAssertNil(refresh.observe(resolved: ["2.2.2.2"], live: ["2.2.2.2", "1.1.1.1"]))
        XCTAssertNil(refresh.observe(resolved: ["3.3.3.3"], live: ["2.2.2.2"]))
        XCTAssertNil(refresh.observe(resolved: ["4.4.4.4"], live: ["2.2.2.2"]), "a flapping answer waits")
        XCTAssertNil(refresh.observe(resolved: [], live: ["2.2.2.2"]), "a failed lookup keeps the routes")
        XCTAssertNil(refresh.observe(resolved: [], live: ["2.2.2.2"]))
    }

    // MARK: The helper side (root)

    func testHelperArgumentAcceptsOnlyPublicAddresses() {
        XCTAssertEqual(RouteManager.siteRoutes(argument: "1.1.1.1,2606:4700::1111,1.1.1.1"),
                       ["1.1.1.1/32", "2606:4700::1111/128"])
        for bad in ["", "1.1.1.1,", "1.1.1.1,10.0.0.1", "example.com", "1.1.1.1/24", "fd00::1",
                    "1.1.1.1;reboot", "0.0.0.0", "255.255.255.255", "::", "-x"] {
            XCTAssertNil(RouteManager.siteRoutes(argument: bad), bad)
        }
        let tooMany = (0...SiteRoutes.maxRoutes).map { "8.8.\($0 / 250).\($0 % 250 + 1)" }
        XCTAssertNil(RouteManager.siteRoutes(argument: tooMany.joined(separator: ",")))
    }

    func testSitesJoinDiscordModeOnlyAndNeverTheEndpoint() {
        var manager = RouteManager()
        manager.dnsRoutes = ["8.8.8.8/32"]
        manager.siteRoutes = ["93.184.216.34/32", "185.65.134.10/32", "2606:2800:220:1::1/128", "8.8.8.8/32"]
        XCTAssertEqual(manager.wanted(.discord, endpoint: "185.65.134.10"),
                       RouteManager.discordRanges + ["8.8.8.8/32", "93.184.216.34/32", "2606:2800:220:1::1/128"])
        XCTAssertEqual(manager.wanted(.all, endpoint: "185.65.134.10"), RouteManager.ranges(for: .all))
        XCTAssertFalse(manager.wanted(.updates).contains("93.184.216.34/32"))
        XCTAssertEqual(manager.liveSites(.discord, ["93.184.216.34/32", "8.8.8.8/32"]),
                       ["93.184.216.34/32", "8.8.8.8/32"])
        XCTAssertNil(manager.liveSites(.all, ["93.184.216.34/32"]))
        XCTAssertNil(RouteManager().liveSites(.discord, RouteManager.discordRanges))
    }

    func testKillSwitchBlocksTheSitesWithDiscord() throws {
        let text = try XCTUnwrap(KillSwitch.rules(scope: .discord, iface: "utun4", endpoints: ["185.65.134.10"],
                                                  sites: ["93.184.216.34/32", "2606:2800:220:1::1/128"]))
        XCTAssertTrue(text.contains("block drop out quick on ! utun4 inet to { 162.159.128.0/18, 162.159.192.0/24, 93.184.216.34/32 }"))
        XCTAssertTrue(text.contains("block drop out quick on ! utun4 inet6 to { 2606:2800:220:1::1/128 }"))
        XCTAssertFalse(try XCTUnwrap(KillSwitch.rules(scope: .discord, iface: "utun4", endpoints: []))
            .contains("inet6"), "Discord only is unchanged")
        XCTAssertNil(KillSwitch.rules(scope: .discord, iface: "utun4", endpoints: [],
                                      sites: ["1.2.3.4/32 } pass out all {"]))
    }

    func testRouteStateSitesSurviveTheFileAndOldFilesHaveNone() throws {
        let dir = NSTemporaryDirectory() + "menfez-sites-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/route-state.json"
        XCTAssertTrue(RouteStateStore.save(RouteState(mode: "discord", routes: ["93.184.216.34/32"],
                                                      sites: ["93.184.216.34/32"]), path: path))
        XCTAssertEqual(RouteStateStore.load(path: path).sites, ["93.184.216.34/32"])
        try #"{"mode":"discord","routes":["162.159.128.0/18"],"hosts":[]}"#
            .write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertNil(RouteStateStore.load(path: path).sites, "a 1.0.4 helper's file")
    }

    // MARK: Scope choice

    func testChoiceIsSavedAndRunsInDiscordMode() {
        let suite = "menfez-sites-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        TunnelScope.save(choice: .sites, defaults)
        XCTAssertEqual(TunnelScope.choice(defaults), .sites)
        XCTAssertEqual(TunnelScope.current(defaults), .discord)
        TunnelScope.save(Mode.all, defaults)
        XCTAssertEqual(TunnelScope.choice(defaults), .all)
        defaults.set("junk", forKey: TunnelScope.defaultsKey)
        XCTAssertEqual(TunnelScope.choice(defaults), .discord)
    }

    func testPickerChangeBetweenDiscordAndSitesReRoutes() {
        XCTAssertTrue(TunnelScope.needsReroute(inTunnel: true, routeMode: "discord", from: .discord, to: .sites))
        XCTAssertTrue(TunnelScope.needsReroute(inTunnel: true, routeMode: "discord", from: .sites, to: .discord))
        XCTAssertTrue(TunnelScope.needsReroute(inTunnel: true, routeMode: "discord", from: .discord, to: .all))
        XCTAssertTrue(TunnelScope.needsReroute(inTunnel: true, routeMode: "all", from: .all, to: .sites))
        XCTAssertFalse(TunnelScope.needsReroute(inTunnel: false, routeMode: "discord", from: .discord, to: .sites))
        XCTAssertFalse(TunnelScope.needsReroute(inTunnel: true, routeMode: "updates", from: .discord, to: .sites))
    }

    // MARK: Old helper

    func testHelperBeforeSiteRoutesIsOutdated() {
        XCTAssertGreaterThanOrEqual(HelperVersion.current, 4)
        XCTAssertTrue(HelperVersion.needsUpdate(installed: 3), "a 1.0.4 helper ignores --site-routes")
    }

    // MARK: DoH AAAA

    func testAAAAQueryAndAnswer() throws {
        let message = try XCTUnwrap(DoHResolver.message(for: "example.com", type: 28))
        XCTAssertEqual(Array(message.suffix(4)), [0, 28, 0, 1])
        // Header, one question, one AAAA answer (pointer to the question name).
        var answer: [UInt8] = [0, 0, 0x81, 0x80, 0, 1, 0, 2, 0, 0, 0, 0]
        answer += [7] + Array("example".utf8) + [3] + Array("com".utf8) + [0, 0, 28, 0, 1]
        answer += [0xc0, 12, 0, 28, 0, 1, 0, 0, 0, 60, 0, 16,
                   0x26, 0x06, 0x28, 0x00, 0x02, 0x20, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1]
        answer += [0xc0, 12, 0, 1, 0, 1, 0, 0, 0, 30, 0, 4, 93, 184, 216, 34]
        let v6 = try XCTUnwrap(DoHResolver.parse(Data(answer), type: 28))
        XCTAssertEqual(v6.addresses, ["2606:2800:220:1::1"])
        XCTAssertEqual(v6.ttl, 60)
        XCTAssertEqual(DoHResolver.parse(Data(answer))?.addresses, ["93.184.216.34"], "A stays A")
    }

    // MARK: The saved list

    func testListSavesPrivatelyAndAnUnreadableFileIsKept() throws {
        let dir = NSTemporaryDirectory() + "menfez-sites-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/sites.json"
        XCTAssertEqual(SiteList.load(path: path).list.sites, [])
        XCTAssertTrue(SiteList(sites: ["example.com"]).save(path: path))
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertEqual(SiteList.load(path: path).list.sites, ["example.com"])

        try #"{"version":1,"sites":["Example.com","example.com","10.0.0.1","bad name"]}"#
            .write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(SiteList.load(path: path).list.sites, ["example.com"], "cleaned like the editor")

        try "not json".write(toFile: path, atomically: true, encoding: .utf8)
        let broken = SiteList.load(path: path)
        XCTAssertTrue(broken.recovered)
        XCTAssertEqual(broken.list.sites, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + ".bak"))
    }
}

private final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
    var list: [String] { lock.lock(); defer { lock.unlock() }; return items }
}
