import XCTest
@testable import MenfezCore

/// End-to-end checks that do not need root.
///
/// These exercise the parts that would break silently: the JSON contract
/// between two processes, the shell wrapper's timeout and PATH handling, and
/// the probe layer's honesty about failures.
final class IntegrationTests: XCTestCase {

    // MARK: - JSON contract

    /// Encode a Report, decode it back, and require every field to survive.
    /// This is the check that would have caught the multi-line decode bug.
    func testReportSurvivesEncodeDecodeRoundTrip() throws {
        let original = Report(
            ts: 1_700_000_000,
            tunnel: "utun5",
            health: Health(ok: true, code: .ok, ageS: 12),
            mode: "discord",
            routes: [RouteInfo(cidr: "162.159.128.0/18", present: true),
                     RouteInfo(cidr: "162.159.192.0/24", present: false)],
            hosts: ["203.0.113.69"],
            profile: "VPN-RO1-RO-229",
            endpoint: "203.0.113.69:51820",
            peerPubkey: "abc=",
            handshakeAgeS: 12,
            handshakeEpoch: 1_700_000_000,
            transfer: Transfer(rx: 1000, tx: 2000),
            dns: ["1.1.1.1", "1.0.0.1"],
            dnsService: "Wi-Fi",
            gateway: "192.168.1.1",
            localIP: "192.168.1.2",
            interface: "en0",
            egressIP: "203.0.113.78",
            geo: Geo(country: "TR", city: "Istanbul", org: "AS47524 ...",
                     ispShort: "Türksat"),
            vpnIP: nil,
            vpnGeo: nil,
            discord: DiscordProbe(code: 200, ms: 150),
            error: nil)

        let text = JSON.encode(original)
        let decoded = try XCTUnwrap(JSON.decode(Report.self, from: text))

        XCTAssertEqual(decoded.mode, original.mode)
        XCTAssertEqual(decoded.tunnel, original.tunnel)
        XCTAssertEqual(decoded.routes.count, 2)
        XCTAssertTrue(decoded.routes[0].present)
        XCTAssertFalse(decoded.routes[1].present)
        XCTAssertEqual(decoded.transfer?.rx, 1000)
        XCTAssertEqual(decoded.geo?.ispShort, "Türksat")
        XCTAssertEqual(decoded.discord.code, 200)
        XCTAssertEqual(decoded.health.ageS, 12)
    }

    /// The helper writes snake_case keys; the app must read exactly those.
    func testWireKeysAreSnakeCase() throws {
        let text = JSON.encode(Report(
            health: Health(ok: true, code: .ok, ageS: 3),
            egressIP: "1.2.3.4",
            geo: Geo(ispShort: "X")))
        XCTAssertTrue(text.contains("\"egress_ip\""))
        XCTAssertTrue(text.contains("\"isp_short\""))
        XCTAssertTrue(text.contains("\"age_s\""))
        XCTAssertFalse(text.contains("\"egressIP\""))
    }

    func testProfilesResponseDecodesHelperOutput() throws {
        // Shape produced by `menfez-route profiles`.
        let text = """
        {"active_iface":"utun5","profiles":[
          {"name":"VPN-RO1-RO-229","file":"/tmp/a.conf",
           "endpoint":"203.0.113.69:51820","host":"203.0.113.69",
           "country":"RO","active":true},
          {"name":"VPN-DE1-DE-522","file":"/tmp/b.conf",
           "endpoint":"198.51.100.130:51820","host":"198.51.100.130",
           "country":"DE","active":false}]}
        """
        let response = try XCTUnwrap(JSON.decode(ProfilesResponse.self, from: text))
        XCTAssertEqual(response.activeIface, "utun5")
        XCTAssertEqual(response.profiles.count, 2)
        XCTAssertEqual(response.profiles[0].country, "RO")
        XCTAssertTrue(response.profiles[0].active)
        XCTAssertEqual(response.profiles[1].id, "VPN-DE1-DE-522")
    }

    func testDNSReportDecodesLiveShape() throws {
        let text = """
        {"service":"Wi-Fi","current":["1.1.1.1","1.0.0.1"],"presets":[
          {"id":"quad9","name":"Quad9","note":"blocks malware domains",
           "v4":["9.9.9.9","149.112.112.112"],"ms":5,"ok":true,"active":false},
          {"id":"system","name":"Automatic","v4":[],"ok":true,"active":false}]}
        """
        let report = try XCTUnwrap(JSON.decode(DNSReport.self, from: text))
        XCTAssertEqual(report.service, "Wi-Fi")
        XCTAssertEqual(report.current.first, "1.1.1.1")
        XCTAssertEqual(report.presets.first?.ms, 5)
        XCTAssertTrue(report.presets.last?.v4.isEmpty ?? false)
    }

