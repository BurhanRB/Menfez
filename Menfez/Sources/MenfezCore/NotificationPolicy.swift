// NotificationPolicy.swift — which events become a macOS notification, and when.
//
// The app posts; this decides. Pure, so the rules a user feels ("it does not
// nag me", "the switch in Settings works", "nothing while I am looking at the
// window") are tested without a notification centre.

import Foundation

public enum NotificationEvent: String, CaseIterable, Sendable {
    /// Tunnel mode is on and the tunnel stopped carrying traffic.
    case tunnelDropped
    /// The dropped tunnel came back on its own.
    case tunnelRestored
    /// A tunnel was closed because its server file was removed.
    case serverRemoved
    /// DPI is selected but its local listener died without the user asking.
    case dpiStopped
    /// The installed tunnel helper is older than the bundled one.
    case helperUpdate

    /// The Settings switch this event follows. Dropped and restored are one
    /// story, so they share one switch.
    public var setting: NotificationEvent { self == .tunnelRestored ? .tunnelDropped : self }

    /// Switches shown in Settings, in display order.
    public static let settings: [NotificationEvent] = [.tunnelDropped, .serverRemoved, .dpiStopped, .helperUpdate]

    public var defaultsKey: String { "notify." + setting.rawValue }

    /// On unless the user turned it off: every event here is rare and needs
    /// the user to act or know (AS-25).
    public func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? true
    }
}

public struct NotificationPolicy {

    /// The same event is not repeated within this window.
    public static let window: TimeInterval = 5 * 60
    /// The helper update is a nag by nature; once a day is enough.
    public static let helperWindow: TimeInterval = 24 * 60 * 60

    private var lastSent: [NotificationEvent: Date] = [:]
    /// A "restored" only follows a "dropped" the user actually saw.
    private var dropAnnounced = false

    public init() {}

    /// True when `event` should be posted now; records it if so.
    ///
    /// `appActive`: the user is looking at Menfez, which already shows the
    /// state, so a banner would only repeat it.
    public mutating func shouldSend(_ event: NotificationEvent, at now: Date = Date(),
                                    appActive: Bool, enabled: Bool) -> Bool {
        if event == .tunnelRestored {
            guard dropAnnounced else { return false }
            dropAnnounced = false
        }
        guard enabled, !appActive else { return false }
        let gap = event == .helperUpdate ? Self.helperWindow : Self.window
        if let last = lastSent[event], now.timeIntervalSince(last) < gap { return false }
        lastSent[event] = now
        if event == .tunnelDropped { dropAnnounced = true }
        return true
    }

    /// The tunnel event, if any, between two ticks.
    ///
    /// Restored needs a measured healthy tunnel in Tunnel mode: `isLost` also
    /// turns false when the user leaves Tunnel mode or a switch is settling,
    /// and neither is the tunnel coming back.
    public static func tunnelEvent(wasLost: Bool, isLost: Bool,
                                   inTunnel: Bool, healthy: Bool) -> NotificationEvent? {
        if !wasLost && isLost { return .tunnelDropped }
        if wasLost && !isLost && inTunnel && healthy { return .tunnelRestored }
        return nil
    }

    /// DPI was running, is not now, and the user still has DPI selected: the
    /// user's own "stop" changes the selection first, so it never lands here.
    public static func dpiStoppedUnexpectedly(wasRunning: Bool, isRunning: Bool,
                                              dpiSelected: Bool) -> Bool {
        wasRunning && !isRunning && dpiSelected
    }
}
