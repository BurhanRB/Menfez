import XCTest
@testable import MenfezCore

/// The ordering and rollback guarantees that the rest of the suite describes
/// but does not actually pin.
///
/// `SecurityTests` proves the state file is *pending* while routes go in, which
/// is a different property from "the pin is in the table before the first wide
/// prefix". A regression that moved `addHost` to after the prefix loop would
/// leave every existing test green, because they assert on the state file
/// rather than on the order of the two mutations. These tests record the
/// mutation sequence itself, so that ordering is the thing under test.
///
/// Nothing here touches the route table: every mutating call is an injected
/// closure. `changeMode` is the one exception — it probes the live pin through
/// `RouteManager.hostRouteGateway`, which is read-only.
final class RouteSafetyTests: XCTestCase {

    private var root = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("menfez-routesafety-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if !root.isEmpty { try? FileManager.default.removeItem(atPath: root) }
        root = ""
        try super.tearDownWithError()
    }

    private func path(_ name: String) -> String {
        (root as NSString).appendingPathComponent(name)
    }

    /// A key with characters that must never appear in an error message.
    private let plantedKey = "PLANTEDKEY44SENTINEL/x9Q2w7ErTyUiOpAsDfGhJkLzXcVbNm="

    private func protonConfig(key: String) -> String {
        """
        [Interface]
        PrivateKey = \(key)
        Address = 10.2.0.2/32
        DNS = 10.2.0.1

        [Peer]
        PublicKey = TESTONLYFAKEPEERKEYDONOTUSE000000000000000A=
        AllowedIPs = 0.0.0.0/0, ::/0
        Endpoint = 203.0.113.69:51820
        """
    }

    /// Drive `up` far enough to reach the mutation loop with everything else
    /// injected. `events` receives one entry per route mutation, in order.
    private func makeManager(statePath: String,
                             events: @escaping (String) -> Void,
                             failOnNet: String? = nil,
                             failDeleteNet: Bool = false)
        -> RouteManager {
        var manager = RouteManager(settle: 0, statePath: statePath)
        manager.probeInterfaces = { ["utun9"] }
        manager.probeHealth = { _ in (true, "handshake 1s old") }
        manager.probeEndpoint = { _ in "203.0.113.69" }
        manager.probeGateway = { "192.168.1.1" }
        manager.probeBaseline = { _ in
            RouteManager.Baseline(epoch: 1_000, rx: 0, tx: 0)
        }
        manager.probeProgress = { _, _, _ in (true, "transport moved") }
        manager.addHost = { ip, gateway in
            events("pin:\(ip)->\(gateway)")
            return RouteManager.Mutation(ok: true, detail: "added")
        }
        manager.addNet = { cidr, _ in
            events("net:\(cidr)")
            if cidr == failOnNet {
                return RouteManager.Mutation(ok: false, detail: "no such interface")
            }
            return RouteManager.Mutation(ok: true, detail: "added")
        }
        manager.deleteNet = { cidr in
            events("-net:\(cidr)")
            return !failDeleteNet
        }
        manager.deleteHost = { ip in
            events("-pin:\(ip)")
            return true
        }
        return manager
    }

    // MARK: - 1. The pin is installed before any wide prefix

    /// The regression this exists for: move `addHost` below the prefix loop and
    /// every other test still passes, while `all` mode briefly routes the
    /// tunnel's own encrypted transport into the tunnel.
    ///
    /// The assertion is on the *index* of the pin relative to the first prefix,
    /// not on the pin's presence, so "a pin exists somewhere in the run" is not
    /// enough to pass.
    func testEndpointPinIsInstalledBeforeTheFirstWidePrefix() throws {
        let statePath = path("route-state.json")
        var events: [String] = []
        let manager = makeManager(statePath: statePath,
                                  events: { events.append($0) })

        let result = manager.up(mode: .discord)
        XCTAssertTrue(result.ok, result.error ?? "")

        let pinIndex = try XCTUnwrap(events.firstIndex { $0.hasPrefix("pin:") },
                                     "no pin was attempted at all: \(events)")
        let firstNetIndex = try XCTUnwrap(events.firstIndex { $0.hasPrefix("net:") },
                                          "no prefix was added at all: \(events)")
        XCTAssertLessThan(pinIndex, firstNetIndex,
                          "the endpoint pin was installed after a wide prefix: \(events)")

        // The pin must also not be withdrawn before the prefixes go in: a run
        // that pinned and immediately unpinned would satisfy the index check.
        let unpinIndex = events.firstIndex { $0.hasPrefix("-pin:") }
        XCTAssertNil(unpinIndex,
                     "the pin was removed during a successful run: \(events)")

        // Both prefixes are still covered by a single pin, added once.
        XCTAssertEqual(events.filter { $0.hasPrefix("pin:") }.count, 1,
                       "the pin was installed more than once: \(events)")
    }

