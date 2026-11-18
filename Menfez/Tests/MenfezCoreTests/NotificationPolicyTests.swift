import XCTest
@testable import MenfezCore

final class NotificationPolicyTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testSameEventIsRateLimited() {
        var p = NotificationPolicy()
        XCTAssertTrue(p.shouldSend(.dpiStopped, at: t0, appActive: false, enabled: true))
        XCTAssertFalse(p.shouldSend(.dpiStopped, at: t0 + 60, appActive: false, enabled: true))
        XCTAssertFalse(p.shouldSend(.dpiStopped, at: t0 + NotificationPolicy.window - 1, appActive: false, enabled: true))
        XCTAssertTrue(p.shouldSend(.dpiStopped, at: t0 + NotificationPolicy.window, appActive: false, enabled: true))
        // Another event is not held back by the first.
        XCTAssertTrue(p.shouldSend(.serverRemoved, at: t0 + 61, appActive: false, enabled: true))
    }

    func testHelperUpdateAtMostDaily() {
        var p = NotificationPolicy()
        XCTAssertTrue(p.shouldSend(.helperUpdate, at: t0, appActive: false, enabled: true))
        XCTAssertFalse(p.shouldSend(.helperUpdate, at: t0 + 3600, appActive: false, enabled: true))
        XCTAssertTrue(p.shouldSend(.helperUpdate, at: t0 + NotificationPolicy.helperWindow, appActive: false, enabled: true))
    }

    func testSuppressedWhileActiveOrDisabledAndNotCounted() {
        var p = NotificationPolicy()
        XCTAssertFalse(p.shouldSend(.dpiStopped, at: t0, appActive: true, enabled: true))
        XCTAssertFalse(p.shouldSend(.dpiStopped, at: t0, appActive: false, enabled: false))
        // Neither suppressed attempt started the rate-limit window.
        XCTAssertTrue(p.shouldSend(.dpiStopped, at: t0 + 1, appActive: false, enabled: true))
    }

    func testRestoredOnlyAfterAnAnnouncedDrop() {
        var p = NotificationPolicy()
        XCTAssertFalse(p.shouldSend(.tunnelRestored, at: t0, appActive: false, enabled: true))
        // A drop the user did not see (window in front) gets no "restored".
        XCTAssertFalse(p.shouldSend(.tunnelDropped, at: t0, appActive: true, enabled: true))
        XCTAssertFalse(p.shouldSend(.tunnelRestored, at: t0 + 1, appActive: false, enabled: true))
        XCTAssertTrue(p.shouldSend(.tunnelDropped, at: t0 + 2, appActive: false, enabled: true))
        XCTAssertTrue(p.shouldSend(.tunnelRestored, at: t0 + 3, appActive: false, enabled: true))
        XCTAssertFalse(p.shouldSend(.tunnelRestored, at: t0 + 400, appActive: false, enabled: true))
    }

    func testTunnelEdges() {
        XCTAssertEqual(NotificationPolicy.tunnelEvent(wasLost: false, isLost: true, inTunnel: true, healthy: false), .tunnelDropped)
        XCTAssertEqual(NotificationPolicy.tunnelEvent(wasLost: true, isLost: false, inTunnel: true, healthy: true), .tunnelRestored)
        // Leaving Tunnel mode or a settling switch is not "restored".
        XCTAssertNil(NotificationPolicy.tunnelEvent(wasLost: true, isLost: false, inTunnel: false, healthy: false))
        XCTAssertNil(NotificationPolicy.tunnelEvent(wasLost: true, isLost: false, inTunnel: true, healthy: false))
        XCTAssertNil(NotificationPolicy.tunnelEvent(wasLost: true, isLost: true, inTunnel: true, healthy: false))
        XCTAssertNil(NotificationPolicy.tunnelEvent(wasLost: false, isLost: false, inTunnel: true, healthy: true))
    }

    func testDPIStoppedOnlyWhenStillSelected() {
        XCTAssertTrue(NotificationPolicy.dpiStoppedUnexpectedly(wasRunning: true, isRunning: false, dpiSelected: true))
        XCTAssertFalse(NotificationPolicy.dpiStoppedUnexpectedly(wasRunning: true, isRunning: false, dpiSelected: false))
        XCTAssertFalse(NotificationPolicy.dpiStoppedUnexpectedly(wasRunning: false, isRunning: false, dpiSelected: true))
    }

    func testSettingsDefaultOnAndRestoredFollowsDropped() {
        let d = UserDefaults(suiteName: "NotificationPolicyTests")!
        d.removePersistentDomain(forName: "NotificationPolicyTests")
        for e in NotificationEvent.allCases { XCTAssertTrue(e.isEnabled(d)) }
        d.set(false, forKey: NotificationEvent.tunnelDropped.defaultsKey)
        XCTAssertFalse(NotificationEvent.tunnelRestored.isEnabled(d))
        XCTAssertTrue(NotificationEvent.dpiStopped.isEnabled(d))
        XCTAssertFalse(NotificationEvent.settings.contains(.tunnelRestored))
        d.removePersistentDomain(forName: "NotificationPolicyTests")
    }
}
