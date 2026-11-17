import XCTest
@testable import MenfezCore

/// The path the user takes when they press the blue button, exercised without
/// clicking it.
///
/// WHY THIS TEST EXISTS
/// Every part of the primary action was tested in isolation — the engine alone,
/// the launcher's argv alone — and the whole thing was never run as one
/// sequence. That gap is the one that ships: a port that starts and is not the
/// port passed to Discord, an argv built before the engine was up, or a launch
/// path that silently returns nil would all leave a user with a running proxy,
/// a Discord that ignores it, and a green status.
///
/// WHAT IT ASSERTS, in order
///   1. `DPIMode.enable()` reports success and a port.
///   2. Something is actually listening on that port (not just recorded).
///   3. `DiscordLauncher.arguments(port:)` produces the argv with that same
///      port embedded — the exact coupling that can drift.
///   4. A real TLS handshake through that port completes, while a direct one to
///      the same host is reset. This is the only step that proves the whole
///      chain, and it needs a blocked network to be meaningful, so it is gated.
///
/// The listener and argv checks run everywhere; only step 4 is opt-in.
final class PrimaryActionTests: XCTestCase {

    /// `enable()` defaults `tunnelBusy` to "any interface exists", which is the
    /// wrong question on a machine with a stray utun. The app passes the real
    /// answer from the route state; a test must do the same or it would be
    /// testing the bug that was fixed.
    @MainActor
    func testEnableBindsAPortAndTheLauncherUsesIt() async throws {
        let mode = DPIMode()
        defer { mode.shutdown() }

        let enabled = await mode.enable(tunnelBusy: false)
        XCTAssertTrue(enabled.ok, "enable refused: \(enabled.message)")
        let port = try XCTUnwrap(enabled.status.port, "enable reported success with no port")
        XCTAssertGreaterThan(port, 1023, "a privileged port would need root")
        XCTAssertLessThanOrEqual(port, 65535)

        // The engine's own view must agree with the result it returned.
        XCTAssertTrue(mode.status.running)
        XCTAssertEqual(mode.status.port, port,
                       "the status and the returned port disagree; the launcher would be given the wrong one")

        // A listener must exist, not merely a recorded number.
        XCTAssertTrue(PortProbe.isListening(port: port),
                      "nothing is listening on \(port) even though enable() reported success")

        // The argv Discord is launched with must carry that port.
        let argv = DiscordLauncher.arguments(port: port)
        let flag = try XCTUnwrap(argv.first(where: { $0.hasPrefix("--proxy-server=") }),
                                 "argv has no proxy-server flag: \(argv)")
        XCTAssertEqual(flag, "--proxy-server=http://127.0.0.1:\(port)",
                       "argv points at a different address than the listener")
        XCTAssertTrue(argv.contains("--args"),
                      "Electron needs --args before the app's own switches")
    }

    /// Leaving DPI mode must release the port, or the next press of the button
    /// fails with "already running" and the user sees a dead action.
    @MainActor
    func testDisableReleasesThePort() async throws {
        let mode = DPIMode()
        let enabled = await mode.enable(tunnelBusy: false)
        let port = try XCTUnwrap(enabled.status.port)
        XCTAssertTrue(PortProbe.isListening(port: port))

        _ = await mode.disable()
        XCTAssertFalse(mode.status.running)
        XCTAssertFalse(PortProbe.isListening(port: port),
                       "port \(port) is still accepting after disable")

        // And it can be started again on a fresh port.
        let again = await mode.enable(tunnelBusy: false)
        XCTAssertTrue(again.ok, "second enable failed: \(again.message)")
        XCTAssertNotNil(again.status.port)
        mode.shutdown()
    }

    /// A tunnel that is actually carrying traffic must block DPI mode, with a
    /// refusal the UI can act on rather than a bare error.
    @MainActor
    func testTunnelConflictIsRefusedNotIgnored() async {
        let mode = DPIMode()
        defer { mode.shutdown() }
        let refused = await mode.enable(tunnelBusy: true)
        XCTAssertFalse(refused.ok)
        XCTAssertTrue(refused.blockedByTunnel,
                      "the UI needs this flag to offer 'turn the tunnel off'")
        XCTAssertNotNil(refused.status.port == nil ? true : nil,
                        "nothing must be listening after a refusal")
    }

    // MARK: - Live end-to-end

    /// The full chain against a real network: enable → argv → request.
    ///
    /// Gated on `MENFEZ_LIVE_DPI=1` because on an unblocked network the direct
    /// request also succeeds and the comparison proves nothing.
    @MainActor
    func testPrimaryActionOpensDiscordThroughTheProxy() async throws {
        guard ProcessInfo.processInfo.environment["MENFEZ_LIVE_DPI"] == "1" else {
            throw XCTSkip("set MENFEZ_LIVE_DPI=1 on a blocked network")
        }

        let mode = DPIMode()
        defer { mode.shutdown() }

        let enabled = await mode.enable(tunnelBusy: false)
        XCTAssertTrue(enabled.ok, enabled.message)
        let port = try XCTUnwrap(enabled.status.port)

        // Exactly what the button does next.
        let argv = DiscordLauncher.arguments(port: port)
        print("PRIMARY argv = \(argv.joined(separator: " "))")

        let direct = curl(["-sS", "-o", "/dev/null", "-w", "%{http_code}",
                           "--max-time", "8", "https://discord.com"])
        let proxied = curl(["-sS", "-o", "/dev/null", "-w", "%{http_code}",
                            "--max-time", "12",
                            "-x", "http://127.0.0.1:\(port)",
                            "https://discord.com"])
        let status = mode.status
        print("PRIMARY direct=\(direct) proxied=\(proxied) "
              + "reframed=\(status.reframed) passthrough=\(status.passthrough)")

        XCTAssertEqual(proxied, "200",
                       "the primary action did not open the host through its own proxy")
        XCTAssertGreaterThan(status.reframed, 0,
                             "a connection went through without being re-framed")
        XCTAssertNotEqual(direct, "200",
                          "the direct request succeeded too, so this network is not blocked "
                          + "and the comparison above proves nothing")
    }

    private func curl(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try? p.run()
        p.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
