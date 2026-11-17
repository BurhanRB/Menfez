import XCTest
@testable import MenfezCore

/// The route layer once took this machine offline. These tests pin the rules
/// that prevent it from happening again; they do not touch the network.
final class RouteRulesTests: XCTestCase {

    // MARK: - Mode ranges

    /// `all` must never use 0.0.0.0/0. A /0 collides with the default route and
    /// makes rollback ambiguous; two halves are equivalent and reversible.
    func testAllModeUsesTwoHalvesNotDefault() {
        let ranges = RouteManager.ranges(for: .all)
        XCTAssertEqual(ranges, ["0.0.0.0/1", "128.0.0.0/1", "::/1", "8000::/1"])
        XCTAssertFalse(ranges.contains("0.0.0.0/0"))
        XCTAssertFalse(ranges.contains("::/0"))
    }

    /// Y4: AllowedIPs is ::/0, so `all` must route IPv6 into the tunnel too or
    /// every IPv6 connection leaves in clear. Discord mode stays IPv4-only.
    func testAllModeRoutesBothIPv6Halves() {
        let v6 = RouteManager.ranges(for: .all).filter { $0.contains(":") }
        XCTAssertEqual(v6, ["::/1", "8000::/1"])
        XCTAssertTrue(RouteManager.ranges(for: .discord).allSatisfy { !$0.contains(":") })
    }

    /// `route -net ::/1` is parsed as IPv4; an IPv6 prefix needs `-inet6`.
    func testRouteFamilyArgumentFollowsThePrefix() {
        XCTAssertEqual(RouteManager.familyArgs("::/1"), ["-inet6", "::/1"])
        XCTAssertEqual(RouteManager.familyArgs("8000::/1"), ["-inet6", "8000::/1"])
        XCTAssertEqual(RouteManager.familyArgs("0.0.0.0/1"), ["-net", "0.0.0.0/1"])
    }

    func testDiscordModeUsesCloudflareAllocation() {
        let ranges = RouteManager.ranges(for: .discord)
        XCTAssertEqual(ranges.count, 2)
        XCTAssertTrue(ranges.contains("162.159.128.0/18"))
        XCTAssertTrue(ranges.contains("162.159.192.0/24"))
    }

    func testOffModeHasNoRoutes() {
        XCTAssertTrue(RouteManager.ranges(for: .off).isEmpty)
    }

    /// Whatever the mode, an endpoint pin must exist before these ranges are
    /// applied. In `all` mode the union of the two halves is the whole IPv4
    /// space, so the endpoint is necessarily swallowed — which is exactly the
    /// failure that was observed before the pin was introduced.
    func testAllModeRangesSwallowTheEndpoint() {
        // 203.0.113.69 is a documentation address (RFC 5737) standing in for a VPN endpoint.
        let endpoint = "203.0.113.69"
        let covered = RouteManager.ranges(for: .all).contains {
            cidrCovers($0, address: endpoint)
        }
        XCTAssertTrue(covered,
                      "the union of the all-mode halves must cover every IPv4 address")
    }

    func testDiscordRangesDoNotCoverAnArbitraryProtonEndpoint() {
        // Sanity check in the other direction: in discord mode the endpoint is
        // not inside the routed set, so the pin matters less but is still added
        // for uniformity. This documents the difference between the modes.
        XCTAssertFalse(cidrCovers("162.159.128.0/18", address: "203.0.113.69"))
    }

    // MARK: - Mode parsing

    func testModeRoundTripsThroughRawValue() {
        for mode in Mode.allCases {
            XCTAssertEqual(Mode(rawValue: mode.rawValue), mode)
        }
    }

    func testUnknownModeDoesNotSilentlyBecomeDiscord() {
        // The CLI falls back to .discord for a missing --mode; an explicit
        // unknown value must not be treated as valid.
        XCTAssertNil(Mode(rawValue: "everything"))
    }

    // MARK: - Health

