// Capabilities.swift — what this machine can do, asked once, off the main thread.
//
// WHY THIS TYPE EXISTS
// --------------------
// The app has two ways to get Discord through: the DPI proxy, which is a
// listener inside this process and therefore needs nothing at all, and the
// WireGuard split tunnel, which needs root and therefore needs the one
// privileged helper to be installed and granted passwordless sudo.
//
// Before this type, the app behaved as if the tunnel were the only way: on a
// fresh machine every action shelled out to `sudo -n <helper>`, failed, and
// surfaced an error. To a stranger that reads as "the app is broken", when the
// truth is "the tunnel was never set up and you do not need it". So the two
// capabilities are named separately, probed once, and the UI branches on the
// answer instead of discovering it through failures.
//
// `dpiAvailable` is always true and that is not a placeholder: the engine is
// linked into the app, binds loopback, and is started with a plain function
// call. If it were ever false, the app would have nothing to offer, so a probe
// result of "no DPI" would be a packaging bug rather than a machine fact.
//
// THE PROBE IS ONE COMMAND
// ------------------------
// `sudo -n <helper> status` returns immediately in every case: with the sudoers
// rule it runs and exits 0, without it `-n` makes sudo fail at once instead of
// waiting for a password on a terminal that does not exist. That is the only
// privileged command the app runs to answer "can I use the tunnel", and it is
// not retried — see `Model.capabilities` in the app, which caches the result.

import Foundation

/// What the app may offer on this machine.
public struct Capabilities: Equatable, Sendable {

    /// The in-process proxy can run. Always true in a correctly built app.
    public var dpiAvailable: Bool

    /// The privileged helper is present and sudo runs it without a password.
    public var tunnelAvailable: Bool

    /// Why the tunnel is unavailable, in a sentence the user can act on.
    /// nil when the tunnel is available, so the UI can render "unavailable"
    /// as an explanation rather than as an error code.
    public var reason: String?

    public init(dpiAvailable: Bool = true,
                tunnelAvailable: Bool,
                reason: String? = nil) {
        self.dpiAvailable = dpiAvailable
        self.tunnelAvailable = tunnelAvailable
        self.reason = reason
    }

    /// The shape a machine with nothing installed produces.
    ///
    /// Used as the value before the probe answers, and by tests that want the
    /// rootless path without touching the filesystem.
    public static func dpiOnly(reason: String? = TunnelSetup.missingHelperReason)
        -> Capabilities {
        Capabilities(dpiAvailable: true, tunnelAvailable: false, reason: reason)
    }
}

/// The one-time setup, written down in one place.
///
/// WHY A COMMAND THAT RUNS THE BUNDLED SCRIPT
/// ------------------------------------------
/// `install.sh` remains the supported way to install, but it lives in the
/// source tree; a person who downloaded the .app does not have it. The bundle
/// carries `install-helper.sh`, the same script `install.sh --tunnel` runs, so
/// both grant exactly the same thing — one absolute, root-owned path, no
/// arguments, no wildcards — validated with `visudo -c` before it lands.
/// Showing the command in the help sheet keeps the tunnel optional without
/// pretending the grant is automatic.
///
/// The validation order matters: a malformed file in /etc/sudoers.d can break
/// sudo for every account, including the one trying to repair it. `visudo -c -f`
/// on a temp file catches that before the file is installed.
public enum TunnelSetup {

    /// Where the rule is written. Same path the installer uses.
    public static let sudoersPath = "/etc/sudoers.d/menfez"

    /// The helper's file name, for messages that cannot see the bundle.
    public static let helperName = "menfez-route"

    public static let missingHelperReason =
        "The tunnel needs a one-time setup: the privileged helper is not installed. "
        + "DPI mode works without it."

    /// The sentence a shipped .app produces on a fresh machine.
    ///
    /// The helper ships *inside* the bundle, so it is almost always present;
    /// what is missing is the sudo grant. Wording this as "sudo still asks for a
    /// password" would describe the mechanism rather than the situation and
    /// would read as a misconfiguration the user caused. It is not: the grant is
    /// optional by design, and the row that shows this is an offer, not a
    /// failure. So the sentence names the one-time setup and points at Help.
    /// Bilingual on purpose.
    ///
    /// The core has no access to the UI's language setting, and threading it
    /// through a capability probe to produce one sentence would put a UI
    /// concern in the network layer. Both strings are short, so both are
    /// carried and the view picks one.
    public static let notPermittedReason =
        "The tunnel needs a one-time setup. DPI works without it."
    public static let notPermittedReasonTR =
        "Tünel için bir kez kurulum gerekiyor. DPI kurulumsuz çalışır."

    public static let timedOutReason =
        "The helper didn't answer in time. The tunnel can't be used until it "
        + "does."
    public static let timedOutReasonTR =
        "Yardımcı program zamanında yanıt vermedi. Yanıt verene kadar tünel kullanılamaz."

