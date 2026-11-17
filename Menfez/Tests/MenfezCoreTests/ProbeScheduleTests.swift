import XCTest
@testable import MenfezCore

final class ProbeScheduleTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testFirstProbeRunsThenTTLGatesActivation() {
        var s = ProbeSchedule(ttl: 60)
        let token = s.start(now: t0, settling: false)
        XCTAssertNotNil(token)
        XCTAssertTrue(s.land(token!, now: t0))
        XCTAssertNil(s.start(now: t0 + 30, settling: false), "activation within the TTL")
        XCTAssertNotNil(s.start(now: t0 + 61, settling: false), "activation after the TTL")
    }

    func testRefreshButtonIgnoresTheTTL() {
        var s = ProbeSchedule(ttl: 60)
        _ = s.land(s.start(now: t0, settling: false)!, now: t0)
        XCTAssertNotNil(s.start(now: t0 + 5, settling: false, force: true))
    }

    /// A switch voids the running probe: its late result is dropped and a new
    /// one may start at once, without waiting for the old one.
    func testResultFromBeforeASwitchIsDropped() {
        var s = ProbeSchedule(ttl: 60)
        let old = s.start(now: t0, settling: false)!
        s.invalidate()
        let fresh = s.start(now: t0 + 1, settling: false)
        XCTAssertNotNil(fresh)
        XCTAssertFalse(s.land(old, now: t0 + 2), "stale generation")
        XCTAssertTrue(s.land(fresh!, now: t0 + 3))
    }

    /// While a switch is running or settling the probe is deferred, not lost,
    /// and the TTL does not swallow it afterwards.
    func testProbeDuringSettlingIsDeferredUntilItEnds() {
        var s = ProbeSchedule(ttl: 60)
        _ = s.land(s.start(now: t0, settling: false)!, now: t0)
        s.invalidate()
        XCTAssertNil(s.start(now: t0 + 1, settling: true))
        XCTAssertTrue(s.pending)
        XCTAssertNotNil(s.start(now: t0 + 9, settling: false))
        XCTAssertFalse(s.pending)
    }

    func testNoSecondProbeForTheSameGeneration() {
        var s = ProbeSchedule(ttl: 60)
        XCTAssertNotNil(s.start(now: t0, settling: false))
        XCTAssertNil(s.start(now: t0, settling: false, force: true))
    }
}
