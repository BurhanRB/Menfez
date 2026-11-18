// HelperClient.swift — the one place the app talks to the privileged helper.
//
// WHY THIS IS IN CORE, NOT IN THE APP
// Two claims about this file have to be tested, and neither can be tested from
// the SwiftUI target (a test target cannot import an executable):
//
//   1. The refresh path spawns no privileged process. Proving that means
//      counting the calls, which means the counting has to live where a test
//      can reach it.
//   2. An app newer than its helper still works. Proving that means feeding the
//      client a reply from an old helper, which means the fallback cannot be
//      buried in SwiftUI.
//
// WHAT THIS IS NOT
// It is not a second privileged entry point. Every call is `sudo -n <helper>
// <args>` with the same absolute path, so the sudoers rule stays one line.
// Adding a method here adds an argument to an existing grant, never a new one.

import Foundation

/// Everything the app asks the helper for, and the count of what it asked.
public final class HelperClient: @unchecked Sendable {

    /// The helper's absolute path, exactly as the sudoers rule names it.
    public let helper: String

    /// How each call is started. Injectable so a test sees calls instead of
    /// processes; production always uses the real one.
    private let launcher: (String, [String], TimeInterval) -> CommandResult

    /// The same, with bytes for the child's standard input (`--key-stdin`).
    private let inputLauncher: (String, [String], TimeInterval, Data) -> CommandResult

    /// Where `switch` finds a profile's key when its file points at the
    /// Keychain. Takes the profile name.
    private let profileKey: (String) -> ProfileKeys.Lookup

    private let lock = NSLock()
    private var _spawns: [String: Int] = [:]

    /// A client with an injected launcher. Spawns nothing on its own, so it
    /// runs no trust check: a fake launcher has no root to protect.
    /// Without `inputLauncher` a call with input runs through `launcher`
    /// (the input dropped); without `profileKey` every key is in its file.
    public init(helper: String,
                launcher: @escaping (String, [String], TimeInterval) -> CommandResult,
                inputLauncher: ((String, [String], TimeInterval, Data) -> CommandResult)? = nil,
                profileKey: @escaping (String) -> ProfileKeys.Lookup = { _ in .inFile }) {
        self.helper = helper
        self.launcher = launcher
        self.inputLauncher = inputLauncher ?? { tool, args, timeout, _ in launcher(tool, args, timeout) }
        self.profileKey = profileKey
    }

    /// The production client. Before every `sudo` it checks that the helper
    /// and each directory above it are root-owned and not group/other
    /// writable; otherwise the user could swap the binary sudo runs as root.
    public convenience init(helper: String,
                            trust: @escaping (String) -> String? = { Shell.trustViolation($0) }) {
        self.init(helper: helper, launcher: { tool, args, timeout in
            if let why = trust(helper) {
                return CommandResult(status: 126, output: Shell.untrustedMessage(why))
            }
            return Shell.run(tool, args, timeout: timeout)
        }, inputLauncher: { tool, args, timeout, input in
            if let why = trust(helper) {
                return CommandResult(status: 126, output: Shell.untrustedMessage(why))
            }
            return Shell.run(tool, args, timeout: timeout, stdin: input)
        }, profileKey: { name in
            guard Validate.isSafeStem(name) else { return .inFile }
            let file = (Path.profiles as NSString).appendingPathComponent(name + ".conf")
            return ProfileKeys.lookup(file: file, store: KeychainStore())
        })
    }

    // MARK: - Spawn accounting

    /// Every process this client has started and the count, by tool.
    ///
    /// Used by the measurement tests. It is production code rather than a test
    /// hook for two reasons: a counter that only exists in a test build would
    /// measure a different program, and having it here means the read path's
    /// budget is visible to anyone reading this file.
    public var spawns: [String: Int] {
        lock.lock(); defer { lock.unlock() }
        return _spawns
    }

    public func resetSpawns() {
        lock.lock(); _spawns = [:]; lock.unlock()
    }

    /// True when a `sudo` has been started since the last reset.
    ///
    /// `sudo` is the only route to root this program has; if that ever changes,
    /// this check has to change with it, which is why it is one named place.
    public var spawnedRoot: Bool {
        spawns["sudo"] != nil
    }

    /// Count a process the app started for itself, without the helper.
    ///
    /// The unit tests in `ReadPathTests` are what assert the fast path starts no
    /// privileged process, but this counter is what the app can show if the
    /// question ever comes up in the field. It is deliberately on the same
    /// `spawns` map as `sudo` so there is one place to look.
    public func recordLocal(_ tool: String) {
        record(tool)
    }

    private func record(_ tool: String) {
        lock.lock(); _spawns[tool, default: 0] += 1; lock.unlock()
    }

