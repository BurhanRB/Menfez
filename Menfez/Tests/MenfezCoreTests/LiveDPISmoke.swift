import XCTest
@testable import MenfezCore

/// A live smoke test of the real engine against the real network.
///
/// Skipped unless MENFEZ_LIVE_DPI=1, because it needs an actually-blocked
/// network to be meaningful: on an unblocked one it passes whether or not the
/// re-framing works, which would be a green test proving nothing.
final class LiveDPISmoke: XCTestCase {

    func testReframedProxyReachesDiscord() throws {
        guard ProcessInfo.processInfo.environment["MENFEZ_LIVE_DPI"] == "1" else {
            throw XCTSkip("set MENFEZ_LIVE_DPI=1 to run the live smoke test")
        }

        let engine = DPIEngine()
        let started: DPIStatus
        do {
            started = try engine.start()
        } catch {
            XCTFail("engine did not start: \(error)")
            return
        }
        guard let port = started.port else {
            XCTFail("engine reported running with no port")
            return
        }
        defer { engine.stop() }
        print("LIVE: proxy on port \(port)")

        // Direct first: on a blocked network this must fail, otherwise the
        // comparison that follows proves nothing.
        let direct = run("/usr/bin/curl",
                         ["-sS", "-o", "/dev/null", "-w", "%{http_code}",
                          "--max-time", "8", "https://discord.com"])
        print("LIVE: direct = \(direct.trimmingCharacters(in: .whitespaces))")

        let viaProxy = run("/usr/bin/curl",
                           ["-sS", "-o", "/dev/null", "-w", "%{http_code}",
                            "--max-time", "12",
                            "-x", "http://127.0.0.1:\(port)",
                            "https://discord.com"])
        print("LIVE: via proxy = \(viaProxy.trimmingCharacters(in: .whitespaces))")

        let status = engine.status()
        print("LIVE: reframed=\(status.reframed) passthrough=\(status.passthrough)")

        XCTAssertEqual(viaProxy.trimmingCharacters(in: .whitespaces), "200",
                       "the proxy must make the handshake complete on a blocked network")
        XCTAssertGreaterThan(status.reframed, 0,
                             "at least one connection must have been re-framed")
    }

    private func run(_ tool: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try? p.run()
        p.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
