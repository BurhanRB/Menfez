// DiscordLauncher.swift — start Discord pointed at this proxy.
//
// THE ONE THING IT DOES
// ---------------------
//   open -a Discord --args --proxy-server=http://127.0.0.1:<port>
//
// Electron reads `--proxy-server` at process start, so the flag only takes
// effect on a Discord that was launched with it. A Discord that is already
// running ignores the new arguments entirely, which is the single most confusing
// failure mode of this feature: the user clicks, nothing looks wrong, and
// Discord still cannot connect. `preflight` exists so the UI can say "quit
// Discord first" before a click that would otherwise do nothing visible.
//
// WHAT IT DOES NOT DO
// -------------------
// It does not touch Discord's `Preferences`, its `Local State`, or any
// system-wide network setting. The one exception is a single key added to
// Discord's `settings.json` (see `allowUpdateFailOpen`), only when missing,
// so the splash stops waiting on an update check the DPI always kills; delete
// the key to undo it. `--proxy-server` is a per-process
// argument; nothing outside that process changes, so quitting Discord removes
// the proxy from the picture completely. That is the property that makes this
// safe to ship in a free tier.
//
// WHY THE RUNNING CHECK IS INJECTED
// ---------------------------------
// Only AppKit can enumerate running applications, and this file lives in
// MenfezCore, which the root helper `menfez-route` also links. Importing AppKit
// there would put a GUI framework inside a privileged command-line tool for the
// sake of one boolean. The check is therefore a parameter: the app passes
// `NSWorkspace`-backed code, the helper passes nothing, and the tests pass a
// value.

import Foundation

public enum DiscordLauncher {

    public static let applicationName = "Discord"

    /// Bundle identifier of the shipping Discord client.
    ///
    /// Kept next to the name so the app's running check has one place to read
    /// it from; a renamed copy in /Applications is still caught by name.
    public static let bundleID = "com.hnc.Discord"

    public enum LaunchError: Error, Equatable, CustomStringConvertible {
        case proxyNotRunning
        case invalidPort(Int)
        case alreadyRunning
        case notInstalled
        case openFailed(String)

        public var description: String {
            switch self {
            case .proxyNotRunning:
                return "start DPI mode first — there is no proxy port to point Discord at"
            case .invalidPort(let port):
                return "port \(port) is not usable"
            case .alreadyRunning:
                return "Discord is already running; quit it first, because the proxy flag is read only at launch"
            case .notInstalled:
                return "Discord was not found in /Applications"
            case .openFailed(let why):
                return "could not launch Discord: \(why)"
            }
        }
    }

