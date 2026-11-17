import XCTest
@testable import MenfezCore

/// The "Set up tunnel" button: what it asks osascript to run, and what the
/// buttons show afterwards. No test runs anything as root: the runner is fake.
final class TunnelInstallerTests: XCTestCase {

    private let helper = "/Applications/Menfez.app/Contents/MacOS/menfez-route"
    private let script = "/Applications/Menfez.app/Contents/Resources/install-helper.sh"

    func testInstallScriptQuotesEveryWordAndUsesBundlePaths() throws {
        let source = try XCTUnwrap(TunnelInstaller.appleScript(.install, helper: helper, user: "ayse"))
        XCTAssertEqual(source,
                       "do shell script \"/bin/bash\""
                       + " & \" \" & quoted form of \"\(script)\""
                       + " & \" \" & quoted form of \"\(helper)\""
                       + " & \" \" & quoted form of \"ayse\""
                       + " with administrator privileges")
        XCTAssertFalse(source.contains("$USER"), "the shell runs as root; the user is named")
        XCTAssertFalse(source.contains("/tmp"))
    }

    func testRemoveRunsTheSameScriptWithRemove() throws {
        let source = try XCTUnwrap(TunnelInstaller.appleScript(.remove, helper: helper, user: "x"))
        XCTAssertTrue(source.contains("quoted form of \"\(script)\" & \" \" & quoted form of \"--remove\""), source)
        XCTAssertTrue(source.hasSuffix("with administrator privileges"))
    }

    func testSpaceInBundlePathStaysOneWord() throws {
        let spaced = "/Users/a/My Apps/Menfez.app/Contents/MacOS/menfez-route"
        let source = try XCTUnwrap(TunnelInstaller.appleScript(.install, helper: spaced, user: "a"))
        XCTAssertTrue(source.contains("quoted form of \"\(spaced)\""))
    }

    func testUnsafePathsAndUsersAreRefused() {
        for bad in ["/Users/a/x\"y/Menfez.app/Contents/MacOS/menfez-route",
                    "/Users/a/x\\y/Menfez.app/Contents/MacOS/menfez-route",
                    "/Users/a/$(reboot)/Menfez.app/Contents/MacOS/menfez-route",
                    "relative/Menfez.app/Contents/MacOS/menfez-route"] {
            XCTAssertNil(TunnelInstaller.appleScript(.install, helper: bad, user: "a"), bad)
            XCTAssertNil(TunnelInstaller.appleScript(.remove, helper: bad, user: "a"), bad)
        }
        for user in ["root", "", "a b", "a\"b", "a;b", "-x", "a ALL=(ALL) ALL"] {
            XCTAssertNil(TunnelInstaller.appleScript(.install, helper: helper, user: user), user)
        }
        let recorder = RecordingRunner()
        XCTAssertEqual(TunnelInstaller.run(.install, helper: helper, user: "root", using: recorder),
                       .failed("unsafe path or user name"))
        XCTAssertTrue(recorder.calls.isEmpty, "nothing is spawned for a refused value")
    }

    func testLiteralEscapesQuotesAndBackslashes() {
        XCTAssertEqual(TunnelInstaller.literal(#"a"b\c"#), #""a\"b\\c""#)
    }

    func testRunCallsOsascriptByAbsolutePath() {
        let recorder = RecordingRunner()
        XCTAssertEqual(TunnelInstaller.run(.install, helper: helper, user: "ayse", using: recorder), .succeeded)
        XCTAssertEqual(recorder.calls.count, 1)
        XCTAssertEqual(recorder.calls.first?.tool, "/usr/bin/osascript")
        XCTAssertEqual(recorder.calls.first?.args.first, "-e")
    }

    func testOutcomes() {
        XCTAssertEqual(TunnelInstaller.outcome(of: CommandResult(status: 0, output: "==> done")), .succeeded)
        XCTAssertEqual(TunnelInstaller.outcome(of: CommandResult(
            status: 1, output: "0:120: execution error: User canceled. (-128)")), .cancelled)
        XCTAssertEqual(TunnelInstaller.outcome(of: CommandResult(
            status: 1, output: "0:142: execution error: error: WireGuard tools not found. "
                + "Install them first: brew install wireguard-tools wireguard-go bash (1)")),
            .failed("WireGuard tools not found. Install them first: brew install wireguard-tools wireguard-go bash"))
        XCTAssertEqual(TunnelInstaller.outcome(of: CommandResult(status: 1, output: "", timedOut: true)),
                       .failed("timed out"))
        XCTAssertEqual(TunnelInstaller.outcome(of: CommandResult(status: 3, output: "")), .failed("exit 3"))
    }

    func testStateTransitions() {
        let idle = TunnelInstallState.idle
        XCTAssertEqual(idle.starting(.install), .running(.install))
        XCTAssertNil(TunnelInstallState.running(.install).starting(.remove), "one dialog at a time")
        XCTAssertEqual(TunnelInstallState.failed(.install, "x").starting(.install), .running(.install))
        XCTAssertEqual(TunnelInstallState.finished(.install, .succeeded), .succeeded(.install))
        XCTAssertEqual(TunnelInstallState.finished(.remove, .cancelled), .cancelled(.remove))
        XCTAssertEqual(TunnelInstallState.finished(.install, .failed("boom")), .failed(.install, "boom"))
        XCTAssertFalse(TunnelInstallState.succeeded(.install).isRunning)
    }

    /// The remove mode exists in the script and refuses to run without root.
    func testScriptRemoveNeedsRoot() {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("install-helper.sh").path
        guard getuid() != 0 else { return }
        let result = Shell.run("/bin/bash", [file, "--remove"], timeout: 10)
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.output.contains("run this with sudo"), result.output)
    }
}
