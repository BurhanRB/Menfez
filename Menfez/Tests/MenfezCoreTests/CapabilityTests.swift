import XCTest
@testable import MenfezCore

// CapabilityTests — what the app may promise on a machine it has just met.
//
// NO TEST HERE TOUCHES SUDO OR THE FILESYSTEM. The probe takes both a
// `helperExists` closure and a `CommandRunner`, so "no helper installed",
// "helper installed but sudo wants a password" and "helper works" are three
// scripted values rather than three machines. That matters more than usual
// here: a test that ran real `sudo -n` would pass or fail depending on whether
// the CI box happens to have a sudoers rule, and the whole point of the type is
// to behave correctly when it does not.

final class CapabilityTests: XCTestCase {

    // MARK: - The three cases the product must distinguish

    /// No helper on disk. The app must still be useful, and must not spawn
    /// sudo at all — a fresh install has no reason to start a privileged
    /// process just to learn it cannot.
    func testMissingHelperIsUnavailableWithoutRunningSudo() {
        let recorder = RecordingRunner()
        recorder.answer = CommandResult(status: 1, output: "sudo: a password is required")

        let caps = CapabilityProbe.probe(helper: "/Applications/Menfez.app/Contents/MacOS/menfez-route",
                                         helperExists: { _ in false },
                                         using: recorder)

        XCTAssertFalse(caps.tunnelAvailable)
        XCTAssertTrue(caps.dpiAvailable)
        XCTAssertEqual(caps.reason, TunnelSetup.missingHelperReason)
        XCTAssertTrue(recorder.calls.isEmpty,
                      "a missing helper must not start a privileged process")
    }

    /// Helper present, sudo granted: the tunnel is available.
    func testHelperPresentAndSudoWorksIsAvailable() {
        let recorder = RecordingRunner()
        recorder.answer = CommandResult(status: 0, output: "tunnel: down\nmode: off\n")

        let caps = CapabilityProbe.probe(helper: "/opt/menfez/menfez-route",
                                         helperExists: { _ in true },
                                         using: recorder)

        XCTAssertTrue(caps.tunnelAvailable)
        XCTAssertTrue(caps.dpiAvailable)
        XCTAssertNil(caps.reason, "an available tunnel needs no explanation")

        // The exact command matters: `-n` is what keeps a missing rule from
        // hanging on a password prompt behind a window with no terminal.
        let call = recorder.calls.first
        XCTAssertEqual(call?.tool, CapabilityProbe.sudoPath)
        XCTAssertEqual(call?.args, ["-n", "/opt/menfez/menfez-route", "status"])
    }

    /// Helper present, sudo refuses: unavailable, with a *different* reason
    /// than the missing-helper case. The two have different fixes — install the
    /// helper versus apply the sudoers rule — so they cannot share a sentence.
    func testHelperPresentButSudoFailsIsUnavailableWithItsOwnReason() {
        let recorder = RecordingRunner()
        recorder.answer = CommandResult(status: 1,
                                        output: "sudo: a password is required")

        let caps = CapabilityProbe.probe(helper: "/opt/menfez/menfez-route",
                                         helperExists: { _ in true },
                                         using: recorder)

        XCTAssertFalse(caps.tunnelAvailable)
        XCTAssertTrue(caps.dpiAvailable)
        XCTAssertEqual(caps.reason, TunnelSetup.notPermittedReason)
        XCTAssertNotEqual(caps.reason, TunnelSetup.missingHelperReason)
        XCTAssertEqual(recorder.calls.count, 1, "the probe must not retry")
    }

    /// A hung helper is reported as a timeout, not as "sudo refused". The user
    /// cannot fix a hung binary with a sudoers line, so conflating them would
    /// send them to the wrong remedy.
    func testTimeoutIsReportedSeparately() {
        let recorder = RecordingRunner()
        recorder.answer = CommandResult(status: 124, output: "", timedOut: true)

        let caps = CapabilityProbe.probe(helper: "/opt/menfez/menfez-route",
                                         helperExists: { _ in true },
                                         using: recorder)

        XCTAssertFalse(caps.tunnelAvailable)
        XCTAssertEqual(caps.reason, TunnelSetup.timedOutReason)
    }

    /// Any other refusal keeps sudo's own last line, which is the only text
    /// that can explain a policy the app has never seen.
    func testOtherSudoFailureQuotesSudo() {
        let recorder = RecordingRunner()
        recorder.answer = CommandResult(status: 1,
                                        output: "Sorry, user burhan is not allowed to execute "
                                            + "'/opt/menfez/menfez-route' as root.")

        let caps = CapabilityProbe.probe(helper: "/opt/menfez/menfez-route",
                                         helperExists: { _ in true },
                                         using: recorder)

        XCTAssertFalse(caps.tunnelAvailable)
        let reason = try? XCTUnwrap(caps.reason)
        XCTAssertTrue(reason?.contains("not allowed to execute") ?? false,
                      "got \(reason ?? "nil")")
    }

