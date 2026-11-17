// MenuBarModes.swift — what the menu-bar extra shows and calls per mode.
//
// The menu and the main window's mode bar both read this list and both call
// `Model.setMode(path)`, so the menu cannot grow its own switching logic.

public enum MenuBarModes {
    /// The order both the window's mode bar and the menu list the modes in.
    public static let order: [RunMode] = [.direct, .dpi, .tunnel]

    /// The argument `Model.setMode` takes for this mode.
    public static func path(_ mode: RunMode) -> String { mode.rawValue }

    /// The localisation key of the mode's name.
    public static func labelKey(_ mode: RunMode) -> String { "mode_" + mode.rawValue }

    /// The menu-bar figure for each mode.
    public static func icon(_ mode: RunMode) -> LogoMark.Variant {
        switch mode {
        case .direct: return .idle
        case .dpi: return .flow
        case .tunnel: return .flowBadge
        }
    }
}
