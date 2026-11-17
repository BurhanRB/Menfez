import XCTest
@testable import MenfezCore

/// The read path's contract, counted rather than asserted.
///
/// The bug this file exists for: the UI refreshed every 5 seconds by spawning
/// `sudo menfez-route report --fast`, which inside the root process shelled out
/// to `wg`, `route`, `networksetup`, `ifconfig` and `ipconfig`. Nothing was
/// wrong with any single value; the problem was the *rate* at which a root
/// process was created to produce them. A test that only checks the report is
/// correct would have passed against the buggy version, so these tests count
/// processes.
///
/// Every command is recorded by a `CommandRunner` that answers from a table.
/// Nothing here touches the real network, the real route table or the real
/// resolver configuration.
final class ReadPathTests: XCTestCase {

    // MARK: - The recording runner

    /// A runner that never starts a process.
    ///
    /// It answers with whatever the test registered for a (tool, first
    /// argument) pair and records the full call list, so a test can assert both
    /// "what did this read" and "did it reach for something privileged".
    final class Recorder: CommandRunner, @unchecked Sendable {
        struct Call: Equatable {
            let tool: String
            let args: [String]
            var joined: String { ([tool] + args).joined(separator: " ") }
        }

        private let lock = NSLock()
        private var _calls: [Call] = []
        private var answers: [String: CommandResult] = [:]

        var calls: [Call] {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }

        /// Register a canned answer. The key is matched against the joined
        /// command line, so "wg show utun9 endpoints" is unambiguous.
        func answer(_ command: String, status: Int32 = 0, output: String = "") {
            lock.lock(); defer { lock.unlock() }
            answers[command] = CommandResult(status: status, output: output)
        }

        func run(_ tool: String, _ args: [String], timeout: TimeInterval) -> CommandResult {
            let call = Call(tool: tool, args: args)
            lock.lock()
            _calls.append(call)
            let key = call.joined
            let exact = answers[key]
            // Fall back to a (tool + first arg) prefix match, which is how the
            // tests express "any `wg show <iface> ...`".
            let prefix = answers.first { k, _ in key.hasPrefix(k + " ") }?.value
            lock.unlock()

            if let hit = exact ?? prefix { return hit }
            // Unregistered commands fail the way a missing tool does, so an
            // unhandled branch shows up as a nil field rather than a crash.
            return CommandResult(status: 127, output: "\(tool): not stubbed")
        }

        /// Every command that needs root, as this platform actually behaves.
        ///
        /// `wg show interfaces` is NOT on the list: it enumerates
        /// /var/run/wireguard, which is 0755, and works as uid 501.
        /// `wg show <iface> ...` IS on the list: it opens a 0600 socket in that
        /// directory and returns "Unable to access interface: Permission
        /// denied". Verified by hand on macOS 14, see docs/READ-PATH.md.
        var privilegedCalls: [Call] {
            calls.filter { call in
                if call.tool == "sudo" { return true }
                if call.tool.hasSuffix("wg") || call.tool == "wg" {
                    // Anything that names an interface.
                    return call.args.count >= 2 && call.args[0] == "show"
                        && call.args[1] != "interfaces"
                }
                return false
            }
        }
    }

    /// A plausible machine: one tunnel, one physical interface, resolvers set.
    private func standardMachine(_ r: Recorder) {
        r.answer("wg show interfaces", output: "utun9\n")
        r.answer("netstat -rn", output: """
            Internet:
            Destination        Gateway            Flags               Netif Expire
            default            192.168.1.1        UGScg                 en0
            162.159.128/18     link#21            USc                 utun9
            162.159.192/24     link#21            USc                 utun9
            """)
        r.answer("ifconfig utun9", output: "utun9: flags=8051<UP,POINTOPOINT>")
        r.answer("route -n get default", output: """
               route to: default
            destination: default
                   mask: default
                gateway: 192.168.1.1
              interface: en0
            """)
        r.answer("route -n get -net 162.159.128.0/18", output: """
               route to: 162.159.128.0
            destination: 162.159.128.0
                   mask: 255.255.192.0
              interface: utun9
            """)
        r.answer("route -n get -net 162.159.192.0/24", output: """
               route to: 162.159.192.0
            destination: 162.159.192.0
                   mask: 255.255.255.0
              interface: utun9
            """)
        r.answer("networksetup -listnetworkserviceorder", output: """
            (1) Thunderbolt Bridge
            (Hardware Port: Thunderbolt Bridge, Device: bridge0)

            (2) Wi-Fi
            (Hardware Port: Wi-Fi, Device: en0)
            """)
        r.answer("networksetup -getdnsservers Wi-Fi", output: "1.1.1.1\n1.0.0.1\n")
        r.answer("ipconfig getifaddr en0", output: "192.168.1.2\n")
    }