    /// `all` mode is the one that swallows the endpoint's own address, so the
    /// ordering matters most there. The union of the halves covers the whole
    /// IPv4 space; this asserts the pin still comes first.
    func testEndpointPinPrecedesTheAllModeHalves() throws {
        let statePath = path("route-state.json")
        var events: [String] = []
        let manager = makeManager(statePath: statePath,
                                  events: { events.append($0) })

        let result = manager.up(mode: .all)
        XCTAssertTrue(result.ok, result.error ?? "")

        let pinIndex = try XCTUnwrap(events.firstIndex { $0.hasPrefix("pin:") })
        let firstNetIndex = try XCTUnwrap(events.firstIndex { $0.hasPrefix("net:") })
        XCTAssertLessThan(pinIndex, firstNetIndex,
                          "all mode added a /1 before pinning the endpoint: \(events)")
        XCTAssertEqual(events.filter { $0.hasPrefix("net:") }.count, 4,
                       "all mode must use exactly two IPv4 and two IPv6 halves: \(events)")
    }

    // MARK: - 2. Rollback removes the earlier prefix and the pin, in reverse

    /// Route 2 of 3 fails: the pin and the first prefix must both come out, the
    /// pin last, and the state must not claim anything. The existing
    /// `testFailedUpDoesNotLeaveAPendingState` fails the *first* prefix add, so
    /// it never exercises undoing a prefix that did go in.
    func testFailingSecondPrefixRollsBackTheFirstPrefixAndThePin() throws {
        let statePath = path("route-state.json")
        var events: [String] = []
        let manager = makeManager(statePath: statePath,
                                  events: { events.append($0) },
                                  failOnNet: "162.159.192.0/24")

        let result = manager.up(mode: .discord)
        XCTAssertFalse(result.ok)

        // The first prefix went in and must come back out.
        XCTAssertTrue(events.contains("net:162.159.128.0/18"), "\(events)")
        XCTAssertTrue(events.contains("-net:162.159.128.0/18"),
                      "the first prefix was left installed: \(events)")

        // The one that failed was never installed, so it must not be undone.
        XCTAssertFalse(events.contains("-net:162.159.192.0/24"),
                       "the rollback tried to remove a route that never went in: \(events)")

        // The pin must be removed, and only after every prefix is gone,
        // otherwise there is a moment with no pin and no wide route — which is
        // harmless — or, worse, the reverse order would leave a wide route
        // unpinned. Assert the actual order.
        let unpinIndex = try XCTUnwrap(events.firstIndex { $0.hasPrefix("-pin:") },
                                       "the pin was left installed: \(events)")
        let lastNetDelete = try XCTUnwrap(events.lastIndex { $0.hasPrefix("-net:") })
        XCTAssertGreaterThan(unpinIndex, lastNetDelete,
                             "the pin was removed before the prefixes: \(events)")

        let after = RouteStateStore.load(path: statePath)
        XCTAssertFalse(after.pending, "the rollback left the intent armed")
        XCTAssertEqual(after.mode, "off")
        XCTAssertTrue(after.routes.isEmpty, "\(after.routes)")
        XCTAssertTrue(after.hosts.isEmpty, "\(after.hosts)")
    }

    // MARK: - 3. A failed tunnel start must not echo the private key

