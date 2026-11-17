import XCTest
@testable import MenfezCore

/// K5: after a network change the endpoint pin must follow the new physical
/// gateway. Every route mutation is an injected closure; nothing touches the
/// table.
final class RepinTests: XCTestCase {

    private var statePath = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("menfez-repin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        statePath = (dir as NSString).appendingPathComponent("route-state.json")
        XCTAssertTrue(RouteStateStore.save(
            RouteState(mode: "all", iface: "utun9",
                       routes: RouteManager.ranges(for: .all),
                       hosts: ["203.0.113.69"], gateway: "192.168.1.1",
                       generation: 4),
            path: statePath))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: (statePath as NSString).deletingLastPathComponent)
        try super.tearDownWithError()
    }

    private func manager(gateway: String?, livePin: String?,
                         pins: @escaping (String) -> Void) -> RouteManager {
        var m = RouteManager(settle: 0, statePath: statePath)
        m.probeInterfaces = { ["utun9"] }
        m.probeEndpoint = { _ in "203.0.113.69" }
        m.probeGateway = { gateway }
        m.probeHostGateway = { _ in livePin }
        m.addHost = { ip, gw in
            pins("\(ip)->\(gw)")
            return RouteManager.Mutation(ok: true, detail: "replaced stale pin")
        }
        m.addNet = { _, _ in XCTFail("repin must not touch prefixes"); return .init(ok: false, detail: "") }
        m.deleteNet = { _ in XCTFail("repin must not touch prefixes"); return false }
        return m
    }

    func testRepinReplacesThePinWhenTheGatewayChanged() {
        var pins: [String] = []
        let result = manager(gateway: "10.0.0.1", livePin: "192.168.1.1",
                             pins: { pins.append($0) }).repin()
        XCTAssertTrue(result.ok, result.error ?? "")
        XCTAssertEqual(pins, ["203.0.113.69->10.0.0.1"])
        let state = RouteStateStore.load(path: statePath)
        XCTAssertEqual(state.gateway, "10.0.0.1")
        XCTAssertEqual(state.hosts, ["203.0.113.69"])
        XCTAssertFalse(state.pending)
        XCTAssertEqual(state.generation, 4, "a re-pin must not invalidate a revert timer")
        XCTAssertEqual(state.routes, RouteManager.ranges(for: .all))
    }

    func testRepinIsANoOpWhenTheGatewayIsUnchanged() {
        var pins: [String] = []
        let result = manager(gateway: "192.168.1.1", livePin: "192.168.1.1",
                             pins: { pins.append($0) }).repin()
        XCTAssertTrue(result.ok)
        XCTAssertTrue(pins.isEmpty, "\(pins)")
        XCTAssertEqual(RouteStateStore.load(path: statePath).gateway, "192.168.1.1")
    }

    func testRepinLeavesThePinAloneWithoutAPhysicalGateway() {
        var pins: [String] = []
        let result = manager(gateway: nil, livePin: "192.168.1.1",
                             pins: { pins.append($0) }).repin()
        XCTAssertTrue(result.ok)
        XCTAssertTrue(pins.isEmpty, "\(pins)")
        XCTAssertEqual(RouteStateStore.load(path: statePath).gateway, "192.168.1.1")
    }

    func testRepinDoesNothingWhenNoModeIsRouted() {
        XCTAssertTrue(RouteStateStore.save(RouteState(), path: statePath))
        var pins: [String] = []
        XCTAssertTrue(manager(gateway: "10.0.0.1", livePin: nil,
                              pins: { pins.append($0) }).repin().ok)
        XCTAssertTrue(pins.isEmpty)
    }

    /// `route get default` answering with the tunnel must not be read as a
    /// router to pin the endpoint to.
    func testPhysicalGatewayIgnoresADefaultViaTheTunnel() {
        struct Fake: CommandRunner {
            let output: String
            func run(_ tool: String, _ args: [String], timeout: TimeInterval) -> CommandResult {
                CommandResult(status: 0, output: output)
            }
        }
        let viaTunnel = "   route to: default\n    gateway: 10.2.0.2\n  interface: utun4\n"
        let viaWifi = "   route to: default\n    gateway: 192.168.7.1\n  interface: en0\n"
        XCTAssertNil(RouteManager.physicalGateway(using: Fake(output: viaTunnel)))
        XCTAssertEqual(RouteManager.physicalGateway(using: Fake(output: viaWifi)), "192.168.7.1")
    }

    // MARK: - Watcher

    func testWakeTriggersOneDebouncedRepinOnlyWhenActive() {
        let center = NotificationCenter()
        let fired = expectation(description: "repin")
        fired.expectedFulfillmentCount = 1
        fired.assertForOverFulfill = true
        let watcher = NetworkChangeWatcher(wakeCenter: center, debounce: 0.2,
                                           isActive: { true }) { fired.fulfill() }
        watcher.start()
        center.post(name: NetworkChangeWatcher.wakeNotification, object: nil)
        center.post(name: NetworkChangeWatcher.wakeNotification, object: nil)
        wait(for: [fired], timeout: 3)
        // Allow a second (wrong) firing to show up before the test ends.
        let settle = expectation(description: "settle")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { settle.fulfill() }
        wait(for: [settle], timeout: 2)
        _ = watcher
    }

    func testPathChangeAfterBaselineTriggersRepinButInactiveDoesNot() {
        let fired = expectation(description: "repin")
        let watcher = NetworkChangeWatcher(debounce: 0.1, isActive: { true }) { fired.fulfill() }
        watcher.onQueue {
            watcher.pathChanged("satisfied|en0|192.168.1.1")   // baseline, no call
            watcher.pathChanged("satisfied|en0|192.168.1.1")   // unchanged, no call
            watcher.pathChanged("satisfied|en0|10.0.0.1")      // changed
        }
        wait(for: [fired], timeout: 3)

        let quiet = expectation(description: "inactive")
        quiet.isInverted = true
        let idle = NetworkChangeWatcher(debounce: 0.1, isActive: { false }) { quiet.fulfill() }
        idle.onQueue {
            idle.pathChanged("a")
            idle.pathChanged("b")
        }
        wait(for: [quiet], timeout: 0.6)
    }
}
