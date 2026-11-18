import XCTest
@testable import MenfezCore

/// Feature 4: ping parsing, host safety, ranking, bounded parallelism, cache.
final class ServerLatencyTests: XCTestCase {

    let full = """
    PING 1.1.1.1 (1.1.1.1): 56 data bytes
    64 bytes from 1.1.1.1: icmp_seq=0 ttl=57 time=41.9 ms
    64 bytes from 1.1.1.1: icmp_seq=1 ttl=57 time=42.3 ms
    64 bytes from 1.1.1.1: icmp_seq=2 ttl=57 time=42.1 ms

    --- 1.1.1.1 ping statistics ---
    3 packets transmitted, 3 packets received, 0.0% packet loss
    round-trip min/avg/max/stddev = 41.900/42.100/42.300/0.163 ms
    """

    func testParsesAverage() {
        XCTAssertEqual(ServerLatency.parse(full), 42)
    }

    func testPartialLossStillHasAverage() {
        let partial = """
        Request timeout for icmp_seq 0
        --- x ping statistics ---
        3 packets transmitted, 1 packets received, 66.7% packet loss
        round-trip min/avg/max/stddev = 87.512/87.512/87.512/0.000 ms
        """
        XCTAssertEqual(ServerLatency.parse(partial), 88)
    }

    func testPing6AndSubMillisecond() {
        XCTAssertEqual(ServerLatency.parse("round-trip min/avg/max/std-dev = 0.118/0.158/0.197/0.040 ms"), 1)
    }

    func testNoReplyCases() {
        let lost = """
        PING 192.0.2.1 (192.0.2.1): 56 data bytes
        Request timeout for icmp_seq 0
        --- 192.0.2.1 ping statistics ---
        3 packets transmitted, 0 packets received, 100.0% packet loss
        """
        XCTAssertNil(ServerLatency.parse(lost))
        XCTAssertNil(ServerLatency.parse("ping: cannot resolve nonexistent.invalid: Unknown host"))
        XCTAssertNil(ServerLatency.parse(""))
        XCTAssertNil(ServerLatency.parse("round-trip min/avg/max/stddev = nan/nan/nan/nan ms"))
    }

    func testSafeHost() {
        XCTAssertEqual(ServerLatency.safeHost("vpn.example.com"), "vpn.example.com")
        XCTAssertEqual(ServerLatency.safeHost("[2001:db8::1]"), "2001:db8::1")
        XCTAssertEqual(ServerLatency.safeHost("203.0.113.9"), "203.0.113.9")
        XCTAssertNil(ServerLatency.safeHost("-f"))
        XCTAssertNil(ServerLatency.safeHost("-c100 x"))
        XCTAssertNil(ServerLatency.safeHost("a b"))
        XCTAssertNil(ServerLatency.safeHost("a;rm"))
        XCTAssertNil(ServerLatency.safeHost(""))
        XCTAssertNil(ServerLatency.safeHost(nil))
        XCTAssertNil(ServerLatency.safeHost(String(repeating: "a", count: 254)))
    }

    func testCommandUsesPing6ForIPv6() {
        XCTAssertEqual(ServerLatency.command(for: "1.2.3.4").tool, "/sbin/ping")
        XCTAssertEqual(ServerLatency.command(for: "1.2.3.4").args, ["-c", "3", "-t", "3", "1.2.3.4"])
        XCTAssertEqual(ServerLatency.command(for: "2001:db8::1").tool, "/sbin/ping6")
        XCTAssertEqual(ServerLatency.command(for: "2001:db8::1").args.last, "2001:db8::1")
    }

    func testRankRepliesFirstNoReplyLastStable() {
        let results: [String: ServerLatency.Result] = ["a": .noReply, "b": .ms(80), "c": .ms(20), "d": .ms(80), "e": .noReply]
        XCTAssertEqual(ServerLatency.rank(["a", "b", "c", "d", "e", "f"], results), ["c", "b", "d", "a", "e", "f"])
        XCTAssertEqual(ServerLatency.fastest(["a", "b", "c"], results), "c")
        XCTAssertNil(ServerLatency.fastest(["a", "e"], results), "a silent server is never picked")
        XCTAssertEqual(ServerLatency.rank(["x", "y"], [:]), ["x", "y"])
    }

    /// Counts concurrent runs; answers like ping.
    final class SlowPing: CommandRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var running = 0
        private(set) var peak = 0
        private(set) var calls: [[String]] = []
        func run(_ tool: String, _ args: [String], timeout: TimeInterval) -> CommandResult {
            lock.lock(); running += 1; peak = max(peak, running); calls.append([tool] + args); lock.unlock()
            Thread.sleep(forTimeInterval: 0.05)
            lock.lock(); running -= 1; lock.unlock()
            if args.last == "10.0.0.9" { return CommandResult(status: 2, output: "100.0% packet loss") }
            return CommandResult(status: 0, output: "round-trip min/avg/max/stddev = 1/12.4/20/1 ms")
        }
    }

    func testMeasureIsBoundedAndSkipsUnsafeHosts() {
        let runner = SlowPing()
        var hosts: [String: String?] = [:]
        for i in 0..<9 { hosts["s\(i)"] = "10.0.0.\(i + 1)" }
        hosts["evil"] = "-f"
        hosts["none"] = .some(nil)
        let results = ServerLatency.measure(hosts, using: runner)
        XCTAssertLessThanOrEqual(runner.peak, ServerLatency.maxParallel)
        XCTAssertEqual(runner.calls.count, 9, "unsafe and missing hosts never reach ping")
        XCTAssertEqual(results["s0"], .ms(12))
        XCTAssertEqual(results["s8"], .noReply)
        XCTAssertEqual(results["evil"], .noReply)
        XCTAssertEqual(results["none"], .noReply)
        XCTAssertEqual(results.count, 11)
    }

    func testCacheExpiresAfterFiveMinutes() {
        var cache = LatencyCache()
        let t0 = Date()
        XCTAssertFalse(cache.isFresh(now: t0))
        cache.store(["a": .ms(5)], at: t0)
        XCTAssertEqual(cache.current(now: t0.addingTimeInterval(299)), ["a": .ms(5)])
        XCTAssertEqual(cache.current(now: t0.addingTimeInterval(301)), [:])
    }
}
