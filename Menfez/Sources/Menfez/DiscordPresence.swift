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
}