    /// `wg-quick` echoes the offending config line, and the managed config holds
    /// the private key. The existing key tests only inspect model types that
    /// have no field for a key; this one puts the key in *tool output* and
    /// proves the failure path replaces it rather than passing it through.
    ///
    /// The positive control is the summary containing "privatekey present":
    /// without it a `managedConfigSummary` that always returned `[]` would pass.
    func testAFailedTunnelStartNeverEchoesThePrivateKey() throws {
        let configPath = path("wgmanaged.conf")
        try protonConfig(key: plantedKey).write(toFile: configPath,
                                                atomically: true,
                                                encoding: .utf8)

        var manager = RouteManager(settle: 0,
                                   statePath: path("route-state.json"),
                                   managedConfigPath: configPath)

        // No tunnel: `up` tries wg-quick, which rejects the config and echoes it.
        manager.probeInterfaces = { [] }
        manager.run = { _, _, _ in
            CommandResult(
                status: 1,
                output: """
                Line unrecognized: `PrivateKey = \(self.plantedKey)`
                Invalid key: \(self.plantedKey)
                """)
        }

        let result = manager.up(mode: .discord)
        XCTAssertFalse(result.ok)

        let json = JSON.encode(result)
        for surface in [json,
                        result.error ?? "",
                        result.notes.joined(separator: "\n")] {
            XCTAssertFalse(surface.contains(plantedKey),
                           "the private key reached the failure payload: \(surface)")
            XCTAssertFalse(surface.contains("PLANTEDKEY"),
                           "a fragment of the key reached the failure payload: \(surface)")
            XCTAssertFalse(surface.contains("9Q2w7ErTyUiOpAsDfGhJkLzXcVbNm"),
                           "the tail of the key reached the failure payload: \(surface)")
            XCTAssertFalse(surface.contains("Line unrecognized"),
                           "raw tool output reached the failure payload: \(surface)")
        }

        // The failure is the fixed sentence, not the tool's text. Asserted by
        // shape rather than by exact wording so a copy edit does not fail the
        // test, while "the raw text is gone" still does.
        let error = try XCTUnwrap(result.error)
        XCTAssertTrue(error.hasPrefix("tunnel start"),
                      "the failure does not name the operation: \(error)")
        XCTAssertTrue(error.contains("could not be applied"),
                      "the failure is not the redacted form: \(error)")
        XCTAssertTrue(error.contains("Nothing was changed"),
                      "the failure does not tell the user the state is intact: \(error)")

        // Positive control: the redacted summary did run, so the absence above
        // is not the absence of an empty summary.
        XCTAssertTrue(result.notes.contains { $0.contains("privatekey present") },
                      "the sanitised summary was not produced: \(result.notes)")
        XCTAssertTrue(result.notes.contains { $0.contains("line ") },
                      "the summary carried no line numbers: \(result.notes)")
        // The key value must not ride along with its own line number.
        XCTAssertFalse(result.notes.joined().contains("10.2.0.2/32"),
                       "a config value reached the summary: \(result.notes)")
    }

    // MARK: - 4. Pending-state recovery removes the pin, and is idempotent