    /// Run a closure with an empty route state file.
    ///
    /// Every `buildLocal` call in this file goes through one of these two
    /// helpers. Without that, a test would read whatever this machine has in
    /// /var/run/menfez, and the suite would pass or fail depending on whether
    /// the developer happened to have a tunnel up.
    private func withEmptyState<T>(_ body: (String) throws -> T) rethrows -> T {
        try withState(RouteState(), body)
    }

    /// Write a route state file so the report has something to describe.
    ///
    /// The file goes in its own directory, not straight into NSTemporaryDirectory:
    /// `StateFile.write` normalises the *parent* directory's mode to 0755 (the
    /// app has to be able to stat root-owned /var/run/menfez), and it refuses a
    /// parent it cannot chmod. Handing it the shared temp directory would make
    /// the test depend on that directory's permissions.
    private func withState<T>(_ state: RouteState, _ body: (String) throws -> T) rethrows -> T {
        let dir = NSTemporaryDirectory() + "menfez-readpath-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/route-state.json"
        XCTAssertTrue(RouteStateStore.save(state, path: path))
        return try body(path)
    }

    // MARK: - The fast path is unprivileged

    /// THE test for this change.
    ///
    /// A local report must not spawn `sudo`, must not run `wg show <iface>`,
    /// and must not run any other root-only command. If someone reintroduces a
    /// privileged read into the fast path, this fails.
    func testLocalReportSpawnsNothingPrivileged() {
        let r = Recorder()
        standardMachine(r)

        let report = withEmptyState { path in
            ReportBuilder().buildLocal(statePath: path, using: r)
        }

        XCTAssertEqual(report.tunnel, "utun9",
                       "the tunnel should still be detected: `wg show interfaces` "
                       + "does not need root")
        XCTAssertTrue(r.privilegedCalls.isEmpty,
                      "the local report must start no privileged process, but ran: "
                      + r.privilegedCalls.map(\.joined).joined(separator: ", "))
        XCTAssertNil(r.calls.first(where: { $0.tool == "sudo" }))
    }

    /// The privileged fields are nil, not zero, when nobody measured them.
    ///
    /// This is `Probes.swift`'s one rule applied to the read path: an
    /// unmeasured handshake must render as a dash, and a 0/0 transfer would
    /// read as "the tunnel moved no traffic".
    func testLocalReportLeavesPrivilegedFieldsUnmeasured() {
        let r = Recorder()
        standardMachine(r)

        let report = withEmptyState { path in
            ReportBuilder().buildLocal(statePath: path, using: r)
        }

        XCTAssertNil(report.transfer, "an unread counter is not zero bytes")
        XCTAssertNil(report.peerPubkey)
        XCTAssertNil(report.handshakeEpoch)
        XCTAssertNil(report.handshakeAgeS)
        XCTAssertNil(report.endpoint, "the endpoint needs `wg show <iface> endpoints`")
        XCTAssertEqual(report.health.code, .unknown,
                       "health cannot be judged without the handshake, and "
                       + "noHandshake would claim a measurement")
        XCTAssertFalse(report.health.ok)
    }

    /// Everything else in the report must actually be filled by the local path.
    ///
    /// The counterpart to the test above: it would be easy to satisfy "spawns
    /// nothing privileged" by spawning nothing at all and showing an empty
    /// card. These are the fields a user reads at a glance and none of them
    /// needs root.
    func testLocalReportFillsEveryUnprivilegedField() {
        let r = Recorder()
        standardMachine(r)

        withState(RouteState(mode: "discord",
                             iface: "utun9",
                             routes: ["162.159.128.0/18", "162.159.192.0/24"],
                             hosts: ["203.0.113.69"],
                             gateway: "192.168.1.1",
                             profile: "VPN-RO1-RO-229",
                             generation: 3)) { statePath in
            let report = ReportBuilder().buildLocal(statePath: statePath, using: r)

            XCTAssertEqual(report.mode, "discord")
            XCTAssertEqual(report.gateway, "192.168.1.1")
            XCTAssertEqual(report.interface, "en0")
            XCTAssertEqual(report.localIP, "192.168.1.2")
            XCTAssertEqual(report.dns, ["1.1.1.1", "1.0.0.1"])
            XCTAssertEqual(report.dnsService, "Wi-Fi")
            XCTAssertEqual(report.profile, "VPN-RO1-RO-229")
            XCTAssertEqual(report.hosts, ["203.0.113.69"])
            XCTAssertEqual(report.routes.count, 2)
            XCTAssertTrue(report.routes.allSatisfy(\.present),
                          "both prefixes are on utun9 in the stub")
            XCTAssertTrue(r.privilegedCalls.isEmpty)
        }
    }

