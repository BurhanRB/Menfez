// DiscordUpdateRoutes.swift — what "Discord updates through the tunnel" routes.
//
// Discord's updater (`updater.node`) ignores `--proxy-server`, resolves with
// system DNS and speaks TLS 1.2, which the measured ISP cuts even through the
// DPI proxy. So in DPI mode, when a WireGuard profile exists, the tunnel comes
// up in `updates` mode carrying only these hosts' IPv4 /32s plus the system's
// public resolvers; everything else stays on the proxy.
//
// The names come from Discord 0.0.422's app.asar: NEW_UPDATE_ENDPOINT
// (https://updates.discord.com/) and API_ENDPOINT (https://discord.com/api,
// the legacy update path), plus dl.discordapp.net for downloads. Behind
// Cloudflare, updates.discord.com and discord.com answer with the same
// addresses, so Discord's API calls through the proxy also take the tunnel;
// the gateway, CDN and voice do not.

import Foundation

public struct UpdateRoutes: Equatable, Sendable {
    /// IPv4 addresses for `--host-routes`.
    public var hosts: [String]
    /// Public resolver addresses for `--dns-routes`.
    public var resolvers: [String]

    public init(hosts: [String], resolvers: [String]) {
        self.hosts = hosts
        self.resolvers = resolvers
    }
}

public enum DiscordUpdateRoutes {
    public static let hostnames = ["updates.discord.com", "dl.discordapp.net", "discord.com"]

    /// UserDefaults key for the setting; on when unset.
    public static let defaultsKey = "discordUpdatesThroughTunnel"

    public static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? true
    }

    /// Whether the updates tunnel carries Discord's update check, so the
    /// settings.json fail-open (and macOS's "access blocked" notice) is not
    /// needed. `lastResult` is the switch's own answer when it just ran;
    /// otherwise a hybrid tunnel already up, or one the switch will bring up
    /// (setting on, a server, the helper), counts.
    public static func tunnelCoversUpdates(lastResult: Bool?, hybridUp: Bool,
                                           enabled: Bool, hasProfile: Bool,
                                           hasHelper: Bool) -> Bool {
        if let lastResult { return lastResult }
        return hybridUp || (enabled && hasProfile && hasHelper)
    }

    /// The answers flattened to public IPv4 only, without repeats, capped at
    /// what the helper accepts. A private or odd answer is dropped here; the
    /// helper would refuse the whole list for it.
    public static func addresses(_ answers: [[String]]) -> [String] {
        var out: [String] = []
        for ip in answers.joined() where !out.contains(ip) {
            if let quad = ConnectRequest.dottedQuad(ip), !ConnectRequest.isPrivate(v4: quad) {
                out.append(ip)
            }
        }
        return Array(out.prefix(RouteManager.maxHostRoutes))
    }

    /// The routes to send, or nil when there is nothing to route (every lookup
    /// failed). Blocking: run it off the main thread.
    public static func plan(resolver: HostResolver = DoHResolver.shared,
                            systemResolvers: [String],
                            timeout: TimeInterval = 8) -> UpdateRoutes? {
        final class Answers: @unchecked Sendable {
            let lock = NSLock()
            var list: [[String]] = []
        }
        let answers = Answers()
        let group = DispatchGroup()
        for name in hostnames {
            group.enter()
            resolver.resolve(name) { found in
                answers.lock.lock(); answers.list.append(found ?? []); answers.lock.unlock()
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + timeout)
        answers.lock.lock(); let snapshot = answers.list; answers.lock.unlock()
        let hosts = addresses(snapshot)
        guard !hosts.isEmpty else { return nil }
        return UpdateRoutes(hosts: hosts, resolvers: RouteManager.publicResolvers(systemResolvers))
    }
}