    /// The sentence for a given language.
    public static func notPermitted(turkish: Bool) -> String {
        turkish ? notPermittedReasonTR : notPermittedReason
    }

    public static func timedOut(turkish: Bool) -> String {
        turkish ? timedOutReasonTR : timedOutReason
    }

    /// Where `visudo` lives. Absolute for the same reason every other tool path
    /// in the app is: `visudo` is in /usr/sbin, which is not on PATH for a
    /// launchd context, and a bare name that fails to resolve makes the whole
    /// `&&` chain stop without installing anything — a silent no-op is the
    /// worst outcome for a setup step the user believes they completed.
    public static let visudoPath = "/usr/sbin/visudo"

    /// The path sudo is granted, and the only one the app calls.
    public static let trustedHelper = Path.trustedHelper

    /// The setup script inside the bundle, beside the helper it installs.
    public static func setupScript(helper: String) -> String {
        let contents = ((helper as NSString).deletingLastPathComponent as NSString)
            .deletingLastPathComponent
        return contents + "/Resources/install-helper.sh"
    }

    /// True for a path that can be pasted into a shell inside single quotes
    /// without any character meaning something: absolute, ASCII letters,
    /// digits, space and `/._-` only, no `..`.
    public static func isSafePath(_ path: String) -> Bool {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 /._-")
        return path.hasPrefix("/") && !path.contains("..")
            && path.allSatisfy { allowed.contains($0) }
    }

    /// The single line a user can copy to set up the tunnel helper, or nil when
    /// the bundle path holds a character that is unsafe to paste into a shell.
    ///
    /// `helper` is the copy inside the bundle. The script it runs copies that
    /// binary, and Homebrew's WireGuard tools, into the root-owned
    /// /Library/PrivilegedHelperTools/menfez, then grants `$USER` exactly
    /// `trustedHelper` — never the bundle path, which the user can write. The
    /// script validates the rule with `visudo -c -f` on a `mktemp` file before
    /// installing it, and re-checks `visudo -c` afterwards.
    public static func command(helper: String) -> String? {
        let script = setupScript(helper: helper)
        guard isSafePath(helper), isSafePath(script) else { return nil }
        return "sudo /bin/bash '\(script)' '\(helper)' \"$USER\""
    }

    /// Turn sudo's refusal into a sentence that names the fix.
    ///
    /// The two common cases are worth separating. "a password is required"
    /// means the rule is missing: the user can fix it with the command above.
    /// Anything else (a helper that crashes, a policy that denies it) is a
    /// different problem, and quoting sudo's own last line is more useful than
    /// a generic message.
    public static func refusalReason(for result: CommandResult) -> String {
        if result.timedOut { return timedOutReason }
        let text = result.output.lowercased()
        if text.contains("password is required")
            || text.contains("a terminal is required")
            || text.contains("no tty present") {
            return notPermittedReason
        }
        let detail = result.tail(1)
        if detail.isEmpty {
            return "sudo could not run the helper (exit \(result.status)); "
                + "the tunnel is unavailable."
        }
        return "sudo could not run the helper (exit \(result.status)): \(detail)"
    }
}

/// Ask the machine, once, what it can do.
public enum CapabilityProbe {

    /// The one privileged command this probe runs. Absolute, like every other
    /// tool path in the app, so a modified PATH cannot change what is executed.
    public static let sudoPath = "/usr/bin/sudo"

    /// The subcommand used as a liveness check.
    ///
    /// `status` exists in every helper version (it predates this probe), needs
    /// root, and prints one short report — enough to prove sudo ran the binary
    /// rather than merely found it.
    public static let helperArguments = ["status"]

    /// Short on purpose. `sudo -n` does not wait for a password, so anything
    /// slower than a couple of seconds is a hung helper, not a slow one, and
    /// the launch path must not sit behind it.
    public static let timeout: TimeInterval = 5

    /// Probe both capabilities.
    ///
    /// `helperExists` is injected so a test can describe "the helper is not
    /// installed" without depending on this machine's /Applications. The
    /// production default is the same check `Backend` uses to decide whether it
    /// is running from a bundle or from a build directory.
    public static func probe(helper: String,
                             helperExists: (String) -> Bool = {
                                 FileManager.default.isExecutableFile(atPath: $0)
                                     && Shell.trustViolation($0) == nil
                             },
                             using runner: CommandRunner = SystemRunner())
        -> Capabilities {

        guard !helper.isEmpty, helperExists(helper) else {
            // No process is spawned at all in this case. That is the rootless
            // path's whole promise: a fresh install never runs sudo.
            return .dpiOnly(reason: TunnelSetup.missingHelperReason)
        }

        let result = runner.run(sudoPath, ["-n", helper] + helperArguments,
                                timeout: timeout)
        if result.ok {
            return Capabilities(dpiAvailable: true, tunnelAvailable: true,
                                reason: nil)
        }
        return Capabilities(dpiAvailable: true, tunnelAvailable: false,
                            reason: TunnelSetup.refusalReason(for: result))
    }
}