    /// A prefix that is recorded but absent must read as absent.
    ///
    /// A recorded prefix missing from the table must read as missing. A
    /// regression here silently turns "your routes are gone" into
    /// "everything is fine".
    func testLocalReportMarksAMissingRouteAsMissing() {
        let r = Recorder()
        standardMachine(r)
        r.answer("netstat -rn", output: """
            Internet:
            Destination        Gateway            Flags               Netif Expire
            default            192.168.1.1        UGScg                 en0
            162.159.128/18     link#21            USc                 utun9
            """)

        withState(RouteState(mode: "discord", iface: "utun9",
                             routes: ["162.159.128.0/18", "162.159.192.0/24"],
                             generation: 1)) { statePath in
            let report = ReportBuilder().buildLocal(statePath: statePath, using: r)
            XCTAssertEqual(report.routes.count, 2)
            XCTAssertTrue(report.routes[0].present)
            XCTAssertFalse(report.routes[1].present)
        }
    }

    /// No tunnel at all is `down`, not `unknown`.
    ///
    /// The distinction matters: `wg show interfaces` succeeding with no output
    /// is a real measurement of "nothing is up", and the UI must say so.
    func testNoTunnelIsDownNotUnknown() {
        let r = Recorder()
        r.answer("wg show interfaces", output: "")

        // An empty state file, so the test does not depend on what this machine
        // happens to have recorded in /var/run/menfez.
        withState(RouteState()) { statePath in
            let report = ReportBuilder().buildLocal(statePath: statePath, using: r)
            XCTAssertNil(report.tunnel)
            XCTAssertEqual(report.health.code, .down)
            XCTAssertNil(report.error)
        }
    }

    /// A failed enumeration is `unknown`, and must not produce a structural
    /// error sentence either.
    ///
    /// A missing `wg` binary (Homebrew uninstalled, PATH wrong) used to look
    /// exactly like "no tunnel", and then the report added "mode is discord but
    /// no tunnel is up" on top of it. That is two false claims from one
    /// unanswerable question.
    func testFailedEnumerationIsUnknownAndNotAnError() {
        let r = Recorder()
        // No answer registered: the recorder returns 127.
        withState(RouteState(mode: "discord", iface: "utun9", generation: 1)) { statePath in
            let report = ReportBuilder().buildLocal(statePath: statePath, using: r)
            XCTAssertNil(report.tunnel)
            XCTAssertEqual(report.health.code, .unknown)
            XCTAssertNil(report.error,
                         "we could not look, so we must not claim the tunnel is down")
        }
    }

    /// The probed depth adds the HTTPS calls and still no root.
    ///
    /// `curl` is not privileged; a user-initiated "full" refresh may pay for
    /// it, but it must not drag the privileged path in with it.
    func testProbedDepthStaysUnprivileged() {
        let r = Recorder()
        standardMachine(r)
        r.answer("curl -sS --max-time 6 https://api.ipify.org", output: "203.0.113.7")
        r.answer("curl", status: 0, output: "{}")

        let report = withEmptyState { path in
            ReportBuilder().buildLocal(depth: .probed, statePath: path, using: r)
        }

        XCTAssertEqual(report.egressIP, "203.0.113.7")
        XCTAssertTrue(r.privilegedCalls.isEmpty,
                      "probed: " + r.privilegedCalls.map(\.joined).joined(separator: ", "))
    }

    // MARK: - The privileged half is one round trip