    /// The arguments Discord needs.
    ///
    /// Exposed on its own so the exact flag string is asserted in one place. A
    /// typo here would be a silent no-op, which is the worst kind of bug in a
    /// feature whose whole value is "this app now goes through the proxy".
    /// The running Discord to offer a restart for, as its PID, or nil.
    ///
    /// Leaving DPI mode closes the proxy, and a Discord launched with
    /// `--proxy-server` keeps dialling that dead port until it restarts.
    /// `psOutput` is `ps -axo pid=,args=`. Only Discord's main executable is
    /// matched (its helpers are "Discord Helper …"), and only with a proxy flag
    /// pointing at `port`, our loopback proxy; any loopback port when `port`
    /// is unknown. Nothing to offer unless the move is out of DPI mode.
    public static func restartCandidate(psOutput: String, from: RunMode, to: RunMode,
                                        port: Int?) -> Int32? {
        guard from == .dpi, to != .dpi else { return nil }
        let flag = "--proxy-server=http://127.0.0.1:" + (port.map(String.init) ?? "")
        for line in psOutput.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard fields.count == 2, let pid = Int32(fields[0]) else { continue }
            let args = " " + fields[1] + " "
            guard args.contains("/Discord.app/Contents/MacOS/Discord "),
                  let range = args.range(of: " " + flag) else { continue }
            // With a port, it must be that exact port, not a longer one.
            if port != nil, args[range.upperBound] != " " { continue }
            return pid
        }
        return nil
    }

    // MARK: - Update fail-open

    /// Discord's own setting: after this many ms of failed update checks the
    /// splash starts the already-installed version instead of retrying forever.
    ///
    /// Needed because the updater (`updater.node`, Rust reqwest over
    /// SecureTransport) ignores `--proxy-server`, resolves names with system
    /// DNS, and speaks TLS 1.2 only. On the measured ISP that TLS 1.2 handshake
    /// is cut after the server's first segment even through this proxy, so no
    /// launch flag can make the check succeed; only failing open gets past the
    /// "Checking for updates" splash.
    public static let updateDeadlineKey = "DESKTOP_TTI_UPDATE_CHECK_DEADLINE_MS"
    public static let updateDeadlineMs = 10_000

    public static var settingsFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/discord/settings.json")
    }

    /// `settings.json` with the deadline added, or nil when nothing should be
    /// written: unparseable JSON, or a value the user (or we) already set.
    public static func settingsAddingUpdateDeadline(_ data: Data) -> Data? {
        guard var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              json[updateDeadlineKey] == nil else { return nil }
        json[updateDeadlineKey] = updateDeadlineMs
        return try? JSONSerialization.data(withJSONObject: json,
                                           options: [.prettyPrinted, .sortedKeys])
    }

    /// What `allowUpdateFailOpen` did. Only `failed` needs the user: the file
    /// is there but macOS (app-data protection) or the disk refused us, so the
    /// splash may still wait on the update check.
    public enum FailOpenResult: Equatable, Sendable {
        case written, unchanged, noSettings
        /// EPERM/EACCES: macOS app-data protection said no. Retrying only
        /// raises the system's "access blocked" notification again.
        case denied(String)
        case failed(String)
    }

    /// EPERM/EACCES, wherever Foundation put it.
    static func isPermissionDenied(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain,
           [CocoaError.fileReadNoPermission.rawValue,
            CocoaError.fileWriteNoPermission.rawValue].contains(ns.code) { return true }
        let posix = (ns.domain == NSPOSIXErrorDomain ? ns : ns.userInfo[NSUnderlyingErrorKey] as? NSError)
        if let posix, posix.domain == NSPOSIXErrorDomain,
           posix.code == Int(EPERM) || posix.code == Int(EACCES) { return true }
        return ns.localizedDescription.contains("Operation not permitted")
    }

    /// Add the deadline to Discord's settings if it is missing. No file means
    /// Discord never ran, so there is no installed version to fall back to and
    /// nothing to gain. Call only while Discord is not running, or its next
    /// save overwrites the key.
    @discardableResult
    public static func allowUpdateFailOpen(settings url: URL = settingsFile) -> FailOpenResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return .noSettings }
        do {
            let data = try Data(contentsOf: url)
            guard let updated = settingsAddingUpdateDeadline(data) else { return .unchanged }
            try updated.write(to: url, options: .atomic)
            return .written
        } catch {
            return isPermissionDenied(error) ? .denied(error.localizedDescription)
                                             : .failed(error.localizedDescription)
        }
    }

    /// What happened to `settings.json` last time, kept so the app reads the
    /// file at most once per path: every read of another app's data can raise
    /// macOS's "access blocked" notification.
    ///
    /// Written or already present: never again for that path. Denied: not
    /// again until `reset()` (the hint's "Try again"). No file or another
    /// error: tried again next launch.
    public struct FailOpenMemory {
        let defaults: UserDefaults
        static let doneKey = "discordFailOpenDone"
        static let deniedKey = "discordFailOpenDenied"
        static let hintDismissedKey = "discordFailOpenHintDismissed"

        public init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }

        public func shouldTry(_ url: URL) -> Bool {
            defaults.string(forKey: Self.doneKey) != url.path
                && defaults.string(forKey: Self.deniedKey) != url.path
        }

        public func record(_ result: FailOpenResult, for url: URL) {
            switch result {
            case .written, .unchanged:
                defaults.set(url.path, forKey: Self.doneKey)
                defaults.removeObject(forKey: Self.deniedKey)
            case .denied:
                defaults.set(url.path, forKey: Self.deniedKey)
                defaults.set(false, forKey: Self.hintDismissedKey)
            case .noSettings, .failed:
                break
            }
        }

        /// The in-app hint stays until the user closes it, so it survives the
        /// relaunch macOS asks for after Full Disk Access is turned on.
        public var showsHint: Bool {
            defaults.string(forKey: Self.deniedKey) != nil
                && !defaults.bool(forKey: Self.hintDismissedKey)
        }

        public func dismissHint() { defaults.set(true, forKey: Self.hintDismissedKey) }

        /// Forget the denial so the next launch tries once more.
        public func reset() { defaults.removeObject(forKey: Self.deniedKey) }
    }

    public static func arguments(port: Int) -> [String] {
        ["-a", applicationName,
         "--args", "--proxy-server=http://127.0.0.1:\(port)"]
    }

    /// Whether a launch may proceed.
    ///
    /// Refuses when the proxy has no port (nothing to point at), when the port
    /// is outside 1-65535, and when Discord is already running. The reason is a
    /// value, so the UI can render the specific sentence rather than a generic
    /// failure.
    public static func preflight(port: Int?,
                                 discordRunning: Bool = false) -> Result<Int, LaunchError> {
        guard let port else { return .failure(.proxyNotRunning) }
        guard port > 0, port <= 65535 else { return .failure(.invalidPort(port)) }
        if discordRunning { return .failure(.alreadyRunning) }
        return .success(port)
    }

    /// Launch Discord through the proxy.
    ///
    /// `open` is used rather than `NSWorkspace.openApplication(configuration:)`
    /// because the documented way to pass `--proxy-server` to an Electron app is
    /// `open --args`, and the LaunchServices configuration object has no field
    /// for arbitrary argv. `open` is in `/usr/bin`, present on every macOS
    /// install, and takes an argument *list* — never a shell string — so a port
    /// cannot inject anything.
    @discardableResult
    public static func launch(port: Int?,
                              discordRunning: Bool = false,
                              using runner: CommandRunner = SystemRunner())
        -> Result<[String], LaunchError> {
        switch preflight(port: port, discordRunning: discordRunning) {
        case .failure(let error):
            return .failure(error)
        case .success(let validPort):
            let args = arguments(port: validPort)
            let result = runner.run("open", args, timeout: 15)
            if result.ok { return .success(args) }
            // `open` reports "Unable to find application named 'Discord'" on
            // stdout in some macOS versions and on stderr in others; Shell
            // merges them, so one substring test covers both. Keeping this
            // distinct from a generic failure lets the UI say "Discord is not
            // installed" instead of "something went wrong".
            let text = result.output.lowercased()
            if text.contains("unable to find") || text.contains("does not exist")
                || text.contains("no such file") {
                return .failure(.notInstalled)
            }
            return .failure(.openFailed(result.tail(1)))
        }
    }
}
