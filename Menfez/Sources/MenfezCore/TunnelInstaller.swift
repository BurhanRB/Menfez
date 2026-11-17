// TunnelInstaller.swift — the "Set up tunnel" / "Remove tunnel" buttons.
//
// The one-time setup used to be a command the user pasted into Terminal. The
// buttons run the same bundled script, as root, through macOS's own
// administrator password dialog: `osascript` with `do shell script ... with
// administrator privileges`. Nothing is looked up on PATH: bash, osascript, the
// script and the helper are absolute paths, and the script and the helper are
// the copies inside this app bundle. Every value is passed through AppleScript's
// `quoted form of`, so the shell sees each one as a single word.

import Foundation

public enum TunnelInstallAction: Equatable, Sendable {
    case install
    case remove
}

/// What one run of the installer came to.
public enum TunnelInstallOutcome: Equatable, Sendable {
    case succeeded
    /// The user closed the password dialog. Not an error.
    case cancelled
    /// The script's own last error line, for the status text.
    case failed(String)
}

/// What the buttons show.
public enum TunnelInstallState: Equatable, Sendable {
    case idle
    case running(TunnelInstallAction)
    case succeeded(TunnelInstallAction)
    case cancelled(TunnelInstallAction)
    case failed(TunnelInstallAction, String)

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    /// The state for a new run, or nil while one is already running: a second
    /// click must not open a second password dialog.
    public func starting(_ action: TunnelInstallAction) -> TunnelInstallState? {
        isRunning ? nil : .running(action)
    }

    public static func finished(_ action: TunnelInstallAction,
                                _ outcome: TunnelInstallOutcome) -> TunnelInstallState {
        switch outcome {
        case .succeeded: return .succeeded(action)
        case .cancelled: return .cancelled(action)
        case .failed(let detail): return .failed(action, detail)
        }
    }
}

public enum TunnelInstaller {

    public static let osascriptPath = "/usr/bin/osascript"
    public static let bashPath = "/bin/bash"

    /// Long enough for the user to read the dialog and for the script to copy
    /// and re-sign the WireGuard tools.
    public static let timeout: TimeInterval = 300

    /// An AppleScript string literal. Paths are already limited to safe
    /// characters; this escaping is the second line, not the first.
    static func literal(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Same rule install-helper.sh applies, checked here so a bad name never
    /// reaches a root shell.
    public static func isValidUser(_ user: String) -> Bool {
        user != "root"
            && user.range(of: #"^[A-Za-z_][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil
    }

    /// The AppleScript source, or nil when a path or the user name is unsafe.
    ///
    /// `helper` is the copy inside the bundle; the script lives beside it in
    /// Contents/Resources. `user` is passed explicitly because the shell runs
    /// as root, where `$USER` would be root.
    public static func appleScript(_ action: TunnelInstallAction,
                                   helper: String, user: String) -> String? {
        let script = TunnelSetup.setupScript(helper: helper)
        guard TunnelSetup.isSafePath(helper), TunnelSetup.isSafePath(script) else { return nil }
        let args: [String]
        switch action {
        case .install:
            guard isValidUser(user) else { return nil }
            args = [script, helper, user]
        case .remove:
            args = [script, "--remove"]
        }
        let words = args.map { " & \" \" & quoted form of \(literal($0))" }.joined()
        return "do shell script \(literal(bashPath))\(words) with administrator privileges"
    }

    /// Run the installer and wait. Blocking: call it off the main actor.
    public static func run(_ action: TunnelInstallAction, helper: String, user: String,
                           using runner: CommandRunner = SystemRunner()) -> TunnelInstallOutcome {
        guard let source = appleScript(action, helper: helper, user: user) else {
            return .failed("unsafe path or user name")
        }
        return outcome(of: runner.run(osascriptPath, ["-e", source], timeout: timeout))
    }

    /// osascript reports a closed dialog as error -128, and a script failure as
    /// `execution error: <stderr> (<status>)`.
    public static func outcome(of result: CommandResult) -> TunnelInstallOutcome {
        if result.ok { return .succeeded }
        if result.timedOut { return .failed("timed out") }
        if result.output.contains("(-128)") || result.output.contains("User canceled") {
            return .cancelled
        }
        let lines = result.output.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        var line = lines.last(where: { $0.contains("error:") }) ?? lines.last ?? ""
        // "0:142: execution error: error: <text> (1)" -> "<text>"
        if let r = line.range(of: "execution error:") { line = String(line[r.upperBound...]) }
        line = line.replacingOccurrences(of: #"\s*\(-?\d+\)$"#, with: "", options: .regularExpression)
        line = line.replacingOccurrences(of: #"^\s*error:\s*"#, with: "", options: .regularExpression)
        line = line.trimmingCharacters(in: .whitespaces)
        return .failed(line.isEmpty ? "exit \(result.status)" : line)
    }
}
