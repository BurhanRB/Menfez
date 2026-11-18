import XCTest
@testable import MenfezCore

/// `teardown` stops the interface `down` leaves up, and the app asks for it
/// when the server behind the tunnel is gone. Plus the helper version check
/// behind the "Update" notice. Nothing here touches a real route or tunnel.
final class TeardownTests: XCTestCase {

    private var dir: String!
    private var statePath: String { dir + "/route-state.json" }
    private var configPath: String { dir + "/wgmanaged.conf" }

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "menfez-teardown-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: configPath, contents: Data("[Interface]\n".utf8))
        RouteStateStore.save(RouteState(mode: "discord", iface: "utun7",
                                        routes: ["162.159.128.0/17"], hosts: ["185.1.1.1"],
                                        gateway: "192.168.1.1", generation: 3), path: statePath)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dir)
    }

    final class Calls: @unchecked Sendable {
        var stopped: [String] = []
        var deleted: [String] = []
        var up = ["utun7"]
    }

    private func manager(_ calls: Calls, stops: Bool = true) -> RouteManager {
        var m = RouteManager(settle: 0, statePath: statePath, managedConfigPath: configPath)
        m.deleteNet = { calls.deleted.append($0); return true }
        m.deleteHost = { calls.deleted.append($0); return true }
        m.probeInterfaces = { calls.up }
        m.stopTunnel = { path in
            calls.stopped.append(path)
            if stops { calls.up = [] }
            return stops
        }
        return m
    }

    func testTeardownRemovesRoutesStopsTheInterfaceAndDropsTheConfig() {
        let calls = Calls()
        let result = manager(calls).teardown()
        XCTAssertTrue(result.ok, result.error ?? "")
        XCTAssertEqual(result.mode, "off")
        XCTAssertEqual(Set(calls.deleted), ["162.159.128.0/17", "185.1.1.1"])
        XCTAssertEqual(calls.stopped, [configPath], "only the managed config is stopped")
        XCTAssertFalse(FileManager.default.fileExists(atPath: configPath), "the key copy is gone")
        let state = RouteStateStore.load(path: statePath)
        XCTAssertEqual(state.mode, "off")
        XCTAssertNil(state.iface)
        XCTAssertTrue(state.routes.isEmpty && state.hosts.isEmpty)
    }

    func testAnInterfaceThatWillNotStopKeepsItsConfigForTheNextTry() {
        let calls = Calls()
        let result = manager(calls, stops: false).teardown()
        XCTAssertFalse(result.ok)
        XCTAssertTrue(FileManager.default.fileExists(atPath: configPath))
        XCTAssertEqual(RouteStateStore.load(path: statePath).iface, "utun7")
    }

    func testNothingRunningIsStillASuccess() {
        let calls = Calls()
        calls.up = []
        let result = manager(calls, stops: false).teardown()
        XCTAssertTrue(result.ok)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configPath))
    }

    func testDownStillLeavesTheInterfaceForQuickModeSwitches() {
        let calls = Calls()
        XCTAssertTrue(manager(calls).down().ok)
        XCTAssertTrue(calls.stopped.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: configPath))
    }

    func testTearDownOnlyWhenTheDeletedProfileMayBackTheTunnel() {
        XCTAssertTrue(TunnelRecovery.shouldTearDown(deletedActive: true, deletedLastUsed: false, noProfilesLeft: false))
        XCTAssertTrue(TunnelRecovery.shouldTearDown(deletedActive: false, deletedLastUsed: true, noProfilesLeft: false))
        XCTAssertTrue(TunnelRecovery.shouldTearDown(deletedActive: false, deletedLastUsed: false, noProfilesLeft: true))
        XCTAssertFalse(TunnelRecovery.shouldTearDown(deletedActive: false, deletedLastUsed: false, noProfilesLeft: false))
    }

    // MARK: Helper version

    struct Fixed: CommandRunner {
        let result: CommandResult
        func run(_ tool: String, _ args: [String], timeout: TimeInterval) -> CommandResult { result }
    }

    func testHelperVersionComparison() {
        let current = Fixed(result: CommandResult(status: 0, output: "{\"version\":\(HelperVersion.current)}"))
        XCTAssertEqual(HelperVersion.installed(helper: "/x", using: current), HelperVersion.current)
        XCTAssertFalse(HelperVersion.needsUpdate(installed: HelperVersion.current))

        // A helper that predates `version` prints usage and exits 2.
        let old = Fixed(result: CommandResult(status: 2, output: "usage: menfez-route <command>"))
        XCTAssertEqual(HelperVersion.installed(helper: "/x", using: old), 0)
        XCTAssertTrue(HelperVersion.needsUpdate(installed: 0))

        let garbage = Fixed(result: CommandResult(status: 0, output: "not json"))
        XCTAssertEqual(HelperVersion.installed(helper: "/x", using: garbage), 0)
        XCTAssertTrue(HelperVersion.needsUpdate(installed: 1, bundled: 2))
        XCTAssertFalse(HelperVersion.needsUpdate(installed: 3, bundled: 2), "a newer helper is fine")
    }
}
