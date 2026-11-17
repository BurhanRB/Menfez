import XCTest
@testable import MenfezCore

/// The app-to-helper boundary.
///
/// Two things are asserted here and nowhere else, because both need to fake a
/// helper: that the fast path asks for nothing privileged, and that an app
/// built against a new helper still works with an old one installed.
final class HelperClientTests: XCTestCase {

    /// A helper stand-in: records every command line, answers from a table.
    final class Stub: @unchecked Sendable {
        private let lock = NSLock()
        private var _lines: [String] = []
        private var replies: [(match: String, status: Int32, output: String)] = []

        var lines: [String] {
            lock.lock(); defer { lock.unlock() }
            return _lines
        }

        /// Register a reply for the first command line that starts with `match`.
        func on(_ match: String, status: Int32 = 0, output: String = "") {
            lock.lock(); defer { lock.unlock() }
            replies.append((match, status, output))
        }

        func launch(_ tool: String, _ args: [String],
                    _ timeout: TimeInterval) -> CommandResult {
            let line = ([tool] + args).joined(separator: " ")
            lock.lock()
            _lines.append(line)
            let hit = replies.first { line.contains($0.match) }
            lock.unlock()
            if let hit {
                return CommandResult(status: hit.status, output: hit.output)
            }
            return CommandResult(status: 127, output: "unstubbed: \(line)")
        }
    }

    private func client(_ stub: Stub, helper: String = "/Applications/Menfez.app/Contents/MacOS/menfez-route") -> HelperClient {
        HelperClient(helper: helper) { tool, args, timeout in
            stub.launch(tool, args, timeout)
        }
    }

    // MARK: - Old helper fallback

    /// An app newer than its helper must still fill the tunnel rows.
    ///
    /// `facts` is a new subcommand. The helper shipped with an earlier build
    /// exits 2 and prints usage, which is exactly what this stub does. The
    /// client must then ask for `report --fast`, which every version has
    /// understood, instead of leaving the card blank.
    func testFactsFallsBackToReportOnAnOlderHelper() throws {
        let stub = Stub()
        // An old helper: unknown subcommand -> usage -> exit 2.
        stub.on("facts", status: 2, output: "usage: menfez-route <command>")
        stub.on("report --fast", output: """
            {"ts":1700000000,"tunnel":"utun9","health":{"ok":true,"code":"ok","age_s":12},
             "mode":"discord","routes":[],"hosts":[],"endpoint":"203.0.113.69",
             "peer_pubkey":"abc=","handshake_epoch":1699999988,
             "transfer":{"rx":10,"tx":20},"dns":[],"discord":{"code":0}}
            """)

        let facts = try XCTUnwrap(client(stub).facts())

        XCTAssertEqual(facts.tunnel, "utun9")
        XCTAssertEqual(facts.endpoint, "203.0.113.69")
        XCTAssertEqual(facts.peerPubkey, "abc=")
        XCTAssertEqual(facts.transfer, Transfer(rx: 10, tx: 20))
        XCTAssertEqual(stub.lines.count, 2, "one facts attempt, one report fallback")
    }

    /// A helper that fails for any other reason must not be retried.
    ///
    /// Exit 1 is a real failure (no root, missing binary, an internal error).
    /// Trying a second command would double the work and hide the problem.
    func testFactsDoesNotFallBackOnARealFailure() {
        let stub = Stub()
        stub.on("facts", status: 1, output: "menfez-route must run as root")

        XCTAssertNil(client(stub).facts())
        XCTAssertEqual(stub.lines.count, 1,
                       "a non-usage failure must not trigger a second command:\n"
                       + stub.lines.joined(separator: "\n"))
    }

    /// A missing helper (sudo refuses) is nil, not a crash or a second attempt.
    func testFactsIsNilWhenSudoRefuses() {
        let stub = Stub()
        stub.on("", status: 1, output: "sudo: a password is required")

        XCTAssertNil(client(stub).facts())
        XCTAssertTrue(stub.lines.first?.hasPrefix("/usr/bin/sudo -n ") ?? false)
    }

    // MARK: - The new helper

    /// The happy path asks for `facts` once and parses it.
    func testFactsUsesTheNarrowCommandWhenAvailable() throws {
        let stub = Stub()
        stub.on("facts", output: """
            {"tunnel":"utun9","endpoint":"203.0.113.69","peer_pubkey":"abc=",
             "handshake_epoch":1699999988,"transfer":{"rx":1,"tx":2}}
            """)

        let facts = try XCTUnwrap(client(stub).facts())

        XCTAssertEqual(facts.tunnel, "utun9")
        XCTAssertEqual(stub.lines.count, 1, "one round trip, not a whole report")
        XCTAssertTrue(stub.lines[0].contains(" facts"))
    }

    // MARK: - Spawn accounting

    /// Every helper call goes through `sudo -n` with the same absolute path.
    ///
    /// This is the property the sudoers rule depends on: one path, no
    /// wildcards. If a second entry point is ever added, this fails.
    func testEveryCallUsesTheSameSudoPath() {
        let stub = Stub()
        stub.on("", status: 2, output: "{}")
        let c = client(stub)

        _ = c.facts()
        _ = c.report()
        _ = c.profiles()
        _ = c.dns()
        _ = c.detail("routes")
        _ = c.act(["up"])

        for line in stub.lines {
            XCTAssertTrue(line.hasPrefix("/usr/bin/sudo -n /Applications/Menfez.app/Contents/MacOS/menfez-route "),
                          "unexpected entry point: \(line)")
        }
        XCTAssertEqual(c.spawns["sudo"], stub.lines.count)
        XCTAssertTrue(c.spawnedRoot)
    }

    /// A client that only does local reads reports no root spawn.
    ///
    /// The counterpart to the test above: the counter is trustworthy in both
    /// directions, so "zero" means zero rather than "nothing is counted".
    func testLocalOnlyClientReportsNoRoot() {
        let stub = Stub()
        let c = client(stub)

        c.recordLocal("route")
        c.recordLocal("networksetup")

        XCTAssertFalse(c.spawnedRoot)
        XCTAssertEqual(c.spawns["route"], 1)
        XCTAssertEqual(c.spawns["networksetup"], 1)
        XCTAssertNil(c.spawns["sudo"])
    }
}