    // MARK: - The setup command

    private let bundled = "/Applications/Menfez.app/Contents/MacOS/menfez-route"

    /// The copyable command runs the bundled setup script on the bundle's
    /// helper, each path single-quoted, and never names a sudoers rule for
    /// the bundle path itself.
    func testSetupCommandRunsBundledScriptQuoted() throws {
        let command = try XCTUnwrap(TunnelSetup.command(helper: bundled))
        XCTAssertEqual(command,
                       "sudo /bin/bash '/Applications/Menfez.app/Contents/Resources/install-helper.sh' "
                       + "'\(bundled)' \"$USER\"")
        XCTAssertFalse(command.contains("NOPASSWD"),
                       "the grant is written by the script, for the root-owned path only")
        XCTAssertFalse(command.contains("*"))
    }

    /// A renamed bundle with a space still works; anything a shell or sudoers
    /// would interpret is refused rather than escaped.
    func testSetupCommandRefusesUnsafePaths() {
        XCTAssertNotNil(TunnelSetup.command(helper: "/Users/a/My Apps/Menfez.app/Contents/MacOS/menfez-route"))
        for bad in ["/Users/a/x'y/Menfez.app/Contents/MacOS/menfez-route",
                    "/Users/a/$(reboot)/Menfez.app/Contents/MacOS/menfez-route",
                    "/Users/a/x;y/Menfez.app/Contents/MacOS/menfez-route",
                    "/Users/a/x\"y/Menfez.app/Contents/MacOS/menfez-route",
                    "/Users/a/x`y`/Menfez.app/Contents/MacOS/menfez-route",
                    "/Users/a/x\ny/Menfez.app/Contents/MacOS/menfez-route",
                    "/Users/a/x,y/Menfez.app/Contents/MacOS/menfez-route",
                    "/Users/a/../Menfez.app/Contents/MacOS/menfez-route",
                    "relative/Menfez.app/Contents/MacOS/menfez-route",
                    "/Users/a/İndir/Menfez.app/Contents/MacOS/menfez-route"] {
            XCTAssertNil(TunnelSetup.command(helper: bad), bad)
        }
    }

    /// The rule the setup script installs must name only the root-owned helper
    /// and must pass `visudo -c`. A rule that does not parse is the one failure
    /// that can lock a machine out of sudo, so it is checked, not assumed.
    func testSetupScriptWritesAValidatableRule() throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("install-helper.sh").path
        let result = Shell.run("/bin/bash", [script, "--print-sudoers", NSUserName()], timeout: 10)
        XCTAssertTrue(result.ok, result.output)
        let rule = result.output.split(separator: "\n").last.map(String.init) ?? ""
        XCTAssertEqual(rule, "\(NSUserName()) ALL=(root) NOPASSWD: \(TunnelSetup.trustedHelper)")

        let file = NSTemporaryDirectory() + "menfez-rule-\(UUID().uuidString)"
        try result.output.write(toFile: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: file) }
        let check = Shell.run(TunnelSetup.visudoPath, ["-c", "-f", file], timeout: 10)
        XCTAssertTrue(check.ok, "visudo rejected the generated rule: \(check.output)")

        // A user name that could smuggle sudoers syntax is refused.
        XCTAssertFalse(Shell.run("/bin/bash", [script, "--print-sudoers", "a ALL=(ALL) ALL"],
                                 timeout: 10).ok)
    }

    // MARK: - The default

    /// The value before the probe answers, and the shape of a machine with
    /// nothing installed: DPI on, tunnel off, one sentence of explanation.
    func testDPIOnlyDefaultIsUsable() {
        let caps = Capabilities.dpiOnly()
        XCTAssertTrue(caps.dpiAvailable)
        XCTAssertFalse(caps.tunnelAvailable)
        XCTAssertNotNil(caps.reason)
        // The sentence has to send the user to the thing that does work, not
        // just report a limitation.
        XCTAssertTrue(caps.reason?.contains("DPI") ?? false)
    }

    /// Capabilities is a value, so the app can hold it, publish it and compare
    /// it without a second source of truth.
    func testEquatable() {
        XCTAssertEqual(Capabilities(dpiAvailable: true, tunnelAvailable: false,
                                    reason: "x"),
                       Capabilities(dpiAvailable: true, tunnelAvailable: false,
                                    reason: "x"))
        XCTAssertNotEqual(Capabilities.dpiOnly(reason: "a"),
                          Capabilities.dpiOnly(reason: "b"))
    }
}
