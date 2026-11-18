import XCTest
@testable import MenfezCore

final class SiteTestTests: XCTestCase {

    // MARK: input

    private func host(_ s: String) -> String? { try? SiteTest.host(from: s).get() }
    private func error(_ s: String) -> SiteTest.InputError? {
        if case .failure(let e) = SiteTest.host(from: s) { return e }
        return nil
    }

    func testAcceptsNamesAndURLs() {
        XCTAssertEqual(host("discord.com"), "discord.com")
        XCTAssertEqual(host("  Discord.COM.  "), "discord.com")
        XCTAssertEqual(host("https://www.example.com/a/b?c=d#e"), "www.example.com")
        XCTAssertEqual(host("http://example.com:80/"), "example.com")
        XCTAssertEqual(host("example.com:443"), "example.com")
    }

    func testUnicodeNameBecomesPunycodeOrIsRefusedPolitely() {
        // macOS 13's URLComponents may not convert; either way no raw Unicode goes to curl.
        switch SiteTest.host(from: "çay.com.tr") {
        case .success(let h): XCTAssertEqual(h, "xn--ay-3ia.com.tr")
        case .failure(let e): XCTAssertEqual(e, .notAName)
        }
    }

    func testRefusesBadInput() {
        XCTAssertEqual(error(""), .empty)
        XCTAssertEqual(error("   "), .empty)
        XCTAssertEqual(error("disc ord.com"), .notAName)
        XCTAssertEqual(error("discord"), .notAName)
        XCTAssertEqual(error("ftp://example.com"), .notAName)
        XCTAssertEqual(error("https://user:pw@example.com"), .notAName)
        XCTAssertEqual(error("-bad.com"), .notAName)
        XCTAssertEqual(error("a_b.com"), .notAName)
        XCTAssertEqual(error("example.com:8443"), .port)
        XCTAssertEqual(error(String(repeating: "a", count: 64) + ".com"), .notAName)
    }

    func testRefusesAddressesAndLocalNames() {
        XCTAssertEqual(error("1.1.1.1"), .address)
        XCTAssertEqual(error("https://192.168.1.1/"), .address)
        XCTAssertEqual(error("[::1]"), .address)
        XCTAssertEqual(error("127.1"), .notAName)
        XCTAssertEqual(error("localhost"), .local)
        XCTAssertEqual(error("printer.local"), .local)
        XCTAssertEqual(error("app.localhost"), .local)
    }

    // MARK: aggregation

    func testPaths() {
        XCTAssertEqual(SiteTest.paths(tunnelCarriesEverything: false), [.direct, .dpi])
        XCTAssertEqual(SiteTest.paths(tunnelCarriesEverything: true), [.tunnel])
    }

    func testOutcomeFromAttempt() {
        XCTAssertEqual(SiteTest.outcome(.init(exit: 0)), .opens)
        XCTAssertEqual(SiteTest.outcome(.init(exit: 28, error: "timed out")), .timedOut)
        XCTAssertEqual(SiteTest.outcome(.init(exit: 6, error: DPIProbe.dnsError)), .notFound)
        XCTAssertEqual(SiteTest.outcome(.init(exit: 35, error: "TLS handshake failed")), .fails)
    }

    func testSummaryTable() {
        typealias S = SiteTest.Summary
        let cases: [([SiteTest.Path: SiteTest.Outcome], S)] = [
            ([.direct: .opens, .dpi: .opens], .opensDirect),
            ([.direct: .fails, .dpi: .opens], .opensWithDPI),
            ([.direct: .timedOut, .dpi: .opens], .opensWithDPI),
            ([.direct: .fails, .dpi: .fails], .opensNowhere),
            ([.direct: .timedOut, .dpi: .timedOut], .opensNowhere),
            ([.direct: .notFound, .dpi: .notFound], .notFound),
            ([.direct: .notFound, .dpi: .fails], .opensNowhere),
            ([.tunnel: .opens], .opensWithTunnel),
            ([.tunnel: .fails], .opensNowhereTunnel),
            ([:], .notFound),
        ]
        for (results, expected) in cases {
            XCTAssertEqual(SiteTest.summary(results), expected, "\(results)")
        }
    }

    // MARK: run

    private struct FixedResolver: HostResolver {
        let answer: [String]?
        func resolve(_ host: String, completion: @escaping @Sendable ([String]?) -> Void) { completion(answer) }
    }

    /// Answers by whether the request goes through the proxy; records arguments.
    private final class FakeCurl: CommandRunner, @unchecked Sendable {
        let direct: Int32, proxied: Int32
        private let lock = NSLock()
        private var _calls: [[String]] = []
        var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return _calls }
        init(direct: Int32, proxied: Int32) { self.direct = direct; self.proxied = proxied }
        func run(_ tool: String, _ args: [String], timeout: TimeInterval) -> CommandResult {
            lock.lock(); _calls.append(args); lock.unlock()
            return CommandResult(status: args.contains("--proxy") ? proxied : direct, output: "")
        }
    }

    func testRunBlockedDirectOpenWithDPIAndPinsCheckedAddress() {
        let curl = FakeCurl(direct: 35, proxied: 0)
        let r = SiteTest.run(host: "example.com", paths: [.direct, .dpi], proxyPort: 6000,
                             resolver: FixedResolver(answer: ["93.184.216.34"]), runner: curl)
        XCTAssertEqual(r.results, [.direct: .fails, .dpi: .opens])
        XCTAssertEqual(r.summary, .opensWithDPI)
        let direct = curl.calls.first { !$0.contains("--proxy") }
        XCTAssertNotNil(direct)
        XCTAssertTrue(direct!.contains("example.com:443:93.184.216.34"))
        XCTAssertEqual(direct!.last, "https://example.com/")
    }

    func testRunRefusesPrivateAnswerWithoutRequests() {
        let curl = FakeCurl(direct: 0, proxied: 0)
        let r = SiteTest.run(host: "evil.example", paths: [.direct, .dpi], proxyPort: 6000,
                             resolver: FixedResolver(answer: ["192.168.1.1"]), runner: curl)
        XCTAssertEqual(r.summary, .refused)
        XCTAssertTrue(curl.calls.isEmpty)
    }

    func testRunUnresolvedNameIsNotFound() {
        let curl = FakeCurl(direct: 0, proxied: 0)
        let r = SiteTest.run(host: "nope.example", paths: [.direct, .dpi], proxyPort: 6000,
                             resolver: FixedResolver(answer: nil), runner: curl)
        XCTAssertEqual(r.summary, .notFound)
        XCTAssertTrue(curl.calls.isEmpty)
    }

    func testRunTunnelOnly() {
        let curl = FakeCurl(direct: 0, proxied: 7)
        let r = SiteTest.run(host: "example.com", paths: [.tunnel], proxyPort: nil,
                             resolver: FixedResolver(answer: ["93.184.216.34"]), runner: curl)
        XCTAssertEqual(r.results, [.tunnel: .opens])
        XCTAssertEqual(r.summary, .opensWithTunnel)
        XCTAssertEqual(curl.calls.count, 1)
    }
}
