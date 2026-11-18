// Onboarding.swift — whether the first-run guide shows.
//
// Once, for new users only. Someone updating from an earlier release already
// knows the app, so any trace of an earlier run counts as "seen". After it
// closes (finished or skipped) it never shows by itself again; Help reopens it.

import Foundation

public enum Onboarding {

    public static let seenKey = "onboardingSeen"

    /// Keys only an earlier run writes: the "What's new" dot, a DPI port,
    /// the last server used.
    public static let earlierRunKeys = ["whatsNewSeen", DPIEngine.portDefaultsKey, "lastProfile"]

    public static func shouldShow(_ defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: seenKey) && !earlierRunKeys.contains { defaults.object(forKey: $0) != nil }
    }

    public static func markSeen(_ defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: seenKey)
    }
}
