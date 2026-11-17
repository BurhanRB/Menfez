import XCTest
@testable import MenfezCore

/// The Discord popup: shown at once from the card's probe, refreshed on the
/// card's own path (proxy + DoH in DPI mode), bounded in time.
final class DiscordDetailTests: XCTestCase {

    private struct FixedResolver: HostResolver {
        let answer: [String]?
        func resolve(_ host: String, completion: @escaping @Sendable ([String]?) -> Void) {
            completion(answer)
        }
    }

    /// Never answers, like a DoH server the network drops.
    private struct SilentResolver: HostResolver {
        func resolve(_ host: String, completion: @escaping @Sendable ([String]?) -> Void) {}
    }

    func testInitialRowsComeFromTheCardProbeWithoutLookups() {
        let rows = Details.discordRows(probe: DiscordProbe(code: 200, ms: 206), names: nil)
        XCTAssertEqual(rows, [DetailItem(label: "HTTPS", value: "HTTP 200 · 206 ms")])
        XCTAssertEqual(Details.discordRows(probe: DiscordProbe(), names: nil).last?.value, "—")
        XCTAssertEqual(Details.discordRows(probe: DiscordProbe(code: 0, failure: .tls), names: nil).last?.value,
                       "unreachable (tls)")
    }

    func testDPIRefreshUsesDoHAndTheProxyNotTheSystemResolver() {
        let runner = RecordingRunner()
        runner.answer = CommandResult(status: 0, output: "200 0.206")
        let rows = Details.discordLive(proxyPort: 64799,
                                       resolver: FixedResolver(answer: ["162.159.137.232"]),
                                       using: runner, timeout: 3)
        XCTAssertEqual(rows.map(\.label), Details.discordHosts + ["HTTPS"])
        XCTAssertEqual(rows.first?.value, "162.159.137.232")
        XCTAssertEqual(rows.last?.value, "HTTP 200 · 206 ms")
        XCTAssertFalse(runner.calls.contains { $0.tool == "dig" }, "no system resolver in DPI mode")
        let curl = runner.calls.first { $0.tool == "curl" }
        XCTAssertNotNil(curl)
        XCTAssertTrue(curl?.joined.contains("-x http://127.0.0.1:64799") ?? false, curl?.joined ?? "")
        XCTAssertTrue(curl?.joined.contains("--max-time 3") ?? false, "short bound, not 8 s")
        XCTAssertFalse(runner.calls.contains { $0.tool.hasSuffix("sudo") }, "no helper call")
    }

    func testOutsideDPIUsesTheSystemResolver() {
        let runner = RecordingRunner()
        runner.answer = CommandResult(status: 0, output: "200 0.1")
        _ = Details.discordLive(proxyPort: nil, resolver: SilentResolver(), using: runner, timeout: 2)
        XCTAssertEqual(runner.calls.filter { $0.tool == "dig" }.count, 3)
    }

    func testRefreshIsBoundedWhenNothingAnswers() {
        let runner = RecordingRunner()
        runner.answer = CommandResult(status: 0, output: "200 0.1")
        let start = Date()
        let rows = Details.discordLive(proxyPort: 64799, resolver: SilentResolver(),
                                       using: runner, timeout: 1)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertEqual(rows.first?.value, "no answer")
    }
}
