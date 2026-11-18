// HotKeyCombo.swift — the global shortcut as data: what was pressed, how it
// reads ("⌃⌥M"), where it is saved, and what it switches to.
//
// Registration is Carbon's `RegisterEventHotKey` in the app (HotKey.swift),
// which needs no Accessibility or Input Monitoring permission. This file
// stays pure so the rules are tested.

import Foundation

public struct HotKeyCombo: Codable, Equatable, Sendable {
    /// Virtual key code (kVK_*).
    public var keyCode: UInt32
    /// Carbon modifier mask (cmdKey, shiftKey, optionKey, controlKey).
    public var modifiers: UInt32
    /// The key's own label as typed ("M"), for the display.
    public var key: String

    // Carbon's mask values (Events.h), written out so the core needs no Carbon.
    public static let cmd: UInt32 = 0x0100
    public static let shift: UInt32 = 0x0200
    public static let option: UInt32 = 0x0800
    public static let control: UInt32 = 0x1000

    /// Nil unless at least one of ⌘ ⌥ ⌃ is held: a bare letter or ⇧+letter
    /// would fire while the user types anywhere.
    public init?(keyCode: UInt32, modifiers: UInt32, key: String) {
        guard modifiers & (Self.cmd | Self.option | Self.control) != 0 else { return nil }
        self.keyCode = keyCode
        self.modifiers = modifiers & (Self.cmd | Self.shift | Self.option | Self.control)
        self.key = Self.named[keyCode] ?? key.uppercased()
        guard !self.key.isEmpty else { return nil }
    }

    /// From an AppKit `NSEvent.modifierFlags.rawValue`.
    public static func carbonModifiers(cocoa flags: UInt) -> UInt32 {
        var mask: UInt32 = 0
        if flags & (1 << 17) != 0 { mask |= shift }
        if flags & (1 << 18) != 0 { mask |= control }
        if flags & (1 << 19) != 0 { mask |= option }
        if flags & (1 << 20) != 0 { mask |= cmd }
        return mask
    }

    /// Keys whose typed character is invisible or misleading.
    static let named: [UInt32: String] = [
        49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    /// "⌃⌥⇧⌘M", in the order macOS menus use.
    public var display: String {
        var text = ""
        if modifiers & Self.control != 0 { text += "⌃" }
        if modifiers & Self.option != 0 { text += "⌥" }
        if modifiers & Self.shift != 0 { text += "⇧" }
        if modifiers & Self.cmd != 0 { text += "⌘" }
        return text + key
    }

    // MARK: - Saved

    public static let defaultsKey = "hotKey.combo"
    public static let lastModeKey = "hotKey.lastMode"

    public static func load(_ defaults: UserDefaults = .standard) -> HotKeyCombo? {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(HotKeyCombo.self, from: $0) }
    }

    public static func save(_ combo: HotKeyCombo?, _ defaults: UserDefaults = .standard) {
        if let combo, let data = try? JSONEncoder().encode(combo) {
            defaults.set(data, forKey: defaultsKey)
        } else {
            defaults.removeObject(forKey: defaultsKey)
        }
    }

    // MARK: - Action

    /// "Toggle last mode": anything on goes to Direct; Direct goes back to
    /// the last mode that was on, DPI when there is none yet.
    public static func toggleTarget(current: RunMode, last: RunMode?) -> RunMode {
        guard current == .direct else { return .direct }
        guard let last, last != .direct else { return .dpi }
        return last
    }
}
