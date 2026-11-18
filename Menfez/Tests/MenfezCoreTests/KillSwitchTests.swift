import XCTest
@testable import MenfezCore

/// The kill switch's pf rules and the plumbing around them. The rules go to
/// pfctl as root, so what they allow, what they refuse to build, and that pf
/// parses them are all pinned here.
final class KillSwitchTests: XCTestCase {

    final class Recorder: CommandRunner, @unchecked Sendable {
        var lines: [String] = []
        func run(_ tool: String, _ args: [String], timeout: TimeInterval) -> CommandResult {
            lines.append(([tool] + args).joined(separator: " "))
            return CommandResult(status: 0, output: "")
        }
    }

    func testWholeInternetKeepsLoopbackTunnelEndpointDHCPAndLANOpenAndBlocksTheRest() throws {
        let text = try XCTUnwrap(KillSwitch.rules(scope: .all, iface: "utun4", endpoints: ["203.0.113.7"]))
        let lines = text.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") }
        XCTAssertEqual(lines.first, "pass out quick on lo0 all")
        XCTAssertTrue(lines.contains("pass out quick on utun4 all"))
        XCTAssertTrue(lines.contains("pass out quick inet to 203.0.113.7"))
        XCTAssertTrue(lines.contains("pass out quick inet proto udp from any port 68 to any port 67"))
        XCTAssertEqual(lines.last, "block drop out quick all", "everything else is dropped, last")
        // DNS is blocked before the LAN pass: a LAN resolver is the ISP's.
        let dns = try XCTUnwrap(lines.firstIndex(of: "block drop out quick proto { tcp udp } to any port 53"))
        let lan = try XCTUnwrap(lines.firstIndex { $0.contains("192.168.0.0/16") })
        let endpoint = try XCTUnwrap(lines.firstIndex(of: "pass out quick inet to 203.0.113.7"))
        XCTAssertLessThan(endpoint, dns, "a server on port 53 must still be reachable")
        XCTAssertLessThan(dns, lan)
        XCTAssertTrue(text.contains("killswitch off"), "the file says how to remove it")
    }

    func testIPv6EndpointGetsAnInet6Pass() throws {
        let text = try XCTUnwrap(KillSwitch.rules(scope: .all, iface: "utun4", endpoints: ["2001:db8::7"]))
        XCTAssertTrue(text.contains("pass out quick inet6 to 2001:db8::7\n"))
    }

    func testDiscordOnlyBlocksDiscordOutsideTheTunnelAndNothingElse() throws {
        let text = try XCTUnwrap(KillSwitch.rules(scope: .discord, iface: "utun9", endpoints: []))
        let rules = text.split(separator: "\n").filter { !$0.hasPrefix("#") }
        XCTAssertEqual(rules, ["block drop out quick on ! utun9 inet to { 162.159.128.0/18, 162.159.192.0/24 }"])
    }

    func testRefusesToBuildFromAnythingThatIsNotWhatItClaims() {
        for iface in ["en0", "utun", "utun1 all", "utun1;pass", "lo0", "utun12345"] {
            XCTAssertNil(KillSwitch.rules(scope: .all, iface: iface, endpoints: ["203.0.113.7"]), iface)
        }
        for endpoint in ["vpn.example.com", "203.0.113.7 port 53", "203.0.113.7/0", "", "any"] {
            XCTAssertNil(KillSwitch.rules(scope: .all, iface: "utun3", endpoints: [endpoint]), endpoint)
        }
        XCTAssertNil(KillSwitch.rules(scope: .all, iface: "utun3", endpoints: []), "no endpoint, no rules")
        XCTAssertNil(KillSwitch.rules(scope: .off, iface: "utun3", endpoints: ["203.0.113.7"]))
        XCTAssertNil(KillSwitch.rules(scope: .updates, iface: "utun3", endpoints: ["203.0.113.7"]))
    }

    /// `pfctl -n` parses without loading and needs no root.
    func testPfParsesTheGeneratedRules() throws {
        guard FileManager.default.isExecutableFile(atPath: "/sbin/pfctl") else { throw XCTSkip("no pfctl") }
        let cases: [(Mode, [String])] = [(.all, ["203.0.113.7"]), (.all, ["2001:db8::7"]), (.discord, [])]
        for (scope, endpoints) in cases {
            let text = try XCTUnwrap(KillSwitch.rules(scope: scope, iface: "utun3", endpoints: endpoints))
            let file = NSTemporaryDirectory() + "menfez-ks-\(UUID().uuidString).conf"
            try text.write(toFile: file, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(atPath: file) }
            let result = Shell.run("pfctl", ["-a", KillSwitch.anchor, "-n", "-f", file], timeout: 10)
            XCTAssertTrue(result.ok, "\(scope): \(result.output)")
        }
    }

    func testTokenFromEnableOutput() {
        XCTAssertEqual(KillSwitch.token(enableOutput: "No ALTQ support in kernel\npf enabled\nToken : 6913424087135727249\n"),
                       "6913424087135727249")
        XCTAssertNil(KillSwitch.token(enableOutput: "pf enabled\n"))
        XCTAssertNil(KillSwitch.token(enableOutput: "Token : 12;rm\n"))
    }

    func testMainRulesetMustReachTheAppleAnchor() {
        XCTAssertTrue(KillSwitch.mainRulesetReachesAnchor("scrub-anchor \"com.apple/*\" all fragment reassemble\nanchor \"com.apple/*\" all\n"))
        XCTAssertFalse(KillSwitch.mainRulesetReachesAnchor(""))
        XCTAssertFalse(KillSwitch.mainRulesetReachesAnchor("scrub-anchor \"com.apple/*\" all\n"))
    }

    func testOffFlushesOnlyOurAnchorAndReleasesTheToken() {
        let runner = Recorder()
        let result = KillSwitch.off(using: runner, token: "42")
        XCTAssertTrue(result.ok)
        XCTAssertEqual(runner.lines, ["pfctl -a com.apple/250.Menfez -F all", "pfctl -X 42"])
    }

    func testStateRoundTripsAndAMissingFileMeansOff() throws {
        XCTAssertNil(KillSwitch.load(path: "/nonexistent/killswitch.json"))
        let state = KillSwitch.State(scope: "all", iface: "utun3", endpoints: ["203.0.113.7"], token: "9")
        let file = NSTemporaryDirectory() + "menfez-ks-\(UUID().uuidString).json"
        try JSON.encode(state).write(toFile: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: file) }
        XCTAssertEqual(KillSwitch.load(path: file), state)
    }

    /// A 1.0.2/1.0.3 helper (version 2) does not know `killswitch`: the app
    /// must offer the update and keep the switch hidden.
    func testOlderHelperIsOfferedTheUpdate() {
        XCTAssertGreaterThanOrEqual(HelperVersion.current, 3)
        XCTAssertTrue(HelperVersion.needsUpdate(installed: 2))
    }
}