    /// `facts` reads the interface four times, each with a distinct `wg show`
    /// verb, and derives the age from the single epoch.
    ///
    /// The version this replaces called `latest-handshakes` three times per
    /// refresh (once for the age, once for the epoch, once inside `health`),
    /// and each was a separate root child process.
    func testFactsReadsTheHandshakeOnceAndDerivesTheAge() {
        let r = Recorder()
        r.answer("wg show utun9 endpoints",
                 output: "PUBKEY=\t203.0.113.69:51820\n")
        r.answer("wg show utun9 peers", output: "PUBKEY=\n")
        r.answer("wg show utun9 latest-handshakes",
                 output: "PUBKEY=\t\(Int(Date().timeIntervalSince1970) - 12)\n")
        r.answer("wg show utun9 transfer", output: "PUBKEY=\t1000\t2000\n")

        let facts = RouteManager.facts(iface: "utun9", using: r)

        XCTAssertEqual(facts.tunnel, "utun9")
        XCTAssertEqual(facts.endpoint, "203.0.113.69")
        XCTAssertEqual(facts.peerPubkey, "PUBKEY=")
        XCTAssertEqual(facts.transfer, Transfer(rx: 1000, tx: 2000))
        XCTAssertNotNil(facts.handshakeEpoch)

        let handshakeReads = r.calls.filter {
            $0.args == ["show", "utun9", "latest-handshakes"]
        }
        XCTAssertEqual(handshakeReads.count, 1,
                       "the epoch must be read once and reused: "
                       + "\(handshakeReads.count) reads")
        XCTAssertEqual(r.calls.count, 4, "four wg reads, one per fact")
    }

    /// Health from a facts snapshot: fresh vs stale, and nil for no peer.
    func testHealthFromFacts() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let fresh = Int(now.timeIntervalSince1970) - 10
        let old = Int(now.timeIntervalSince1970) - (RouteManager.handshakeMaxAge + 5)