    /// A crash between the pin and the first prefix leaves a pending file whose
    /// only real entry is the host route. Recovery must remove that pin — a pin
    /// that survives points at the gateway of a network the machine may have
    /// left — and must leave nothing for a second pass to do.
    ///
    /// The existing reconcile test asserts the prefixes were removed but never
    /// asserts the host route was, even though it installs one.
    func testReconcileRemovesThePinLeftByACrashBeforeAnyPrefix() throws {
        let statePath = path("route-state.json")
        XCTAssertTrue(RouteStateStore.save(
            RouteState(mode: "discord", iface: "utun5",
                       routes: [],
                       hosts: ["203.0.113.69"],
                       gateway: "192.168.1.1",
                       pending: true, generation: 3),
            path: statePath))

        var manager = RouteManager(settle: 0, statePath: statePath)
        var removedHosts: [String] = []
        var removedNets: [String] = []
        manager.deleteNet = { removedNets.append($0); return true }
        manager.deleteHost = { removedHosts.append($0); return true }

        let result = try XCTUnwrap(manager.reconcile())
        XCTAssertTrue(result.ok, result.error ?? "")
        XCTAssertEqual(removedHosts, ["203.0.113.69"],
                       "the pin left by the crash survived recovery")
        XCTAssertTrue(removedNets.isEmpty, "\(removedNets)")

        let after = RouteStateStore.load(path: statePath)
        XCTAssertFalse(after.pending)
        XCTAssertEqual(after.mode, "off")
        XCTAssertTrue(after.hosts.isEmpty, "\(after.hosts)")
        XCTAssertEqual(after.generation, 3,
                       "recovery must not bump the generation; a timer armed for "
                       + "the crashed run would stop matching")

        // A second command must find nothing to do. Recovery that reported the
        // same pending file twice would delete routes on every invocation.
        XCTAssertNil(manager.reconcile(),
                     "recovery was not idempotent: the pending state came back")
        XCTAssertEqual(removedHosts, ["203.0.113.69"],
                       "the second reconcile touched the table again")
    }

    // MARK: - 5. changeMode probes the pin instead of trusting the state file

    /// H2. The state file claiming `hosts` contains the endpoint is not evidence
    /// that the pin is in the table: it survived an interface going down, a
    /// network change, or a manual `route delete`. `changeMode` therefore probes
    /// the live gateway and re-pins when it differs.
    ///
    /// The gateway here is TEST-NET-3, which no machine has as its default
    /// gateway, so the live probe always disagrees and the re-pin is required.
    func testChangeModeReinstallsAPinTheStateFileOnlyClaims() throws {
        let statePath = path("route-state.json")
        XCTAssertTrue(RouteStateStore.save(
            RouteState(mode: "discord", iface: "utun5",
                       routes: ["162.159.128.0/18", "162.159.192.0/24"],
                       hosts: ["198.51.100.7"],
                       gateway: "192.168.1.1",
                       pending: false, generation: 5),
            path: statePath))

        var manager = RouteManager(settle: 0, statePath: statePath)
        manager.probeInterfaces = { ["utun9"] }
        manager.probeHealth = { _ in (true, "handshake 1s old") }
        manager.probeGateway = { "203.0.113.1" }
        manager.probeEndpoint = { _ in "198.51.100.7" }

        var events: [String] = []
        manager.addHost = { ip, gateway in
            events.append("pin:\(ip)->\(gateway)")
            return RouteManager.Mutation(ok: true, detail: "added")
        }
        manager.addNet = { cidr, _ in
            events.append("net:\(cidr)")
            return RouteManager.Mutation(ok: true, detail: "added")
        }
        manager.deleteNet = { cidr in
            events.append("-net:\(cidr)")
            return true
        }

        let result = manager.changeMode(to: .all)
        XCTAssertTrue(result.ok, result.error ?? "")

        // The state said the pin existed. It must be re-installed anyway.
        let pin = try XCTUnwrap(events.first { $0.hasPrefix("pin:") },
                                "changeMode trusted the state file and skipped the pin: \(events)")
        XCTAssertEqual(pin, "pin:198.51.100.7->203.0.113.1",
                       "the pin was not reinstalled against the live gateway")

        // And still before any wide prefix.
        let pinIndex = try XCTUnwrap(events.firstIndex { $0.hasPrefix("pin:") })
        let firstNetIndex = try XCTUnwrap(events.firstIndex { $0.hasPrefix("net:") })
        XCTAssertLessThan(pinIndex, firstNetIndex,
                          "the swap added a /1 before the pin: \(events)")

        let after = RouteStateStore.load(path: statePath)
        XCTAssertEqual(after.mode, "all")
        XCTAssertEqual(after.routes.sorted(), ["0.0.0.0/1", "128.0.0.0/1", "8000::/1", "::/1"])
        XCTAssertEqual(after.generation, 6, "a successful swap must bump the generation")
    }

    // MARK: - Y4. IPv6 is routed in all mode

