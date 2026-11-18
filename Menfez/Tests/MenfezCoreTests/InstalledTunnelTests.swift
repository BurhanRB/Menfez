import XCTest
@testable import MenfezCore

/// The helper installed after launch must count without a relaunch, and a
/// removed one must stop counting (owner repro: brew upgrade, Set up tunnel,
/// Tunnel still said "no privileged helper" until restart).
final class InstalledTunnelTests: XCTestCase {
    /// A helper that works: down until started.
    private final class Up: TunnelControl, @unchecked Sendable {
        var up = false
        func isTunnelUp() -> Bool { up }
        func start(mode: Mode) -> TunnelOutcome { up = true; return TunnelOutcome(ok: true, message: "up") }
        func stop() -> TunnelOutcome { up = false; return TunnelOutcome(ok: true, message: "down") }
        func routeMode() -> String { up ? "all" : Mode.off.rawValue }
    }

    private final class Flag: @unchecked Sendable { var on = false }

    func testFollowsTheHelperOnEveryCall() {
        let flag = Flag()
        let tunnel = InstalledTunnel(installed: { flag.on }, helper: Up())

        XCTAssertFalse(tunnel.start(mode: .all).ok)
        XCTAssertEqual(tunnel.start(mode: .all).message, NoTunnel.message)
        XCTAssertFalse(tunnel.isTunnelUp())
        XCTAssertEqual(tunnel.routeMode(), Mode.off.rawValue)

        flag.on = true   // "Set up tunnel" finished
        XCTAssertTrue(tunnel.start(mode: .all).ok)
        XCTAssertTrue(tunnel.isTunnelUp())
        XCTAssertEqual(tunnel.routeMode(), "all")

        flag.on = false  // helper removed
        XCTAssertFalse(tunnel.start(mode: .all).ok)
        XCTAssertFalse(tunnel.isTunnelUp())
    }

    @MainActor func testCoordinatorPicksUpALateInstall() async {
        let flag = Flag()
        let coordinator = ModeCoordinator(tunnel: InstalledTunnel(installed: { flag.on }, helper: Up()))
        let refused = await coordinator.switchTo(.tunnel)
        XCTAssertFalse(refused.ok)
        flag.on = true
        let started = await coordinator.switchTo(.tunnel)
        XCTAssertTrue(started.ok, started.message)
    }
}
