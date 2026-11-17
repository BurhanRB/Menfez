import XCTest
@testable import MenfezCore

/// The kill-switch warning: shown only when tunnel mode is selected and the
/// report measured the tunnel as gone, down or stale — never on a guess.
final class TunnelLossTests: XCTestCase {

    private func report(tunnel: String?, _ code: Health.Code) -> Report {
        var r = Report()
        r.tunnel = tunnel
        r.health = Health(ok: code == .ok, code: code)
        return r
    }

    func testLostWhenTunnelModeAndInterfaceGoneDownOrStale() {
        XCTAssertTrue(TunnelLoss.isLost(runMode: .tunnel, report: report(tunnel: "utun5", .gone), settling: false))
        XCTAssertTrue(TunnelLoss.isLost(runMode: .tunnel, report: report(tunnel: "utun5", .stale), settling: false))
        XCTAssertTrue(TunnelLoss.isLost(runMode: .tunnel, report: report(tunnel: nil, .down), settling: false))
    }

    func testNotLostWhenHealthyOrUnmeasured() {
        XCTAssertFalse(TunnelLoss.isLost(runMode: .tunnel, report: report(tunnel: "utun5", .ok), settling: false))
        XCTAssertFalse(TunnelLoss.isLost(runMode: .tunnel, report: report(tunnel: "utun5", .unknown), settling: false))
        XCTAssertFalse(TunnelLoss.isLost(runMode: .tunnel, report: report(tunnel: "utun5", .noHandshake), settling: false))
        XCTAssertFalse(TunnelLoss.isLost(runMode: .tunnel, report: report(tunnel: nil, .unknown), settling: false))
        XCTAssertFalse(TunnelLoss.isLost(runMode: .tunnel, report: nil, settling: false))
    }

    func testNotLostOutsideTunnelModeOrWhileSettling() {
        let gone = report(tunnel: nil, .down)
        XCTAssertFalse(TunnelLoss.isLost(runMode: .direct, report: gone, settling: false))
        XCTAssertFalse(TunnelLoss.isLost(runMode: .dpi, report: gone, settling: false))
        XCTAssertFalse(TunnelLoss.isLost(runMode: .tunnel, report: gone, settling: true))
    }
}
