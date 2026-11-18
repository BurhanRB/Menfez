import XCTest
@testable import MenfezCore

/// The leak test's verdicts, one row per check.
final class LeakTestTests: XCTestCase {

    private func line(_ lines: [LeakTest.Line], _ row: LeakTest.Row) -> LeakTest.Line? {
        lines.first { $0.row == row }
    }

    private func healthyAll() -> LeakTest.Input {
        LeakTest.Input(scope: .all, tunnelIface: "utun4", egressIP: "203.0.113.7",
                       endpoint: "203.0.113.7", probeRouteIface: "utun4",
                       resolvers: [("10.64.0.1", "utun4")], hasPublicIPv6: true,
                       ipv6Route: "utun4", killSwitch: true)
    }

    func testTunnelOffIsOneHonestRow() {
        XCTAssertEqual(LeakTest.classify(LeakTest.Input()), [LeakTest.Line(.ip, .warn, "off")])
        XCTAssertEqual(LeakTest.classify(LeakTest.Input(scope: .updates, tunnelIface: "utun4")),
                       [LeakTest.Line(.ip, .warn, "off")])
    }

    func testWholeInternetDoneRightIsAllGreen() {
        let lines = LeakTest.classify(healthyAll())
        XCTAssertEqual(lines.map(\.row), LeakTest.Row.allCases)
        XCTAssertTrue(lines.allSatisfy { $0.level == .ok }, "\(lines)")
        XCTAssertEqual(line(lines, .ip), LeakTest.Line(.ip, .ok, "ip_server", "203.0.113.7"))
    }

    func testExitAddressDifferentFromEndpointIsStillTheTunnel() {
        var input = healthyAll()
        input.egressIP = "198.51.100.9"
        XCTAssertEqual(line(LeakTest.classify(input), .ip), LeakTest.Line(.ip, .ok, "ip_exit", "198.51.100.9"))
    }

    func testTrafficOutsideTheTunnelIsRed() {
        var input = healthyAll()
        input.probeRouteIface = "en0"
        XCTAssertEqual(line(LeakTest.classify(input), .ip)?.level, .bad)
    }

    func testResolverOutsideTheTunnelIsRedInWholeInternetAmberInDiscord() {
        var input = healthyAll()
        input.resolvers = [("10.64.0.1", "utun4"), ("192.168.1.1", "en0")]
        XCTAssertEqual(line(LeakTest.classify(input), .dns), LeakTest.Line(.dns, .bad, "dns_leak", "192.168.1.1"))
        input.scope = .discord
        XCTAssertEqual(line(LeakTest.classify(input), .dns)?.level, .warn)
        XCTAssertEqual(line(LeakTest.classify(input), .dns)?.key, "dns_discord")
    }

    func testLocalResolverCannotBeJudged() {
        var input = healthyAll()
        input.resolvers = [("127.0.0.1", "lo0")]
        XCTAssertEqual(line(LeakTest.classify(input), .dns)?.key, "dns_local")
        input.resolvers = []
        XCTAssertEqual(line(LeakTest.classify(input), .dns)?.key, "dns_unknown")
    }

    func testIPv6() {
        var input = healthyAll()
        input.hasPublicIPv6 = false
        XCTAssertEqual(line(LeakTest.classify(input), .ipv6)?.key, "v6_none")
        input.hasPublicIPv6 = true
        input.ipv6Route = "blocked"
        XCTAssertEqual(line(LeakTest.classify(input), .ipv6)?.key, "v6_blocked")
        input.ipv6Route = nil
        XCTAssertEqual(line(LeakTest.classify(input), .ipv6)?.key, "v6_blocked")
        input.ipv6Route = "en0"
        XCTAssertEqual(line(LeakTest.classify(input), .ipv6)?.level, .bad)
        input.scope = .discord
        XCTAssertEqual(line(LeakTest.classify(input), .ipv6)?.level, .warn)
    }

    func testDiscordOnlyChecksDiscordsRoute() {
        var input = healthyAll()
        input.scope = .discord
        XCTAssertEqual(line(LeakTest.classify(input), .ip), LeakTest.Line(.ip, .ok, "ip_discord"))
        input.probeRouteIface = "en0"
        XCTAssertEqual(line(LeakTest.classify(input), .ip)?.key, "ip_discord_leak")
        XCTAssertEqual(LeakTest.probeAddress(.discord), RouteManager.kickTarget)
    }

    func testKillSwitchRow() {
        var input = healthyAll()
        input.killSwitch = false
        XCTAssertEqual(line(LeakTest.classify(input), .killSwitch), LeakTest.Line(.killSwitch, .warn, "ks_off"))
        input.killSwitch = nil
        XCTAssertEqual(line(LeakTest.classify(input), .killSwitch)?.key, "ks_unknown")
    }

    func testGlobalIPv6AndRouteTarget() {
        XCTAssertTrue(LeakTest.isGlobalIPv6("2a02:ff0::1"))
        for ip in ["fe80::1", "fd00::1", "fc12::1", "::1", "fe80::1%en0", "192.168.1.2"] {
            XCTAssertFalse(LeakTest.isGlobalIPv6(ip), ip)
        }
        XCTAssertEqual(LeakTest.routeTarget(["interface": "lo0", "flags": "<UP,DONE,STATIC,REJECT>"]), "blocked")
        XCTAssertEqual(LeakTest.routeTarget(["interface": "utun4"]), "utun4")
        XCTAssertNil(LeakTest.routeTarget([:]))
    }

    /// Every key the classifier can produce has a sentence in both languages.
    func testEveryKeyIsLocalised() throws {
        let source = try String(contentsOfFile: #filePath.replacingOccurrences(
            of: "Tests/MenfezCoreTests/LeakTestTests.swift", with: "Sources/Menfez/MenfezApp.swift"))
        let keys = ["off", "ip_server", "ip_exit", "ip_tunnel", "ip_leak", "ip_discord", "ip_discord_leak",
                    "dns_tunnel", "dns_leak", "dns_discord", "dns_local", "dns_unknown",
                    "v6_none", "v6_tunnel", "v6_blocked", "v6_leak", "v6_discord",
                    "ks_on", "ks_off", "ks_unknown"]
        for key in keys + LeakTest.Row.allCases.map({ "row_" + $0.rawValue }) {
            XCTAssertEqual(source.components(separatedBy: "\"leak_\(key)\":").count - 1, 2, key)
        }
    }
}
