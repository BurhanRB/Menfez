import XCTest
@testable import MenfezCore

/// The "tunnel ready" line must not claim readiness while the server row says "none".
final class TunnelReadyKeyTests: XCTestCase {
    func testKeyFollowsProfiles() {
        let idle = Profile(name: "a", file: "a.conf")
        var live = Profile(name: "b", file: "b.conf")
        live.active = true
        XCTAssertEqual(Profile.tunnelReadyKey([]), "tunnel_ready_add")
        XCTAssertEqual(Profile.tunnelReadyKey([idle]), "tunnel_ready_pick")
        XCTAssertEqual(Profile.tunnelReadyKey([idle, live]), "tunnel_ready")
    }
}