    func testHealthCodesDecodeFromTheWire() throws {
        let json = """
        {"ok":false,"code":"nohandshake","age_s":null}
        """
        let health = try XCTUnwrap(JSON.decode(Health.self, from: json))
        XCTAssertFalse(health.ok)
        XCTAssertEqual(health.code, .noHandshake)
        XCTAssertNil(health.ageS)
    }

    func testHealthDownIsNotOk() {
        XCTAssertFalse(Health.down.ok)
        XCTAssertEqual(Health.down.code, .down)
    }

    // MARK: - Report decoding

    func testReportDecodesWithMostFieldsMissing() throws {
        // A report from a machine with no tunnel, no network and no profiles.
        // Every optional must survive being absent; the UI renders dashes.
        let json = """
        {"ts":1,"health":{"ok":false,"code":"down"},"mode":"off",
         "routes":[],"hosts":[],"transfer":{"rx":0,"tx":0},"dns":[],
         "discord":{"code":0}}
        """
        let report = try XCTUnwrap(JSON.decode(Report.self, from: json))
        XCTAssertEqual(report.mode, "off")
        XCTAssertNil(report.tunnel)
        XCTAssertNil(report.egressIP)
        XCTAssertNil(report.geo)
        XCTAssertTrue(report.routes.isEmpty)
    }

    func testReportIgnoresAWarningPrintedBeforeTheJSON() throws {
        // wg-quick and curl both like to print progress on stderr. The helper
        // captures both streams, so the decoder must skip anything that is not
        // the JSON object.
        let text = """
        warning: something harmless
        {"ts":2,"health":{"ok":true,"code":"ok","age_s":5},"mode":"discord",
         "routes":[],"hosts":[],"transfer":{"rx":1,"tx":2},"dns":["1.1.1.1"],
         "discord":{"code":200,"ms":150}}
        """
        let report = try XCTUnwrap(JSON.decode(Report.self, from: text))
        XCTAssertEqual(report.mode, "discord")
        XCTAssertEqual(report.discord.code, 200)
        XCTAssertEqual(report.discord.ms, 150)
        XCTAssertEqual(report.dns, ["1.1.1.1"])
    }

    func testActionResultFailureCarriesItsMessage() throws {
        let text = #"{"ok":false,"error":"cannot pin the endpoint","routes":[]}"#
        let result = try XCTUnwrap(JSON.decode(ActionResult.self, from: text))
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.error, "cannot pin the endpoint")
    }

    // MARK: - Shell

    func testShellResolvesOnlyAbsoluteExecutables() {
        // `route` lives in /sbin, `wg` only in Homebrew; both must resolve to
        // an absolute path regardless of the caller's PATH.
        XCTAssertTrue(Shell.resolve("route").hasPrefix("/"))
        XCTAssertTrue(Shell.resolve("ifconfig").hasPrefix("/"))
    }

    func testShellReportsMissingToolWithoutThrowing() {
        let result = Shell.run("/nonexistent/menfez-tool", ["--version"], timeout: 5)
        XCTAssertFalse(result.ok)
        XCTAssertFalse(result.timedOut)
    }

    func testShellEnforcesTimeout() {
        // A tool that sleeps forever must be killed, not waited on.
        let start = Date()
        let result = Shell.run("/bin/sleep", ["5"], timeout: 0.5)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.ok)
        XCTAssertLessThan(elapsed, 3.0, "timeout was not enforced promptly")
    }

    // MARK: - Helpers

    /// True when `cidr` contains `address`. IPv4 only; the tests never need v6.
    private func cidrCovers(_ cidr: String, address: String) -> Bool {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2,
              let prefix = Int(parts[1]),
              let network = ipv4ToUInt32(String(parts[0])),
              let host = ipv4ToUInt32(address) else { return false }
        let mask: UInt32 = prefix == 0 ? 0 : ~((1 << (32 - prefix)) - 1)
        return (network & mask) == (host & mask)
    }

    private func ipv4ToUInt32(_ text: String) -> UInt32? {
        let octets = text.split(separator: ".").compactMap { UInt32($0) }
        guard octets.count == 4, octets.allSatisfy({ $0 <= 255 }) else { return nil }
        return (octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3]
    }
}
