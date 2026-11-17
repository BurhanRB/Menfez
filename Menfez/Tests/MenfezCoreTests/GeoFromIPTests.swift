import XCTest
@testable import MenfezCore

/// The profile list used to wait on one ipinfo request per unknown server, on
/// the main thread, every time it was listed, and a failure was never
/// remembered. These pin the caching rules that make a listing cheap.
final class GeoFromIPTests: XCTestCase {

    /// Counts curl calls; answers with a fixed result.
    final class FakeCurl: CommandRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        let result: CommandResult
        init(_ result: CommandResult) { self.result = result }
        var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
        func run(_ tool: String, _ args: [String], timeout: TimeInterval) -> CommandResult {
            lock.lock(); _calls.append(args.last ?? ""); lock.unlock()
            return result
        }
    }

    private var cache = ""

    override func setUp() {
        super.setUp()
        cache = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("menfez-geo-\(UUID().uuidString)/geo-cache.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(
            atPath: (cache as NSString).deletingLastPathComponent)
        super.tearDown()
    }

    private let failing = CommandResult(status: 7, output: "")
    private let answering = CommandResult(status: 0, output: #"{"country":"ro","city":"Bucharest"}"#)
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testFailureIsCachedAndNotRetriedWithinTTL() {
        let curl = FakeCurl(failing)
        XCTAssertEqual(GeoFromIP.countries(forIPs: ["203.0.113.7"], cachePath: cache,
                                           using: curl, now: t0), [:])
        XCTAssertEqual(curl.calls.count, 1)
        _ = GeoFromIP.countries(forIPs: ["203.0.113.7"], cachePath: cache,
                                using: curl, now: t0.addingTimeInterval(GeoFromIP.failureTTL - 1))
        XCTAssertEqual(curl.calls.count, 1, "a failure inside the TTL must not be re-asked")
    }

    func testFailureIsRetriedAfterTTL() {
        _ = GeoFromIP.countries(forIPs: ["203.0.113.7"], cachePath: cache,
                                using: FakeCurl(failing), now: t0)
        let curl = FakeCurl(answering)
        let found = GeoFromIP.countries(forIPs: ["203.0.113.7"], cachePath: cache,
                                        using: curl, now: t0.addingTimeInterval(GeoFromIP.failureTTL + 1))
        XCTAssertEqual(curl.calls.count, 1)
        XCTAssertEqual(found, ["203.0.113.7": "RO"])
    }

    func testSuccessIsCachedForAWeek() {
        _ = GeoFromIP.countries(forIPs: ["203.0.113.7"], cachePath: cache,
                                using: FakeCurl(answering), now: t0)
        let curl = FakeCurl(failing)
        let found = GeoFromIP.countries(forIPs: ["203.0.113.7"], cachePath: cache,
                                        using: curl, now: t0.addingTimeInterval(GeoFromIP.failureTTL * 5))
        XCTAssertEqual(curl.calls.count, 0)
        XCTAssertEqual(found, ["203.0.113.7": "RO"])
    }

    func testNonIPHostsAreSkipped() {
        let curl = FakeCurl(answering)
        let found = GeoFromIP.countries(forIPs: ["vpn.example.com", "", "not an ip", "2001:db8::1"],
                                        cachePath: cache, using: curl, now: t0)
        XCTAssertEqual(curl.calls, ["https://ipinfo.io/2001:db8::1/json"])
        XCTAssertEqual(found, ["2001:db8::1": "RO"])
    }

    /// Several misses: each asked once, all written in one cache that a second
    /// pass answers from without any request.
    func testManyMissesShareOneCache() {
        let ips = (1...9).map { "203.0.113.\($0)" }
        let curl = FakeCurl(answering)
        XCTAssertEqual(GeoFromIP.countries(forIPs: ips + ips, cachePath: cache,
                                           using: curl, now: t0).count, 9)
        XCTAssertEqual(Set(curl.calls).count, 9)
        XCTAssertEqual(curl.calls.count, 9)
        let again = FakeCurl(failing)
        XCTAssertEqual(GeoFromIP.countries(forIPs: ips, cachePath: cache,
                                           using: again, now: t0).count, 9)
        XCTAssertEqual(again.calls.count, 0)
    }
}
