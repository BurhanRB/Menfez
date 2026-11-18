// HelperVersion.swift — is the installed helper as new as the one in this app?
//
// The helper is copied out of the bundle once, at setup. A newer app with an
// older helper keeps working (unknown flags are ignored) but misses whatever
// the helper learned since, such as `teardown` or moving DNS for Whole
// internet. `menfez-route version` answers without root; a helper too old to
// know the command fails, and that counts as version 0.

import Foundation

public enum HelperVersion {

    /// Bump when the helper gains a command or behaviour the app relies on.
    /// 1 = everything up to 1.0.1; 2 = `version`, `teardown`, `--tunnel-dns`;
    /// 3 = `killswitch` (pf anchor), cleared by `teardown`;
    /// 4 = `--site-routes` (Discord + chosen sites), blocked by the kill switch.
    public static let current = 4

    public struct Reply: Codable, Sendable {
        public var version: Int
        public init(version: Int) { self.version = version }
    }

    /// The installed helper's version, 0 when it does not know the command.
    /// Run as the user: nothing about it needs root.
    public static func installed(helper: String,
                                 using runner: CommandRunner = SystemRunner()) -> Int {
        parse(runner.run(helper, ["version"], timeout: 10))
    }

    static func parse(_ result: CommandResult) -> Int {
        guard result.ok, let reply = JSON.decode(Reply.self, from: result.output) else { return 0 }
        return reply.version
    }

    public static func needsUpdate(installed: Int, bundled: Int = current) -> Bool {
        installed < bundled
    }
}
