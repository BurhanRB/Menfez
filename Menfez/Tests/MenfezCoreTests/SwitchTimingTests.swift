import Foundation
import XCTest
@testable import MenfezCore

/// Where a tunnel switch spends its time, on a fake clock.
final class SwitchTimingTests: XCTestCase {

    /// Drives `waitForProgress` with a clock that only moves when it sleeps.
    /// `rxAt`/`txAt` are when the transport shows a reply / any movement.
    private func run(rxAt: TimeInterval?, txAt: TimeInterval?, exists: Bool = true,
                     settle: TimeInterval = RouteManager.settleSeconds,
                     budget: TimeInterval = RouteManager.transportProbeBudget)
        -> (result: (healthy: Bool, reason: String), at: TimeInterval, kicks: Int) {
        var now: TimeInterval = 0
        var kicks = 0
        let result = RouteManager.waitForProgress(
            settle: settle, budget: budget, poll: RouteManager.transportPollSeconds,
            kick: { kicks += 1 },
            exists: { exists },
            progressed: { requireReceive in
                if let rxAt, now >= rxAt { return true }
                if !requireReceive, let txAt, now >= txAt { return true }
                return false
            },
            elapsed: { now },
            sleep: { now += $0 })
        return (result, now, kicks)
    }

    /// The reported case: a live tunnel answers the kick within one RTT, so
    /// the switch no longer waits for the 5 s settle or the next keepalive.
    func testReplyEndsTheWaitWithinHalfASecond() {
        let r = run(rxAt: 0.08, txAt: 0.0)
        XCTAssertTrue(r.result.healthy)
        XCTAssertEqual(r.kicks, 1)
        XCTAssertLessThanOrEqual(r.at, 0.5)
    }

    /// tx alone (a keepalive into a broken path looks like this) is not
    /// accepted before the settle: the early exit needs a reply.
    func testTxOnlyWaitsForTheSettleLikeBefore() {
        let r = run(rxAt: nil, txAt: 0.1)
        XCTAssertTrue(r.result.healthy)
        XCTAssertEqual(r.at, RouteManager.settleSeconds, accuracy: 0.001)
    }

    /// Old step was 5 s: movement at 11 s was seen at 15 s. Now at 11 s.
    func testLateMovementIsSeenOnTheNextSecond() {
        let r = run(rxAt: nil, txAt: 11)
        XCTAssertTrue(r.result.healthy)
        XCTAssertEqual(r.at, 11, accuracy: 0.001)
    }

    /// Rollback still happens: nothing moves, the budget runs out.
    func testNoMovementFailsAtTheBudget() {
        let r = run(rxAt: nil, txAt: nil)
        XCTAssertFalse(r.result.healthy)
        XCTAssertEqual(r.at, RouteManager.transportProbeBudget, accuracy: 0.001)
    }

    func testVanishedInterfaceFailsAtOnce() {
        let r = run(rxAt: 0, txAt: 0, exists: false)
        XCTAssertFalse(r.result.healthy)
        XCTAssertEqual(r.at, 0)
    }

    /// The kick target is routed into the tunnel in both modes.
    func testKickTargetIsInsideBothModesRoutes() {
        func inside(_ cidr: String) -> Bool {
            let parts = cidr.split(separator: "/")
            guard parts.count == 2, let bits = Int(parts[1]),
                  let net = ConnectRequest.dottedQuad(String(parts[0])),
                  let ip = ConnectRequest.dottedQuad(RouteManager.kickTarget) else { return false }
            let n = net.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            let a = ip.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            let mask: UInt32 = bits == 0 ? 0 : ~UInt32(0) << (32 - bits)
            return n & mask == a & mask
        }
        XCTAssertTrue(RouteManager.ranges(for: .discord).contains(where: inside))
        XCTAssertTrue(RouteManager.ranges(for: .all).contains(where: inside))
    }

    /// Leaving DPI mode does not wait for the 5 s drain of open tunnels; only
    /// the listener close is waited for.
    func testProxyStopDoesNotWaitForTheDrain() throws {
        let upstream = try FakeUpstream()
        defer { upstream.stop() }
        let engine = DPIEngine(configuration: .loopback)
        defer { engine.shutdown() }
        let port = try XCTUnwrap(engine.start().port)
        let client = try RawClient(port: port)
        defer { client.close() }
        try client.send("CONNECT 127.0.0.1:\(upstream.port) HTTP/1.1\r\n\r\n")
        _ = try client.readUntil([0x0d, 0x0a, 0x0d, 0x0a], timeout: 5)

        let started = Date()
        engine.stop()
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        print("TIMING: proxy stop with one open tunnel \(ms) ms")
        XCTAssertLessThan(ms, 1000)
    }
}
