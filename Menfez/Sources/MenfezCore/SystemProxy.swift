// SystemProxy.swift — "Use in browsers too": the system's automatic proxy
// (PAC) setting, changed only by the helper (`menfez-route proxy`, helper 6).
//
// WHAT IT TOUCHES
// For every enabled network service, the "Automatic proxy configuration" URL
// and its on/off state, through /usr/sbin/networksetup. The helper lists the
// services itself; the app sends only a port (1024-65535), never a name.
//
// HOW IT IS UNDONE
// Before the first change the helper records each service's previous URL and
// state in /Library/Application Support/Menfez/proxy-state.json (root, 0600,
// persistent: the system setting survives a restart, so the record must too).
// A second `pac` (a new port) keeps that original. `proxy off` puts every
// recorded service back, switches off our URL on any service it finds without
// a record, and deletes the file. `teardown`, quitting the app,
// `install-helper.sh --remove` and `uninstall.sh` all run it. The PAC says
// "PROXY ...; DIRECT", so a stale setting after a crash costs a refused
// connection, not the internet; the next launch runs `off` (`livePort`).

import Foundation

public enum SystemProxy {

    public static let ports = 1024...65535

    public static var statePath: String {
        (Path.systemSupport as NSString).appendingPathComponent("proxy-state.json")
    }

    /// What one service had. `url` nil is networksetup's "(null)".
    public struct Setting: Codable, Equatable, Sendable {
        public var url: String?
        public var enabled: Bool
        public init(url: String?, enabled: Bool) {
            self.url = url
            self.enabled = enabled
        }
    }

    /// The record `off` restores from.
    public struct State: Codable, Equatable, Sendable {
        public var version: Int
        public var port: Int
        /// Service name → its setting before Menfez changed it.
        public var saved: [String: Setting]
        public init(port: Int, saved: [String: Setting]) {
            self.version = 1
            self.port = port
            self.saved = saved
        }
    }

    /// `proxy status`: is our PAC set on any enabled service, and on which port.
    public struct Status: Codable, Equatable, Sendable {
        public var active: Bool
        public var port: Int?
        public init(active: Bool, port: Int? = nil) {
            self.active = active
            self.port = port
        }
    }

    // MARK: - Pure parts

    /// The helper's port argument: digits only, 1024-65535.
    public static func port(_ raw: String?) -> Int? {
        guard let raw, (1...5).contains(raw.count), raw.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(raw), ports.contains(value) else { return nil }
        return value
    }

    public static func pacURL(port: Int) -> String {
        "http://127.0.0.1:\(port)\(PACFile.path)"
    }

    /// The port when `url` is a Menfez PAC URL (any port), else nil.
    public static func ourPort(url: String?) -> Int? {
        let prefix = "http://127.0.0.1:"
        guard let url, url.hasPrefix(prefix), url.hasSuffix(PACFile.path) else { return nil }
        let middle = url.dropFirst(prefix.count).dropLast(PACFile.path.count)
        return port(String(middle))
    }

    /// `networksetup -listallnetworkservices`: enabled services only. The
    /// legend line ("An asterisk (*) denotes …") and "*"-marked disabled
    /// services are skipped; names with spaces are kept whole.
    public static func enabledServices(_ output: String) -> [String] {
        var lines = output.components(separatedBy: "\n")
        if let first = lines.first, first.contains("asterisk") { lines.removeFirst() }
        return lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            // A name starting with "-" would read as an option to networksetup.
            .filter { !$0.isEmpty && !$0.hasPrefix("*") && !$0.hasPrefix("-") }
    }

    /// `networksetup -getautoproxyurl <service>`: "URL: …" and "Enabled: Yes|No".
    public static func setting(_ output: String) -> Setting? {
        var url: String??
        var enabled: Bool?
        for line in output.components(separatedBy: "\n") {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("URL:") {
                let value = text.dropFirst(4).trimmingCharacters(in: .whitespaces)
                url = .some(value.isEmpty || value == "(null)" ? nil : value)
            } else if text.hasPrefix("Enabled:") {
                let value = text.dropFirst(8).trimmingCharacters(in: .whitespaces)
                enabled = value == "Yes" ? true : value == "No" ? false : nil
            }
        }
        guard let url, let enabled else { return nil }
        return Setting(url: url, enabled: enabled)
    }

    /// The record to keep before pointing services at `port`. What is already
    /// recorded is the user's original and is never replaced; a service seen
    /// for the first time is added; our own URL is never taken for an
    /// original (a lost record, a second run) and is remembered as "off".
    public static func remember(current: [String: Setting], previous: State?, port: Int) -> State {
        var saved = previous?.saved ?? [:]
        for (service, setting) in current where saved[service] == nil {
            saved[service] = ourPort(url: setting.url) == nil ? setting : Setting(url: nil, enabled: false)
        }
        return State(port: port, saved: saved)
    }

    /// networksetup arguments that point `services` at our PAC.
    public static func setCommands(services: [String], port: Int) -> [[String]] {
        services.flatMap { service in
            [["-setautoproxyurl", service, pacURL(port: port)],
             ["-setautoproxystate", service, "on"]]
        }
    }