    /// `all` mode used to route only the IPv4 halves while AllowedIPs was ::/0,
    /// so IPv6 left in clear. `up` must add both IPv6 halves, record them, and
    /// `down` must remove them.
    func testAllModeUpAddsAndDownRemovesTheIPv6Halves() throws {
        let statePath = path("route-state.json")
        var events: [String] = []
        let manager = makeManager(statePath: statePath,
                                  events: { events.append($0) })

        let result = manager.up(mode: .all)
        XCTAssertTrue(result.ok, result.error ?? "")
        XCTAssertTrue(events.contains("net:::/1"), "\(events)")
        XCTAssertTrue(events.contains("net:8000::/1"), "\(events)")

        let state = RouteStateStore.load(path: statePath)
        XCTAssertTrue(state.routes.contains("::/1"), "\(state.routes)")
        XCTAssertTrue(state.routes.contains("8000::/1"), "\(state.routes)")

        events.removeAll()
        let down = makeManager(statePath: statePath, events: { events.append($0) }).down()
        XCTAssertTrue(down.ok, down.error ?? "")
        XCTAssertTrue(events.contains("-net:::/1"), "\(events)")
        XCTAssertTrue(events.contains("-net:8000::/1"), "\(events)")
        XCTAssertTrue(RouteStateStore.load(path: statePath).routes.isEmpty)
    }

    // MARK: - Y5. changeMode and switch share up()'s pending + rollback path

    private func saveDiscordState(_ statePath: String) {
        XCTAssertTrue(RouteStateStore.save(
            RouteState(mode: "discord", iface: "utun9",
                       routes: ["162.159.128.0/18", "162.159.192.0/24"],
                       hosts: ["203.0.113.69"], gateway: "192.168.1.1",
                       generation: 3),
            path: statePath))
    }

    /// A failed add half-way through a swap removes what the swap added,
    /// restores the old set, and leaves a non-pending state claiming it.
    func testChangeModeFailureMidwayRollsBackAndKeepsStateConsistent() throws {
        let statePath = path("route-state.json")
        saveDiscordState(statePath)
        var events: [String] = []
        var manager = makeManager(statePath: statePath,
                                  events: { events.append($0) },
                                  failOnNet: "128.0.0.0/1")
        manager.probeHostGateway = { _ in "192.168.1.1" }

        let result = manager.changeMode(to: .all)
        XCTAssertFalse(result.ok)

        XCTAssertTrue(events.contains("net:0.0.0.0/1"), "\(events)")
        XCTAssertTrue(events.contains("-net:0.0.0.0/1"),
                      "the prefix added before the failure was left installed: \(events)")
        let undo = try XCTUnwrap(events.lastIndex(of: "-net:0.0.0.0/1"))
        let restore = try XCTUnwrap(events.lastIndex(of: "net:162.159.128.0/18"),
                                    "the old set was not restored: \(events)")
        XCTAssertLessThan(undo, restore, "old set restored before the new one was removed: \(events)")

        let after = RouteStateStore.load(path: statePath)
        XCTAssertFalse(after.pending)
        XCTAssertEqual(after.mode, "discord")
        XCTAssertEqual(after.routes.sorted(), ["162.159.128.0/18", "162.159.192.0/24"])
        XCTAssertEqual(after.hosts, ["203.0.113.69"])
        XCTAssertEqual(after.generation, 3)
    }

    /// The intent is pending before the first route changes, so a crash at
    /// that point lets the next `down` remove both the old and the new set.
    func testChangeModeCrashMidwayIsCleanedUpByDown() throws {
        let statePath = path("route-state.json")
        saveDiscordState(statePath)
        var snapshot: RouteState?
        var manager = makeManager(statePath: statePath, events: { _ in })
        manager.probeHostGateway = { _ in "192.168.1.1" }
        manager.addNet = { _, _ in
            if snapshot == nil { snapshot = RouteStateStore.load(path: statePath) }
            return RouteManager.Mutation(ok: true, detail: "added")
        }
        XCTAssertTrue(manager.changeMode(to: .all).ok)

        // "Crash": the file as it was when the first new prefix went in.
        let crashed = try XCTUnwrap(snapshot)
        XCTAssertTrue(crashed.pending, "no pending intent before the first route")
        XCTAssertTrue(RouteStateStore.save(crashed, path: statePath))

        var removed: [String] = []
        var downer = makeManager(statePath: statePath, events: { _ in })
        downer.deleteNet = { removed.append($0); return true }
        XCTAssertTrue(downer.down().ok)
        XCTAssertEqual(Set(removed),
                       Set(RouteManager.ranges(for: .all) + RouteManager.ranges(for: .discord)))
        let after = RouteStateStore.load(path: statePath)
        XCTAssertFalse(after.pending)
        XCTAssertTrue(after.routes.isEmpty && after.hosts.isEmpty)
    }

