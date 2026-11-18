import XCTest
@testable import MenfezCore

/// A tunnel kept running on a server the user deleted (1.0.1): `down` leaves
/// the WireGuard interface up, deleting a profile outside Tunnel mode left it
/// there, and the next `up` re-routed through the deleted server.
final class OrphanTunnelTests: XCTestCase {

    private func profile(_ name: String, key: String?) -> Profile {
        Profile(name: name, file: "/p/\(name).conf", peerKey: key)
    }

    // MARK: - The decision

    func testOnlyOurOwnInterfaceCanBeOrphaned() {
        XCTAssertFalse(TunnelRecovery.isOrphan(liveIface: "utun7", stateIface: "utun5",
                                               livePeerKey: "K", profiles: []),
                       "another client's utun is never touched")
        XCTAssertFalse(TunnelRecovery.isOrphan(liveIface: nil, stateIface: "utun5",
                                               livePeerKey: nil, profiles: []))
    }

    func testNoProfileLeftMeansOrphaned() {
        XCTAssertTrue(TunnelRecovery.isOrphan(liveIface: "utun5", stateIface: "utun5",
                                              livePeerKey: nil, profiles: []))
    }

    func testPeerKeyDecides() {
        let list = [profile("de-1", key: "NEW"), profile("nl-1", key: "OTHER")]
        XCTAssertTrue(TunnelRecovery.isOrphan(liveIface: "utun5", stateIface: "utun5",
                                              livePeerKey: "OLD", profiles: list),
                      "deleted or replaced: no file has the live key")
        XCTAssertFalse(TunnelRecovery.isOrphan(liveIface: "utun5", stateIface: "utun5",
                                               livePeerKey: "NEW", profiles: list))
        XCTAssertFalse(TunnelRecovery.isOrphan(liveIface: "utun5", stateIface: "utun5",
                                               livePeerKey: nil, profiles: list),
                       "unknown key: never tear down on a guess")
    }

    func testRenamedProfileStillBacksItsTunnel() {
        // Same key under a new name, while the state file still says the old one.
        XCTAssertFalse(TunnelRecovery.isOrphan(liveIface: "utun5", stateIface: "utun5",
                                               livePeerKey: "K", profiles: [profile("renamed", key: "K")]))
    }

    func testOnlyACarryingOrphanIsReleased() {
        let idle = RouteState(mode: "off", iface: "utun5")
        XCTAssertFalse(TunnelRecovery.shouldRelease(liveIface: "utun5", state: idle,
                                                    livePeerKey: "OLD", profiles: []))
        let tunnel = RouteState(mode: "discord", iface: "utun5", routes: ["162.159.128.0/19"])
        XCTAssertTrue(TunnelRecovery.shouldRelease(liveIface: "utun5", state: tunnel,
                                                   livePeerKey: "OLD", profiles: []))
        let hybrid = RouteState(mode: "updates", iface: "utun5", hosts: ["192.0.2.1"])
        XCTAssertTrue(TunnelRecovery.shouldRelease(liveIface: "utun5", state: hybrid,
                                                   livePeerKey: "OLD", profiles: [profile("x", key: "NEW")]))
        XCTAssertFalse(TunnelRecovery.shouldRelease(liveIface: "utun5", state: tunnel,
                                                    livePeerKey: "NEW", profiles: [profile("x", key: "NEW")]))
    }

    func testStaleStartPlansARebuildFromAnExistingProfile() {
        XCTAssertEqual(TunnelRecovery.plan(code: nil, lastProfile: "de-1", available: ["de-1"], stale: true),
                       .switchTo("de-1"))
        XCTAssertEqual(TunnelRecovery.plan(code: nil, lastProfile: "gone", available: [], stale: true),
                       .chooseServer)
    }

    // MARK: - Active row by key

    func testListMarksActiveByPeerKeyNotEndpointText() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orphan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func write(_ name: String, endpoint: String, key: String) throws {
            try "[Interface]\nAddress = 10.0.0.2/32\n[Peer]\nPublicKey = \(key)\nEndpoint = \(endpoint)\n"
                .write(to: dir.appendingPathComponent(name + ".conf"), atomically: true, encoding: .utf8)
        }
        // A hostname endpoint never contains the live IP.
        try write("byname", endpoint: "vpn.example.test:51820", key: "LIVE")
        try write("other", endpoint: "198.51.100.7:51820", key: "OTHER")

        let byKey = WireGuardProfiles.list(directory: dir.path, liveHost: "198.51.100.9", livePeerKey: "LIVE")
        XCTAssertEqual(byKey.filter(\.active).map(\.name), ["byname"])
        XCTAssertEqual(byKey.first?.peerKey, "LIVE")