    /// Run one helper subcommand through passwordless sudo.
    ///
    /// `-n` is not decoration: without it a missing sudoers rule would leave a
    /// password prompt hanging behind a window with no terminal, and the app
    /// would appear to freeze.
    public func run(_ args: [String], timeout: TimeInterval = 120) -> CommandResult {
        record("sudo")
        return launcher("/usr/bin/sudo", ["-n", helper] + args, timeout)
    }

    private func decode<T: Decodable>(_ type: T.Type,
                                      _ args: [String],
                                      timeout: TimeInterval = 120) -> T? {
        let result = run(args, timeout: timeout)
        guard result.ok else { return nil }
        return JSON.decode(type, from: result.output)
    }

    // MARK: - Reads

    /// The privileged half of a report.
    ///
    /// Returns nil when nothing could be read. A caller must treat nil as
    /// "these fields are unknown" and draw a dash; it must never be read as
    /// "the tunnel is down", because the unprivileged half is what knows that.
    ///
    /// BACKWARDS COMPATIBILITY
    /// `facts` is new. A helper from an earlier build does not know the
    /// subcommand and exits 2 with a usage line, so a usage failure falls back
    /// to `report --fast`, which every version has understood. The fallback
    /// costs what the old path cost — once, on the slow timer, not on every
    /// redraw — and it is what keeps an app updated ahead of its helper
    /// working instead of silently blanking the tunnel rows.
    ///
    /// Only exit 2 triggers it. Any other failure is a real failure: a helper
    /// that is missing, not permitted, or out of space must not have a second
    /// command attempted on its behalf.
    public func facts(timeout: TimeInterval = 30) -> RouteManager.TunnelFacts? {
        let direct = run(["facts"], timeout: timeout)
        if direct.ok,
           let facts = JSON.decode(RouteManager.TunnelFacts.self, from: direct.output) {
            return facts
        }
        guard direct.status == 2 else { return nil }

        // Old helper: ask for the report it does understand.
        guard let report = decode(Report.self, ["report", "--fast"], timeout: 60)
        else { return nil }
        return RouteManager.TunnelFacts(tunnel: report.tunnel,
                                        endpoint: report.endpoint,
                                        peerPubkey: report.peerPubkey,
                                        handshakeEpoch: report.handshakeEpoch,
                                        transfer: report.transfer)
    }

    /// A whole report built by the helper, privileged fields included.
    ///
    /// Not on the refresh path: that would put a root process back on the
    /// timer. Kept for a one-off "show me everything now".
    public func report(full: Bool = false, timeout: TimeInterval = 60) -> Report? {
        decode(Report.self, full ? ["report"] : ["report", "--fast"],
               timeout: timeout)
    }

    public func profiles(timeout: TimeInterval = 30) -> ProfilesResponse? {
        decode(ProfilesResponse.self, ["profiles"], timeout: timeout)
    }

    public func dns(timeout: TimeInterval = 90) -> DNSReport? {
        decode(DNSReport.self, ["dns", "status"], timeout: timeout)
    }

    public func detail(_ what: String, value: String? = nil,
                       timeout: TimeInterval = 60) -> DetailResponse? {
        var args = ["detail", what]
        if let value { args += ["--value", value] }
        return decode(DetailResponse.self, args, timeout: timeout)
    }

    // MARK: - Mutations

    /// Run a command that changes something, and always return an ActionResult.
    ///
    /// A non-JSON reply means the helper never ran (sudo refused, binary gone),
    /// so the raw text is surfaced as the error. Returning nil here would make
    /// the UI say "helper did not respond", which is true but useless; the
    /// tail of sudo's own message is what the user can act on.
    /// Longest a mutating helper call may take before the client gives up.
    ///
    /// The worst case is `switch`: `wg-quick down` and `wg-quick up` (each
    /// bounded by `wireGuardTimeout`), the transport probe, plus a minute for
    /// the route commands around them. Timing out earlier would kill `sudo`
    /// while the helper is half-way through a route change.
    public static let actTimeout: TimeInterval =
        2 * RouteManager.wireGuardTimeout + RouteManager.transportProbeBudget + 60

    ///
    /// `switch` to a profile whose key is in the Keychain gets the key on
    /// standard input and `--key-stdin`; the key is never an argument.
    @discardableResult
    public func act(_ args: [String], timeout: TimeInterval = HelperClient.actTimeout) -> ActionResult {
        let result: CommandResult
        if args.first == "switch", args.count > 1 {
            switch profileKey(args[1]) {
            case .inFile:
                result = run(args, timeout: timeout)
            case .unreadable:
                return ActionResult.failure(ProfileKeys.readFailure)
            case .key(let key):
                record("sudo")
                result = inputLauncher("/usr/bin/sudo", ["-n", helper] + args + ["--key-stdin"],
                                       timeout, Data((key + "\n").utf8))
            }
        } else {
            result = run(args, timeout: timeout)
        }
        if let decoded = JSON.decode(ActionResult.self, from: result.output) {
            return decoded
        }
        return ActionResult(ok: false, error: result.tail(3))
    }
}
