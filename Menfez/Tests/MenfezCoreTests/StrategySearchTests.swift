import XCTest
@testable import MenfezCore

final class StrategySearchTests: XCTestCase {

    private let ok = DPIProbeOutcome.Attempt(exit: 0, ms: 40)
    private let reset = DPIProbeOutcome.Attempt(exit: 35, error: "TLS handshake failed")
    private let dns = DPIProbeOutcome.Attempt(exit: 6, error: DPIProbe.dnsError)

    func testCandidatesSkipTheFailingLength() {
        XCTAssertEqual(StrategySearch.candidates(current: 40), [1, 2, 5, 100])
        XCTAssertEqual(StrategySearch.candidates(current: 77), [1, 2, 5, 40, 100])
    }

    func testDirectWorksMeansNotNeeded() {
        var tried: [Int] = []
        let out = StrategySearch.run(current: 40, direct: { ok }, attempt: { tried.append($0); return self.ok })
        XCTAssertEqual(out, .notNeeded)
        XCTAssertEqual(tried, [])
    }

    func testFirstSuccessStopsInOrder() {
        var tried: [Int] = []
        var shown: [String] = []
        let out = StrategySearch.run(current: 40, direct: { reset },
                                     attempt: { tried.append($0); return $0 == 5 ? self.ok : self.reset },
                                     progress: { shown.append("\($0)/\($1)") })
        XCTAssertEqual(out, .found(5))
        XCTAssertEqual(tried, [1, 2, 5])
        XCTAssertEqual(shown, ["1/4", "2/4", "3/4"])
    }

    func testNothingWorks() {
        var tried: [Int] = []
        let out = StrategySearch.run(current: 40, direct: { reset }, attempt: { tried.append($0); return self.reset })
        XCTAssertEqual(out, .noneWorked)
        XCTAssertEqual(tried, [1, 2, 5, 100])
    }

    func testDNSFailureStops() {
        XCTAssertEqual(StrategySearch.run(current: 40, direct: { dns }, attempt: { _ in self.ok }), .dnsBlocked)
        var tried: [Int] = []
        XCTAssertEqual(StrategySearch.run(current: 40, direct: { reset },
                                          attempt: { tried.append($0); return self.dns }), .dnsBlocked)
        XCTAssertEqual(tried, [1])
    }

    func testTotalCapStopsEarly() {
        // Each attempt "takes" 20 s: starts at 0, 20, 40; a fourth at 60 would end past the cap.
        var clock = Date(timeIntervalSince1970: 0)
        var tried: [Int] = []
        let out = StrategySearch.run(current: 40, direct: { reset },
                                     attempt: { tried.append($0); clock += 20; return self.reset },
                                     now: { clock })
        XCTAssertEqual(out, .noneWorked)
        XCTAssertEqual(tried, [1, 2, 5])
    }

    // MARK: - Per-network storage

    private func defaults() -> UserDefaults {
        let name = "StrategySearchTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testPerNetworkValueAndGlobalFallback() {
        let t = DPITuning(defaults: defaults())
        XCTAssertEqual(t.effective(for: "a"), TLSRecordReframer.firstRecordPayloadLimit)
        t.save(5, for: "a")
        XCTAssertEqual(t.effective(for: "a"), 5)
        XCTAssertEqual(t.effective(for: "b"), 40)
        XCTAssertEqual(t.effective(for: nil), 40)
        t.save(2, for: nil)   // unknown network: becomes the global default
        XCTAssertEqual(t.effective(for: "b"), 2)
        XCTAssertEqual(t.effective(for: "a"), 5)
        t.forget("a")
        XCTAssertEqual(t.effective(for: "a"), 2)
    }

    func testOutOfRangeIgnoredAndTableCapped() {
        let d = defaults()
        let t = DPITuning(defaults: d)
        t.save(0, for: "a")
        t.save(500, for: "a")
        XCTAssertNil(t.value(for: "a"))
        d.set(["x": 900], forKey: DPITuning.key)
        XCTAssertNil(t.value(for: "x"))
        for i in 0..<(DPITuning.maxNetworks + 5) { t.save(1, for: "n\(i)") }
        XCTAssertEqual((d.dictionary(forKey: DPITuning.key) ?? [:]).count, DPITuning.maxNetworks)
        XCTAssertEqual(t.value(for: "n\(DPITuning.maxNetworks + 4)"), 1)
    }

    func testEngineSplitCanChange() {
        let e = DPIEngine()
        XCTAssertEqual(e.splitAt, 40)
        e.setSplit(5)
        XCTAssertEqual(e.splitAt, 5)
        e.setSplit(0)
        XCTAssertEqual(e.splitAt, 5)
    }
}