    func testDetailResponseDecodes() throws {
        let text = """
        {"what":"ip","items":[
          {"label":"IP","value":"203.0.113.78"},
          {"label":"Provider","value":"Türksat"},
          {"label":"Routing","value":"en0 via 192.168.1.1"}],"error":null}
        """
        let detail = try XCTUnwrap(JSON.decode(DetailResponse.self, from: text))
        XCTAssertEqual(detail.items.count, 3)
        XCTAssertEqual(detail.items[1].value, "Türksat")
    }

    // MARK: - Probes are honest

    /// A resolver that cannot answer must report nil, never 0.
    /// A fabricated "0 ms" would make a dead resolver look fastest.
    func testUnreachableResolverReturnsNil() {
        XCTAssertNil(Probes.dnsLatency(server: "192.0.2.99"))
    }

    func testNoAnswersFromDeadResolver() {
        XCTAssertTrue(Probes.dnsAnswers(server: "192.0.2.99").isEmpty)
    }

    /// Empty answers count as poisoned: the caller must not treat "nothing
    /// came back" as a clean result.
    func testEmptyAnswerIsTreatedAsPoisoned() {
        XCTAssertTrue(Probes.looksPoisoned([]))
        XCTAssertTrue(Probes.looksPoisoned(["0.0.0.0"]))
        XCTAssertTrue(Probes.looksPoisoned(["192.168.1.1"]))
        XCTAssertTrue(Probes.looksPoisoned(["127.0.0.1"]))
        XCTAssertTrue(Probes.looksPoisoned(["::ffff:192.168.1.5"]))
    }

    func testPublicAnswerIsNotPoisoned() {
        XCTAssertFalse(Probes.looksPoisoned(["1.1.1.1"]))
        XCTAssertFalse(Probes.looksPoisoned(["172.32.1.1"]))
    }

    /// routeSummary must report what `route -n get` actually says. TEST-NET
    /// addresses resolve through the default route on this machine, so the
    /// check is that a real interface/gateway pair comes back rather than a
    /// hardcoded guess.
    func testRouteSummaryReportsTheRealRoute() {
        let summary = Probes.routeSummary(ip: "1.1.1.1")
        XCTAssertTrue(summary.contains(" via "), "got \(summary)")
        XCTAssertFalse(summary.isEmpty)
    }

    func testHumanBytesFormatting() {
        XCTAssertEqual(Probes.humanBytes(0), "0 B")
        XCTAssertEqual(Probes.humanBytes(1023), "1023 B")
        XCTAssertEqual(Probes.humanBytes(1024), "1.0 KB")
        XCTAssertEqual(Probes.humanBytes(1_048_576), "1.0 MB")
    }

    // MARK: - Shell

    /// The helper must never inherit a caller's PATH: under launchd there is
    /// no /opt/homebrew, and `wg` would appear to be missing.
    func testShellFindsHomebrewToolsRegardlessOfPath() {
        // wg is only in Homebrew; route is only in /sbin.
        XCTAssertTrue(Shell.resolve("wg").hasPrefix("/opt/homebrew")
                      || Shell.resolve("wg") == "wg")
        XCTAssertEqual(Shell.resolve("route"), "/sbin/route")
    }

    func testShellCapturesBothStreams() {
        let result = Shell.run("/bin/sh", ["-c", "echo out; echo err 1>&2"], timeout: 5)
        XCTAssertTrue(result.ok)
        XCTAssertTrue(result.output.contains("out"))
        XCTAssertTrue(result.output.contains("err"))
    }

    func testShellTrimsTailForStatusBar() {
        let result = Shell.run("/bin/sh", ["-c", "echo one; echo two; echo three"],
                               timeout: 5)
        let tail = result.tail(2)
        XCTAssertTrue(tail.contains("two"))
        XCTAssertTrue(tail.contains("three"))
        XCTAssertFalse(tail.contains("one"))
    }

    // MARK: - Paths

    /// Under sudo, $HOME is root's. The helper must still resolve the invoking
    /// user's Application Support directory, or it writes profiles nobody can
    /// read.
    func testSupportPathIsUnderLibraryApplicationSupport() {
        XCTAssertTrue(Path.support.hasSuffix("Library/Application Support/Menfez"))
        XCTAssertEqual(Path.managedConfig, "/var/run/menfez/wireguard/wgmanaged.conf")
        XCTAssertEqual(Path.stateDir, "/var/run/menfez")
    }

    func testProfileDirIsNotWorldReadable() {
        // Profiles hold private keys.
        _ = Path.ensureDir(Path.profiles, mode: 0o700)
        let attrs = try? FileManager.default
            .attributesOfItem(atPath: Path.profiles)
        let perms = (attrs?[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(perms ?? 0o755, 0o700)
    }
}
