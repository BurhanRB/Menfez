import XCTest
@testable import MenfezCore

// DPIModeTests — the policy around the engine: the mode conflict, start/stop
// wire-up, and the Discord launch that must not silently do nothing.
//
// No test opens a socket to anything but 127.0.0.1, and none needs a tunnel:
// `DPIMode` takes the interface list as a closure, which is the whole reason it
// exists as a separate type from `DPIEngine`.

final class DPIModeTests: XCTestCase {

    // MARK: - The conflict rule

    /// DPI mode must refuse while the tunnel is up, and must NOT stop the
    /// tunnel: a refused click is recoverable, a torn-down tunnel is not.
    @MainActor
    func testDPIEnableRefusesWhileTunnelIsUp() async {
        let engine = DPIEngine()
        defer { engine.shutdown() }
        let mode = DPIMode(engine: engine, tunnelInterfaces: { ["utun5"] })

        let result = await mode.enable()
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.blockedByTunnel)
        XCTAssertEqual(result.message, DPIConflict.tunnelIsUpMessage)
        // The refusal must not have started a listener as a side effect.
        XCTAssertFalse(engine.status().running)
        XCTAssertNil(engine.status().port)
    }

    @MainActor
    func testDPIEnableSucceedsWithNoTunnel() async {
        let engine = DPIEngine()
        defer { engine.shutdown() }
        let mode = DPIMode(engine: engine, tunnelInterfaces: { [] })

        let result = await mode.enable()
        XCTAssertTrue(result.ok, result.message)
        XCTAssertNotNil(result.status.port)
        XCTAssertTrue(result.status.running)
        // The message must name the port, because that is the number the user
        // needs if they want to configure the client by hand.
        XCTAssertTrue(result.message.contains("127.0.0.1:"))
        XCTAssertTrue(result.message.contains("\(result.status.port ?? 0)"))
    }

    /// Enabling twice is not an error: DPI mode is already on, and reporting
    /// the existing port is more useful than a failure the user cannot act on.
    @MainActor
    func testDPIEnableIsIdempotent() async {
        let engine = DPIEngine()
        defer { engine.shutdown() }
        let mode = DPIMode(engine: engine, tunnelInterfaces: { [] })

        let first = await mode.enable()
        let second = await mode.enable()
        XCTAssertTrue(first.ok)
        XCTAssertTrue(second.ok)
        XCTAssertEqual(first.status.port, second.status.port,
                       "the second enable must not move to a new port")
        XCTAssertTrue(second.message.contains("already"))
    }

    @MainActor
    func testDPIDisableStopsTheListener() async {
        let engine = DPIEngine()
        defer { engine.shutdown() }
        let mode = DPIMode(engine: engine, tunnelInterfaces: { [] })

        _ = await mode.enable()
        let port = mode.status.port
        XCTAssertNotNil(port)

        let result = await mode.disable()
        XCTAssertTrue(result.ok)
        XCTAssertFalse(mode.status.running)
        XCTAssertNil(mode.status.port)
    }

    /// Leaving DPI mode must be possible even when the tunnel is up: only
    /// *entering* it is refused.
    @MainActor
    func testDPIDisableWorksWhileTunnelIsUp() async {
        let engine = DPIEngine()
        defer { engine.shutdown() }
        var interfaces: [String] = []
        let mode = DPIMode(engine: engine, tunnelInterfaces: { interfaces })
        _ = await mode.enable()

        interfaces = ["utun5"]
        let disabled = await mode.disable()
        XCTAssertTrue(disabled.ok)
    }

    // MARK: - Discord

    @MainActor
    func testDiscordLaunchRefusedWhenProxyIsOff() async {
        let engine = DPIEngine()
        defer { engine.shutdown() }
        let mode = DPIMode(engine: engine, tunnelInterfaces: { [] })

        let result = await mode.launchDiscord(using: RecordingRunner())
        XCTAssertEqual(result.failureValue, .proxyNotRunning)
        XCTAssertEqual(mode.discordAvailability.enabled, false)
    }

    /// The already-running refusal is the whole reason `discordRunning` is
    /// injectable: without it, a click on a running Discord produces no visible
    /// change and the user believes the app is covered.
    @MainActor
    func testDiscordLaunchRefusedWhenAlreadyRunning() async {
        let engine = DPIEngine()
        defer { engine.shutdown() }
        let mode = DPIMode(engine: engine,
                           tunnelInterfaces: { [] },
                           discordRunning: { true })
        _ = await mode.enable()

        let runner = RecordingRunner()
        let result = await mode.launchDiscord(using: runner)
        XCTAssertEqual(result.failureValue, .alreadyRunning)
        XCTAssertTrue(runner.calls.isEmpty, "no launch must be attempted")

        let availability = mode.discordAvailability
        XCTAssertFalse(availability.enabled)
        XCTAssertTrue(availability.reason?.contains("quit Discord") ?? false)
    }

    @MainActor
    func testDiscordLaunchUsesTheLivePort() async throws {
        let engine = DPIEngine()
        defer { engine.shutdown() }
        let mode = DPIMode(engine: engine, tunnelInterfaces: { [] })
        let status = await mode.enable()
        let port = try XCTUnwrap(status.status.port)

        let runner = RecordingRunner()
        let result = await mode.launchDiscord(using: runner)
        let args = try XCTUnwrap(try? result.get())
        XCTAssertEqual(args.last, "--proxy-server=http://127.0.0.1:\(port)")
        XCTAssertEqual(runner.calls.first?.tool, "open")
    }

    /// `open` can take its full 15 s timeout; it must never run on the main
    /// thread, or the window freezes for that long.
    @MainActor
    func testDiscordLaunchRunsOffTheMainThread() async throws {
        final class ThreadRunner: CommandRunner, @unchecked Sendable {
            var ranOnMain: Bool?
            func run(_ tool: String, _ args: [String], timeout: TimeInterval) -> CommandResult {
                ranOnMain = Thread.isMainThread
                return CommandResult(status: 0, output: "")
            }
        }
        let engine = DPIEngine()
        defer { engine.shutdown() }
        let mode = DPIMode(engine: engine, tunnelInterfaces: { [] })
        _ = await mode.enable()

        let runner = ThreadRunner()
        _ = await mode.launchDiscord(using: runner)
        XCTAssertEqual(runner.ranOnMain, false)
    }

    // MARK: - Probe honesty

    /// A probe with the proxy off makes one request and says so. It must not
    /// claim the proxy is broken, which would be a fabricated verdict.
    func testProbeOfflineVerdict() {
        let runner = RecordingRunner()
        let outcome = DPIProbe.run(port: nil, using: runner)
        XCTAssertEqual(outcome.verdict, .proxyOff)
        XCTAssertEqual(runner.calls.count, 1,
                       "no second attempt without a proxy to compare against")
    }

    /// The most important honesty case: a direct success plus a proxied success
    /// must NOT be reported as "working". That combination is exactly what the
    /// spike saw after the block lifted, and reporting it as a bypass would be
    /// the lie this whole type exists to prevent.
    func testBothSucceedIsNotReportedAsWorking() {
        let runner = RecordingRunner()
        runner.answer = CommandResult(status: 0, output: "")
        let outcome = DPIProbe.run(port: 5000, using: runner)
        XCTAssertEqual(outcome.verdict, .notNeeded)
        XCTAssertNotEqual(outcome.verdict, .working)
    }

    /// Direct failed, proxied worked: the only combination that justifies the
    /// word "working".
    func testDirectFailureProxySuccessIsWorking() {
        let runner = SequencedRunner()
        runner.answers = [CommandResult(status: 56, output: "reset"),
                          CommandResult(status: 0, output: "")]
        let outcome = DPIProbe.run(port: 5000, using: runner)
        XCTAssertEqual(outcome.verdict, .working)
        XCTAssertTrue(outcome.direct.ok == false)
        XCTAssertTrue(outcome.proxied.ok)
    }

    func testBothFailIsNotHelping() {
        let runner = RecordingRunner()
        runner.answer = CommandResult(status: 56, output: "reset")
        let outcome = DPIProbe.run(port: 5000, using: runner)
        XCTAssertEqual(outcome.verdict, .notHelping)
    }

    func testDirectSuccessProxyFailureIsProxyBroken() {
        let runner = SequencedRunner()
        runner.answers = [CommandResult(status: 0, output: ""),
                          CommandResult(status: 7, output: "refused")]
        let outcome = DPIProbe.run(port: 5000, using: runner)
        XCTAssertEqual(outcome.verdict, .proxyBroken)
    }
}

// MARK: - Helpers

/// Answers each call with the next scripted result, in order.
final class SequencedRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var index = 0
    var answers: [CommandResult] = []

    func run(_ tool: String, _ args: [String], timeout: TimeInterval) -> CommandResult {
        lock.lock(); defer { lock.unlock() }
        let answer = answers.indices.contains(index)
            ? answers[index]
            : CommandResult(status: 127, output: "no more answers")
        index += 1
        return answer
    }
}

private extension Result {
    /// The failure value, or nil when the result succeeded.
    ///
    /// Named `failureValue` rather than `failure` so it cannot be confused with
    /// the enum case of the same name at a call site.
    var failureValue: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