    /// networksetup arguments that put back what `state` recorded, for the
    /// services that still exist. A service that had no URL is switched off;
    /// networksetup cannot empty the field, so our URL stays there, unused.
    public static func restoreCommands(state: State, existing: [String]) -> [[String]] {
        state.saved.keys.sorted().filter(existing.contains).flatMap { service -> [[String]] in
            let old = state.saved[service]!
            var out: [[String]] = []
            if let url = old.url { out.append(["-setautoproxyurl", service, url]) }
            out.append(["-setautoproxystate", service, old.enabled ? "on" : "off"])
            return out
        }
    }

    /// The app's decision: the port the system should point at, or nil for off.
    public static func wanted(enabled: Bool, dpiRunning: Bool, port: Int?) -> Int? {
        guard enabled, dpiRunning, let port, ports.contains(port) else { return nil }
        return port
    }

    /// Our port when the system's current proxy settings (primary service)
    /// use a Menfez PAC. Read as the user, no process: launch-time recovery.
    public static func livePort(settings: [String: Any]? = systemSettings()) -> Int? {
        guard let settings, (settings["ProxyAutoConfigEnable"] as? Int) == 1 else { return nil }
        return ourPort(url: settings["ProxyAutoConfigURLString"] as? String)
    }

    public static func systemSettings() -> [String: Any]? {
        CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any]
    }

    // MARK: - State file

    /// The record, nil when there is none; `corrupt` when a file exists that
    /// cannot be read (then nothing is changed: it may hold the only copy).
    static func load(path: String) -> (state: State?, corrupt: Bool) {
        guard FileManager.default.fileExists(atPath: path) else { return (nil, false) }
        guard let data = FileManager.default.contents(atPath: path),
              let state = try? JSONDecoder().decode(State.self, from: data), state.version == 1
        else { return (nil, true) }
        return (state, false)
    }

    static func save(_ state: State, path: String) -> Bool {
        guard let text = StateFile.encode(state) else { return false }
        return StateFile.write(text, to: path, mode: 0o600, dirMode: 0o700)
    }

    // MARK: - Root side (the helper)

    static func listServices(using runner: CommandRunner) -> [String]? {
        let result = runner.run("networksetup", ["-listallnetworkservices"], timeout: 15)
        return result.ok ? enabledServices(result.output) : nil
    }

    static func read(_ service: String, using runner: CommandRunner) -> Setting? {
        let result = runner.run("networksetup", ["-getautoproxyurl", service], timeout: 15)
        return result.ok ? setting(result.output) : nil
    }

    /// Point every enabled service at the PAC on `port`. All or nothing: a
    /// failed change puts back what was recorded.
    public static func pac(port: Int, statePath: String = statePath,
                           using runner: CommandRunner = SystemRunner()) -> ActionResult {
        guard ports.contains(port) else { return .failure("port must be 1024-65535") }
        let (previous, corrupt) = load(path: statePath)
        if corrupt {
            return .failure("the saved proxy state at \(statePath) is unreadable; run `proxy off` after fixing it")
        }
        guard let services = listServices(using: runner), !services.isEmpty else {
            return .failure("networksetup listed no network services")
        }
        var current: [String: Setting] = [:]
        for service in services where previous?.saved[service] == nil {
            guard let setting = read(service, using: runner) else {
                return .failure("could not read the proxy setting of \(service)")
            }
            current[service] = setting
        }
        let state = remember(current: current, previous: previous, port: port)
        guard save(state, path: statePath) else { return .failure("could not record the proxy setting") }
        for args in setCommands(services: services, port: port) {
            guard runner.run("networksetup", args, timeout: 15).ok else {
                _ = off(statePath: statePath, using: runner)
                return .failure("networksetup refused to set the proxy on \(args[1]); put back")
            }
        }
        return ActionResult(ok: true, notes: ["browser proxy on (port \(port), \(services.count) services)"])
    }

    /// Put back what was recorded and switch our PAC off anywhere else.
    @discardableResult
    public static func off(statePath: String = statePath,
                           using runner: CommandRunner = SystemRunner()) -> ActionResult {
        let (state, corrupt) = load(path: statePath)
        if corrupt {
            return .failure("the saved proxy state at \(statePath) is unreadable; nothing was changed")
        }
        // A failed listing must not count as "every service vanished": the
        // record would be deleted with nothing put back.
        guard let all = DNSManager.allServices(using: runner) else {
            return .failure("networksetup listed no network services; nothing was changed")
        }
        var failed: [String] = []
        if let state {
            for args in restoreCommands(state: state, existing: all)
            where !runner.run("networksetup", args, timeout: 15).ok {
                failed.append(args[1])
            }
        }
        // No record (or a service added since): our URL must not stay on.
        for service in listServices(using: runner) ?? [] where state?.saved[service] == nil {
            if let now = read(service, using: runner), now.enabled, ourPort(url: now.url) != nil,
               !runner.run("networksetup", ["-setautoproxystate", service, "off"], timeout: 15).ok {
                failed.append(service)
            }
        }
        guard failed.isEmpty else {
            return .failure("networksetup could not restore the proxy on \(failed.joined(separator: ", "))")
        }
        unlink(statePath)
        return ActionResult(ok: true, notes: state == nil ? [] : ["browser proxy off"])
    }

    /// Read as any user: our PAC on any enabled service.
    public static func status(using runner: CommandRunner = SystemRunner()) -> Status {
        for service in listServices(using: runner) ?? [] {
            if let now = read(service, using: runner), now.enabled, let port = ourPort(url: now.url) {
                return Status(active: true, port: port)
            }
        }
        return Status(active: false)
    }
}
