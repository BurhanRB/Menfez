import XCTest
@testable import MenfezCore

/// Feature 4: when the automatic reconnect tries what, and when it stops.
final class ReconnectTests: XCTestCase {

    private func lost(_ current: String? = "A", ranked: [String] = ["A", "B", "C"],
                      allowSwitch: Bool = false, path: Bool = true) -> Reconnect.Input {
        Reconnect.Input(active: true, lost: true, healthy: false, pathSatisfied: path,
                        current: current, ranked: ranked, allowSwitch: allowSwitch)
    }

    private let healthy = Reconnect.Input(active: true, lost: false, healthy: true, pathSatisfied: true,
                                          current: "A", ranked: ["A"], allowSwitch: false)

    /// Feed `input` once per second from t0 until `seconds`; collect attempts with their time.
    private func run(_ r: inout Reconnect, _ input: Reconnect.Input, from t0: Date,
                     seconds: Int) -> [(Int, Reconnect.Decision)] {
        var out: [(Int, Reconnect.Decision)] = []
        for s in 0...seconds {
            let d = r.observe(input, now: t0.addingTimeInterval(TimeInterval(s)))
            if d != .none { out.append((s, d)) }
        }
        return out
    }

    func testBackoffTimingAndOrderSameServer() {
        var r = Reconnect()
        let events = run(&r, lost(), from: Date(), seconds: 2000)
        XCTAssertEqual(events.map(\.0), [5, 20, 80, 380, 680, 980, 1280])
        XCTAssertEqual(events.map(\.1), [.attempt(.repin), .attempt(.restart("A")), .attempt(.restart("A")),
                                         .attempt(.restart("A")), .attempt(.restart("A")),
                                         .attempt(.restart("A")), .gaveUp])
        XCTAssertTrue(r.gaveUp)
        XCTAssertEqual(r.attempts, Reconnect.maxAttempts)
    }

    func testSwitchesToNextFastestOnlyWhenAllowed() {
        var r = Reconnect()
        let events = run(&r, lost(ranked: ["B", "A", "C"], allowSwitch: true), from: Date(), seconds: 700)
        XCTAssertEqual(events.map(\.1), [.attempt(.repin), .attempt(.restart("A")), .attempt(.switchTo("B")),
                                         .attempt(.switchTo("C")), .attempt(.switchTo("B"))])
    }

    func testSingleServerUserNeverSwitches() {
        XCTAssertEqual(Reconnect.step(index: 2, current: "A", ranked: ["A"], allowSwitch: true), .restart("A"))
        XCTAssertEqual(Reconnect.step(index: 3, current: nil, ranked: [], allowSwitch: true), .repin)
        XCTAssertEqual(Reconnect.step(index: 0, current: "A", ranked: ["A", "B"], allowSwitch: true), .repin)
    }

    func testNoAttemptWithoutNetwork() {
        var r = Reconnect()
        let t0 = Date()
        XCTAssertTrue(run(&r, lost(path: false), from: t0, seconds: 3000).isEmpty)
        XCTAssertEqual(r.attempts, 0)
        // Network back: the clock starts then, first attempt after 5 s.
        let t1 = t0.addingTimeInterval(4000)
        XCTAssertEqual(r.observe(lost(), now: t1), .none)
        XCTAssertEqual(r.observe(lost(), now: t1.addingTimeInterval(5)), .attempt(.repin))
    }

    func testRecoveredAfterAttemptOnlyWhenMeasuredHealthy() {
        var r = Reconnect()
        let t0 = Date()
        _ = r.observe(lost(), now: t0)
        XCTAssertEqual(r.observe(lost(), now: t0.addingTimeInterval(5)), .attempt(.repin))
        // Settling after our own attempt: not lost, not healthy yet. Keep waiting.
        let settling = Reconnect.Input(active: true, lost: false, healthy: false, pathSatisfied: true,
                                       current: "A", ranked: ["A"], allowSwitch: false)
        XCTAssertEqual(r.observe(settling, now: t0.addingTimeInterval(6)), .none)
        XCTAssertEqual(r.attempts, 1)
        XCTAssertEqual(r.observe(healthy, now: t0.addingTimeInterval(8)), .recovered)
        XCTAssertEqual(r, Reconnect())
    }

    func testHealthyWithoutAttemptsIsSilent() {
        var r = Reconnect()
        _ = r.observe(lost(), now: Date())
        XCTAssertEqual(r.observe(healthy, now: Date()), .none)
    }

    func testAfterGivingUpWaitsQuietlyThenResetsWhenHealthy() {
        var r = Reconnect()
        let t0 = Date()
        _ = run(&r, lost(), from: t0, seconds: 1300)
        XCTAssertTrue(r.gaveUp)
        XCTAssertEqual(r.observe(lost(), now: t0.addingTimeInterval(5000)), .none)
        XCTAssertEqual(r.observe(healthy, now: t0.addingTimeInterval(5001)), .none, "no 'reconnected' after giving up")
        XCTAssertFalse(r.gaveUp)
    }

    func testInactiveStopsTheMachine() {
        var r = Reconnect()
        let t0 = Date()
        _ = run(&r, lost(), from: t0, seconds: 30)
        XCTAssertEqual(r.attempts, 2)
        var off = lost()
        off.active = false
        XCTAssertEqual(r.observe(off, now: t0.addingTimeInterval(31)), .none)
        XCTAssertEqual(r, Reconnect())
    }

    func testDefaults() {
        let d = UserDefaults(suiteName: "reconnect-tests-\(UUID().uuidString)")!
        XCTAssertTrue(Reconnect.isAuto(d), "reconnect is on by default (AS-10)")
        XCTAssertFalse(Reconnect.allowsSwitch(d), "switching server is off by default (AS-10)")
    }
}