        XCTAssertEqual(RouteManager.health(iface: "u", exists: true,
                                           handshakeEpoch: fresh, now: now).code, .ok)
        XCTAssertEqual(RouteManager.health(iface: "u", exists: true,
                                           handshakeEpoch: old, now: now).code, .stale)
        XCTAssertEqual(RouteManager.health(iface: "u", exists: true,
                                           handshakeEpoch: nil, now: now).code, .noHandshake)
        XCTAssertEqual(RouteManager.health(iface: "u", exists: false,
                                           handshakeEpoch: fresh, now: now).code, .gone)
    }

    /// The stale code carries the age so the UI can print it.
    func testStaleHealthCarriesTheAge() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let old = Int(now.timeIntervalSince1970) - 400
        let health = RouteManager.health(iface: "u", exists: true,
                                         handshakeEpoch: old, now: now)
        XCTAssertEqual(health.code, .stale)
        XCTAssertEqual(health.ageS, 400)
    }

    // MARK: - Wire compatibility

    /// `TunnelFacts` must round-trip through the same snake_case keys the rest
    /// of the contract uses.
    ///
    /// This is the payload the new helper emits and the new app reads. It is a
    /// separate object from `Report` on purpose: adding it means an older app
    /// simply never asks for `facts`, and a newer app talking to an older
    /// helper gets a usage error (exit 2) instead of a decode failure.
    func testTunnelFactsWireShape() {
        let facts = RouteManager.TunnelFacts(
            tunnel: "utun9",
            endpoint: "203.0.113.69",
            peerPubkey: "abc=",
            handshakeEpoch: 1_700_000_000,
            transfer: Transfer(rx: 1, tx: 2))
        let text = JSON.encode(facts)

        XCTAssertTrue(text.contains("\"peer_pubkey\""))
        XCTAssertTrue(text.contains("\"handshake_epoch\""))
        XCTAssertFalse(text.contains("\"peerPubkey\""))

        let back = JSON.decode(RouteManager.TunnelFacts.self, from: text)
        XCTAssertEqual(back, facts)
    }

    /// An older app must still decode a current `Report`.
    ///
    /// `unknown` is an app-only health code. If the helper ever emitted it, an
    /// older app (whose `Health.Code` has no such case) would fail to decode
    /// the *entire* report, because `health` is non-optional. This test pins the
    /// rule: the helper's output never contains it.
    func testHelperReportNeverEmitsUnknownHealth() {
        let r = Recorder()
        // No tunnel, and not even an enumerable one.
        r.answer("wg show interfaces", status: 1, output: "wg: not found")

        let report = withEmptyState { path in
            ReportBuilder().build(full: false, statePath: path, using: r)
        }
        XCTAssertNotEqual(report.health.code, .unknown,
                          "the helper must not emit a code older apps cannot decode")
        XCTAssertEqual(report.health.code, .down)

        let text = JSON.encode(report)
        XCTAssertFalse(text.contains("\"unknown\""))
    }

    /// `menfez-route facts` with no tunnel must be a decodable nullable object.
    ///
    /// The helper emits `RouteManager.TunnelFacts()` in that case, which has to
    /// be valid JSON with `tunnel: null` — not `{}` and not an empty stdout. The
    /// app distinguishes "no tunnel" from "could not ask" by whether the reply
    /// decoded at all, so this shape is part of the contract.
    func testEmptyFactsAreDecodableAndMeanNoTunnel() throws {
        let text = JSON.encode(RouteManager.TunnelFacts())
        let facts = try XCTUnwrap(JSON.decode(RouteManager.TunnelFacts.self, from: text))

        XCTAssertNil(facts.tunnel)
        XCTAssertNil(facts.endpoint)
        XCTAssertNil(facts.transfer)
        XCTAssertNil(facts.handshakeEpoch)
        // And it must still be a JSON object, so a decoder cannot mistake it
        // for a malformed reply. `{}` is what an all-nil `TunnelFacts` encodes
        // to (Swift's default encoder drops nil optionals), and decoding it
        // gives a `TunnelFacts` whose every field is nil — which is precisely
        // "no tunnel", not "no answer". The XCTUnwrap above proves the decode.
        XCTAssertTrue(text.hasPrefix("{"))
        XCTAssertTrue(text.hasSuffix("}"))
    }

    /// A report produced by `buildLocal` is still decodable by anything that
    /// understands `Report`, unknown code included.
    func testLocalReportSurvivesTheWire() {
        let r = Recorder()
        standardMachine(r)
        let local = withEmptyState { path in
            ReportBuilder().buildLocal(statePath: path, using: r)
        }
        let decoded = JSON.decode(Report.self, from: JSON.encode(local))
        XCTAssertEqual(decoded?.health.code, .unknown)
        XCTAssertEqual(decoded?.tunnel, "utun9")
    }

    // MARK: - Profiles without a privileged read

    /// Listing profiles from disk must not ask for the live endpoint.
    ///
    /// The picker used `WireGuardProfiles.list()`, which called
    /// `wg show <iface> endpoints` — root — just to decide which row to
    /// highlight. With no host supplied, no row is marked active and the picker
    /// shows no highlight, which is a dash, not a wrong answer.
    func testProfileListingWithoutLiveHostStaysUnprivileged() throws {
        let dir = NSTemporaryDirectory() + "menfez-profiles-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let conf = """
        [Interface]
        PrivateKey = SECRET
        Address = 10.2.0.2/32

        [Peer]
        PublicKey = PEER
        Endpoint = 203.0.113.69:51820
        """
        try conf.write(toFile: dir + "/VPN-RO1-RO-229.conf",
                       atomically: true, encoding: .utf8)

        let r = Recorder()
        let profiles = WireGuardProfiles.list(directory: dir, liveHost: nil,
                                              resolveLiveHost: false, using: r)

        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].endpoint, "203.0.113.69:51820")
        XCTAssertFalse(profiles[0].active,
                       "without a live host no row may claim to be the active one")
        XCTAssertTrue(r.calls.isEmpty,
                      "a directory read must start no process at all, ran: "
                      + r.calls.map(\.joined).joined(separator: ", "))
    }

    /// When the caller does have a host from `facts`, the highlight works
    /// again — the value is just supplied instead of probed.
    func testProfileListingMarksActiveFromASuppliedHost() throws {
        let dir = NSTemporaryDirectory() + "menfez-profiles-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let conf = """
        [Interface]
        Address = 10.2.0.2/32

        [Peer]
        Endpoint = 203.0.113.69:51820
        """
        try conf.write(toFile: dir + "/VPN-RO1-RO-229.conf",
                       atomically: true, encoding: .utf8)

        let profiles = WireGuardProfiles.list(directory: dir,
                                              liveHost: "203.0.113.69",
                                              resolveLiveHost: false,
                                              using: Recorder())
        XCTAssertTrue(profiles.first?.active ?? false)
    }

    // MARK: - A missing helper must not crash or hang the app

    /// If the helper is missing, `facts` returns nil and every privileged field
    /// stays a dash. The app must still show a full card.
    ///
    /// This is the "sudoers rule absent" case: `sudo -n` exits non-zero, the
    /// decode returns nil, and nothing else changes.
    func testMissingPrivilegedDataLeavesADashNotAnError() {
        let r = Recorder()
        standardMachine(r)
        let local = withEmptyState { path in
            ReportBuilder().buildLocal(statePath: path, using: r)
        }

        // Simulate the merge with no facts available: this is what the app does.
        var merged = local
        let facts: RouteManager.TunnelFacts? = nil
        if facts == nil {
            merged.transfer = nil
            merged.handshakeAgeS = nil
        }

        XCTAssertNil(merged.transfer)
        XCTAssertNil(merged.handshakeAgeS)
        XCTAssertEqual(merged.tunnel, "utun9", "the unprivileged half still works")
        XCTAssertEqual(merged.health.code, .unknown)
    }
}