    /// `switchTo` now applies routes through `apply`. A mid-way failure there
    /// rolls back this run's prefixes and keeps the previous server's pin
    /// claimed (it survives the interface going down).
    func testSwitchApplyFailureRollsBackAndKeepsOldPinClaimed() throws {
        let statePath = path("route-state.json")
        XCTAssertTrue(RouteStateStore.save(
            RouteState(mode: "all", hosts: ["198.51.100.7"], generation: 2),
            path: statePath))
        var events: [String] = []
        let manager = makeManager(statePath: statePath,
                                  events: { events.append($0) },
                                  failOnNet: "128.0.0.0/1")

        let result = manager.apply(mode: .all, iface: "utun9", gateway: "192.168.1.1",
                                   endpoint: "203.0.113.69", revertAfter: nil)
        XCTAssertFalse(result.ok)
        XCTAssertTrue(events.contains("-net:0.0.0.0/1"), "\(events)")
        XCTAssertTrue(events.contains("-pin:203.0.113.69"), "\(events)")
        let after = RouteStateStore.load(path: statePath)
        XCTAssertFalse(after.pending)
        XCTAssertEqual(after.hosts, ["198.51.100.7"])
        XCTAssertTrue(after.routes.isEmpty)
    }

    // MARK: - Managed config cleared at reboot / left at the 1.0.x path

    func testUpWithMissingManagedConfigFailsClearlyWithoutRunningWgQuick() {
        var manager = RouteManager(settle: 0, statePath: path("route-state.json"),
                                   managedConfigPath: path("absent/wgmanaged.conf"))
        manager.probeInterfaces = { [] }
        manager.run = { tool, _, _ in
            XCTFail("\(tool) ran on a missing config")
            return CommandResult(status: 1, output: "")
        }
        let result = manager.up(mode: .discord)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.error,
                       "tunnel config missing (cleared at restart); choose a server to recreate it")
    }

    /// Without a managed config the tunnel is stopped the way wg-quick does it
    /// on macOS: our interface's UAPI socket and name file go, nothing else.
    func testStopManagedTunnelWithoutConfigRemovesOnlyOurSocket() throws {
        let runDir = path("wireguard")
        try FileManager.default.createDirectory(atPath: runDir, withIntermediateDirectories: true)
        let fm = FileManager.default
        func touch(_ name: String, _ text: String = "") {
            fm.createFile(atPath: (runDir as NSString).appendingPathComponent(name),
                          contents: Data(text.utf8))
        }
        touch("wgmanaged.name", "utun7\n")
        touch("utun7.sock")
        touch("utun3.sock")
        XCTAssertTrue(WireGuardProfiles.stopManagedTunnel(config: path("absent.conf"),
                                                          runDir: runDir))
        XCTAssertFalse(fm.fileExists(atPath: runDir + "/utun7.sock"))
        XCTAssertFalse(fm.fileExists(atPath: runDir + "/wgmanaged.name"))
        XCTAssertTrue(fm.fileExists(atPath: runDir + "/utun3.sock"), "another tunnel was stopped")

        touch("wgmanaged.name", "../utun3")
        XCTAssertFalse(WireGuardProfiles.stopManagedTunnel(config: path("absent.conf"),
                                                           runDir: runDir))
        XCTAssertTrue(fm.fileExists(atPath: runDir + "/utun3.sock"))
    }
}
