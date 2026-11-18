// DiscordPresence.swift — "is Discord running?", for the app target only.
//
// WHY THIS LIVES IN THE APP AND NOT IN MenfezCore
// `NSWorkspace.runningApplications` is the only way to answer the question, and
// it is AppKit. MenfezCore is linked by `menfez-route`, the root helper, which
// is a command-line tool; dragging a GUI framework into it for one boolean would
// be a poor trade. So the one AppKit call lives here and is passed into
// `DPIMode` as a closure, which also makes it replaceable in a test.

import AppKit
import MenfezCore

enum DiscordPresence {

    /// True when the shipping Discord client is running.
    ///
    /// Matched by bundle id first, then by display name, because a copy that a
    /// user dragged into /Applications from a DM has the same name and the same
    /// bundle id but may not be registered the same way. `.regular` activation
    /// policy filters out helpers and login items that share the name.
    static var isRunning: Bool {
        let workspace = NSWorkspace.shared
        if workspace.runningApplications.contains(where: {
            $0.bundleIdentifier == DiscordLauncher.bundleID
        }) {
            return true
        }
        return workspace.runningApplications.contains {
            $0.localizedName == DiscordLauncher.applicationName
                && $0.activationPolicy == .regular
        }
    }

    /// The running Discord client, if any (same matching as `isRunning`).
    static var app: NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications
        return apps.first { $0.bundleIdentifier == DiscordLauncher.bundleID }
            ?? apps.first { $0.localizedName == DiscordLauncher.applicationName && $0.activationPolicy == .regular }
    }

    /// Discord's live state for the DPI card. Reads the process arguments
    /// with sysctl (no spawn), so it can run on the 2 s tick.
    static func state(port: Int?) -> DiscordLauncher.State {
        guard let app else { return .closed }
        return DiscordLauncher.state(running: true, arguments: arguments(pid: app.processIdentifier), port: port)
    }

    /// argv of a process this user owns, from KERN_PROCARGS2, or nil.
    static func arguments(pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var at = MemoryLayout<Int32>.size
        while at < size, buffer[at] != 0 { at += 1 }      // executable path
        while at < size, buffer[at] == 0 { at += 1 }      // padding
        var out: [String] = []
        while out.count < Int(argc), at < size {
            let start = at
            while at < size, buffer[at] != 0 { at += 1 }
            out.append(String(decoding: buffer[start..<at], as: UTF8.self))
            at += 1
        }
        return out
    }
}
