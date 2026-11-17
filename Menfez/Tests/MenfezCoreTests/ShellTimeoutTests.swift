import XCTest
@testable import MenfezCore

/// M6: the timeout path must kill grandchildren too, and the output buffer is
/// never read while the reader thread may still be writing it.
final class ShellTimeoutTests: XCTestCase {
    func testTimeoutKillsGrandchildrenAndKeepsOutput() {
        let start = Date()
        // `sleep` is a grandchild holding the pipe; killing only `sh` would
        // leave the pipe open for 30 s.
        let result = Shell.run("/bin/sh", ["-c", "echo started; /bin/sleep 30 & wait"], timeout: 1)
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.status, 124)
        XCTAssertTrue(result.output.contains("started"), result.output)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testOpenPipeAfterExitIsMarkedUnavailable() {
        let start = Date()
        // The child exits at once; a detached grandchild keeps the pipe open.
        let result = Shell.run("/bin/sh", ["-c", "echo hi; (/bin/sleep 6 &)"], timeout: 10)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, Shell.outputUnavailable)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testNormalOutput() {
        let result = Shell.run("/bin/echo", ["hello"], timeout: 5)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.output, "hello\n")
    }

    func testActTimeoutCoversWorstCaseSwitch() {
        // switch = wg-quick down + wg-quick up + transport probe, plus routes.
        let worst = 2 * RouteManager.wireGuardTimeout + RouteManager.transportProbeBudget
        XCTAssertGreaterThan(HelperClient.actTimeout, worst)
    }
}
