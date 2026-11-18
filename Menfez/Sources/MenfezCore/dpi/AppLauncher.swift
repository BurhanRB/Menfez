// AppLauncher.swift — other apps through the DPI proxy (1.0.8, feature 7).
//
// Three ways, per app, from a fixed list (no user-added apps, ROADMAP AS-18):
//   .flag    Electron/Chromium apps read `--proxy-server` at launch, like
//            Discord (`DiscordLauncher`). Menfez opens them with the flag.
//   .manual  The app has its own HTTP proxy setting; Menfez shows the
//            address and the user types it in. Menfez never edits it.
//   .tunnel  The app ignores proxies or speaks UDP; only Tunnel mode helps.
// Discord keeps its own launcher and is not in this list.
//
// The list is a hypothesis until measured (docs/DPI-ENGINE.md §6).

import Foundation

public enum AppLauncher {

    public enum Route: String, Sendable { case flag, manual, tunnel }

    public struct App: Equatable, Sendable, Identifiable {
        public let name: String
        public let bundleID: String
        public let route: Route
        public var id: String { bundleID }
    }

    public static let catalog: [App] = [
        App(name: "Slack", bundleID: "com.tinyspeck.slackmacgap", route: .flag),
        App(name: "Signal", bundleID: "org.whispersystems.signal-desktop", route: .flag),
        App(name: "Element", bundleID: "im.riot.app", route: .flag),
        App(name: "Telegram Desktop", bundleID: "org.telegram.desktop", route: .manual),
        App(name: "Spotify", bundleID: "com.spotify.client", route: .manual),
        App(name: "Telegram", bundleID: "ru.keepcoder.Telegram", route: .tunnel),
        App(name: "Roblox", bundleID: "com.roblox.RobloxPlayer", route: .tunnel),
    ]

    public static func app(_ bundleID: String) -> App? {
        catalog.first { $0.bundleID == bundleID }
    }

    /// What the user types into an app's own proxy setting.
    public static func address(port: Int) -> String { "127.0.0.1:\(port)" }

    /// `open` arguments for a `.flag` app, or nil for anything else. The
    /// bundle id comes only from `catalog`, never from the user; `open` takes
    /// an argument list, so nothing reaches a shell.
    public static func arguments(for app: App, port: Int?) -> [String]? {
        guard app.route == .flag, catalog.contains(app),
              let port, (1...65535).contains(port) else { return nil }
        return ["-b", app.bundleID, "--args", "--proxy-server=http://127.0.0.1:\(port)"]
    }

    /// Running catalog apps still pointed at our loopback proxy, as PIDs, from
    /// `ps -axo pid=,args=`. After leaving DPI mode these dial a closed port
    /// until restarted (same reason as `DiscordLauncher.restartCandidate`).
    /// Only main executables match: helper processes ("… Helper …") and
    /// Discord (its own offer) are skipped.
    public static func flaggedPIDs(psOutput: String, port: Int?) -> [Int32] {
        let flag = port.map { "--proxy-server=http://127.0.0.1:\($0)" } ?? "--proxy-server=http://127.0.0.1:"
        var out: [Int32] = []
        for line in psOutput.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let space = text.firstIndex(of: " "), let pid = Int32(text[..<space]) else { continue }
            let args = String(text[space...])
            guard args.contains(flag), args.contains(".app/Contents/MacOS/"),
                  !args.contains("Helper"), !args.contains("Discord.app/") else { continue }
            if port != nil, let range = args.range(of: flag) {
                // `:443` must not match a flag for `:4430`.
                let rest = args[range.upperBound...]
                if let next = rest.first, next.isNumber { continue }
            }
            out.append(pid)
        }
        return out
    }
}
