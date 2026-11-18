// SingleInstance.swift — one Menfez at a time (owner feedback, 1.0.8).
//
// A second copy would start its own proxy, sync the system proxy and talk to
// the helper next to the first. The app asks this at launch, before any
// window or engine exists, and quits when an older copy is running.

import Foundation

public enum SingleInstance {

    /// A running app, as `NSRunningApplication` describes it.
    public struct Running: Equatable, Sendable {
        public var pid: Int32
        public var bundleID: String?
        public var launched: Date?
        public init(pid: Int32, bundleID: String?, launched: Date?) {
            self.pid = pid
            self.bundleID = bundleID
            self.launched = launched
        }
    }

    /// The posted name the running copy listens for to show its window.
    public static let showWindowNotification = "com.menfez.app.showWindow"

    /// The copy `me` should hand over to, or nil to keep running. Only an
    /// older copy with the same bundle id wins, so two copies started at the
    /// same moment never both quit. Same launch time: the lower pid wins.
    /// No bundle id (a `swift run` binary) never yields.
    public static func yieldTo(me: Running, others: [Running]) -> Running? {
        guard let id = me.bundleID else { return nil }
        return others
            .filter { $0.pid != me.pid && $0.bundleID == id && isOlder($0, than: me) }
            .min { isOlder($0, than: $1) }
    }

    static func isOlder(_ a: Running, than b: Running) -> Bool {
        switch (a.launched, b.launched) {
        case let (x?, y?) where x != y: return x < y
        default: return a.pid < b.pid
        }
    }
}
