import XCTest
@testable import MenfezCore

/// `down` and `sanity` against a damaged or partly failing state. No real
/// route is touched: the delete hooks are fakes.
final class RouteStateRecoveryTests: XCTestCase {
    private var dir: String!
    private var statePath: String { dir + "/route-state.json" }

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "menfez-recovery-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dir)
    }

    /// (a) A corrupt file must not read as "nothing installed".
    func testDownWithCorruptStateDeletesEveryKnownPrefix() throws {
        try "{ not json".write(toFile: statePath, atomically: true, encoding: .utf8)
        XCTAssertTrue(RouteStateStore.loadChecked(path: statePath).corrupt)
        XCTAssertFalse(RouteStateStore.loadChecked(path: dir + "/absent.json").corrupt)

        var deleted: [String] = []
        var m = RouteManager(settle: 0, statePath: statePath)
        m.deleteNet = { deleted.append($0); return $0 != "::/1" }
        let result = m.down()

        for cidr in ["0.0.0.0/1", "128.0.0.0/1", "::/1", "8000::/1"] + RouteManager.discordRanges {
            XCTAssertTrue(deleted.contains(cidr), "\(cidr) was not deleted")
        }
        XCTAssertFalse(result.ok)
        let after = RouteStateStore.loadChecked(path: statePath)
        XCTAssertFalse(after.corrupt)
        XCTAssertEqual(after.state.routes, ["::/1"], "a failed delete stays recorded")
        XCTAssertEqual(try String(contentsOfFile: statePath + ".corrupt", encoding: .utf8), "{ not json")
    }

    /// (b) `sanity` keeps the deletes that failed recorded (H5).
    func testSanityKeepsFailedDeletesRecorded() throws {
        guard RouteManager.interfaces().isEmpty else {
            throw XCTSkip("a WireGuard interface is up here; sanity would return early")
        }
        XCTAssertTrue(RouteStateStore.save(RouteState(mode: "all",
                                                      routes: ["0.0.0.0/1", "128.0.0.0/1"],
                                                      hosts: ["203.0.113.5"]),
                                           path: statePath))
        var m = RouteManager(settle: 0, statePath: statePath)
        m.deleteNet = { $0 != "128.0.0.0/1" }
        m.deleteHost = { _ in false }
        let result = m.sanity()
        XCTAssertFalse(result.ok)
        let after = RouteStateStore.load(path: statePath)
        XCTAssertEqual(after.mode, "off")
        XCTAssertEqual(after.routes, ["128.0.0.0/1"])
        XCTAssertEqual(after.hosts, ["203.0.113.5"])
    }

    /// An absent route counts as removed; a real failure does not.
    func testDeleteOfAbsentRouteIsSuccess() {
        XCTAssertTrue(RouteManager.deleted(CommandResult(
            status: 1, output: "route: writing to routing socket: not in table")))
        XCTAssertFalse(RouteManager.deleted(CommandResult(status: 1, output: "route: permission denied")))
        XCTAssertTrue(RouteManager.deleted(CommandResult(status: 0, output: "delete net 0.0.0.0")))
    }
}