        let byHost = WireGuardProfiles.list(directory: dir.path, liveHost: "198.51.100.7")
        XCTAssertEqual(byHost.filter(\.active).map(\.name), ["other"], "no key known: endpoint fallback")
    }

    // MARK: - HelperTunnel refuses to revive an orphan

    private final class Script: @unchecked Sendable {
        let lock = NSLock()
        var calls: [String] = []
        let replies: [String: String]
        init(_ replies: [String: String]) { self.replies = replies }
        func client() -> HelperClient {
            HelperClient(helper: "/h") { _, args, _ in
                let sub = args.drop(while: { $0 != "/h" }).dropFirst().first ?? ""
                self.lock.lock(); self.calls.append(sub); self.lock.unlock()
                return CommandResult(status: 0, output: self.replies[sub] ?? #"{"ok":false}"#)
            }
        }
    }

    private let ours = RouteState(mode: "off", iface: "utun5")
    private let factsOld = #"{"tunnel":"utun5","peer_pubkey":"OLD"}"#

    func testStartWithNoProfileLeftDoesNotRunUp() {
        let script = Script(["up": #"{"ok":true,"mode":"discord"}"#])
        let state = ours
        let tunnel = HelperTunnel(client: script.client(), interfaces: { ["utun5"] },
                                  routeState: { state }, lastProfile: { "gone" },
                                  profileNames: { [] }, profileList: { [] })
        let outcome = tunnel.start(mode: .discord)
        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(outcome.recovery, .chooseServer)
        XCTAssertEqual(script.calls, [], "the user's bug: `up` re-routed through the deleted server")
    }

    func testStartOverAnOrphanSwitchesToAnExistingProfile() {
        let script = Script(["facts": factsOld, "switch": #"{"ok":true,"mode":"discord"}"#])
        let state = ours
        let tunnel = HelperTunnel(client: script.client(), interfaces: { ["utun5"] },
                                  routeState: { state }, lastProfile: { "de-1" },
                                  profileNames: { ["de-1"] },
                                  profileList: { [Profile(name: "de-1", file: "/p", peerKey: "NEW")] })
        let outcome = tunnel.start(mode: .discord)
        XCTAssertTrue(outcome.ok)
        XCTAssertEqual(outcome.recovery, .reconnected("de-1"))
        XCTAssertEqual(script.calls, ["facts", "switch"], "`switch` stops the old interface first")
    }

    func testStartOverOurMatchingInterfaceStillRunsUp() {
        let script = Script(["facts": factsOld, "up": #"{"ok":true,"mode":"discord"}"#])
        let state = ours
        let tunnel = HelperTunnel(client: script.client(), interfaces: { ["utun5"] },
                                  routeState: { state }, lastProfile: { "de-1" },
                                  profileNames: { ["de-1"] },
                                  profileList: { [Profile(name: "de-1", file: "/p", peerKey: "OLD")] })
        XCTAssertTrue(tunnel.start(mode: .discord).ok)
        XCTAssertEqual(script.calls, ["facts", "up"])
    }

    func testHybridUpdatesStartOverAnOrphanDoesNotRunUp() {
        let script = Script([:])
        let state = ours
        let tunnel = HelperTunnel(client: script.client(), interfaces: { ["utun5"] },
                                  routeState: { state }, profileNames: { [] }, profileList: { [] })
        let outcome = tunnel.startUpdates(UpdateRoutes(hosts: ["162.159.137.232"], resolvers: []))
        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(script.calls, [])
    }

    func testAnotherClientsInterfaceIsLeftToUp() {
        let script = Script(["up": #"{"ok":true,"mode":"discord"}"#])
        let tunnel = HelperTunnel(client: script.client(), interfaces: { ["utun9"] },
                                  routeState: { RouteState(mode: "off", iface: "utun5") },
                                  profileNames: { [] }, profileList: { [] })
        XCTAssertTrue(tunnel.start(mode: .discord).ok)
        XCTAssertEqual(script.calls, ["up"])
    }

    // MARK: - releaseTunnel

    @MainActor
    func testReleaseInTunnelModeGoesDirect() async {
        let engine = DPIEngine()
        defer { engine.shutdown() }
        let tunnel = HybridUpdatesTests.Tunnel()
        let c = ModeCoordinator(dpi: DPIMode(engine: engine, tunnelInterfaces: { [] }), tunnel: tunnel)
        await c.switchTo(.tunnel)
        let state = await c.releaseTunnel()
        XCTAssertTrue(state.ok)
        XCTAssertEqual(state.mode, .direct)
        XCTAssertEqual(tunnel.calls.last, "stop")
        XCTAssertFalse(tunnel.isCarryingTraffic())
    }

    @MainActor
    func testReleaseBesideDPIStopsOnlyTheUpdatesTunnel() async {
        let engine = DPIEngine()
        defer { engine.shutdown() }
        let tunnel = HybridUpdatesTests.Tunnel()
        let c = ModeCoordinator(dpi: DPIMode(engine: engine, tunnelInterfaces: { [] }), tunnel: tunnel)
        c.updateRoutes = { UpdateRoutes(hosts: ["162.159.137.232"], resolvers: []) }
        await c.switchTo(.dpi)
        XCTAssertTrue(tunnel.isUpdatesOnly())
        let state = await c.releaseTunnel()
        XCTAssertTrue(state.ok)
        XCTAssertEqual(state.mode, .dpi, "the proxy keeps Discord working")
        XCTAssertTrue(c.proxy.running)
        XCTAssertFalse(tunnel.isTunnelUp())
    }

    @MainActor
    func testReleaseWithNothingUpIsANoOp() async {
        let tunnel = HybridUpdatesTests.Tunnel()
        let engine = DPIEngine()
        defer { engine.shutdown() }
        let c = ModeCoordinator(dpi: DPIMode(engine: engine, tunnelInterfaces: { [] }), tunnel: tunnel)
        let state = await c.releaseTunnel()
        XCTAssertTrue(state.ok)
        XCTAssertEqual(state.mode, .direct)
        XCTAssertEqual(tunnel.calls, [])
    }
}
