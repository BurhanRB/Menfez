// Presentation.swift — the one state machine behind every sheet in the app.
//
// WHY THIS IS IN THE CORE AND NOT IN THE VIEW
// The bug it replaces could only be seen by clicking: open a sheet, close it,
// watch it come back. A rule that can only be checked by hand is a rule that
// breaks again, so the rule lives here as a value with no SwiftUI in it and is
// covered by tests that run on every `swift test`.
//
// THE BUG, IN ONE PARAGRAPH
// The window had four independent presentation states (three `@State` booleans
// plus one `.sheet(item:)` optional) and two different ways to close a sheet.
// Most Close buttons set the flag to false. The Close buttons of the help and
// detail panels instead called `NSApp.keyWindow?.sheetParent?.endSheet(...)`,
// which ends the AppKit sheet but leaves the SwiftUI state still saying
// "presented". SwiftUI's contract is that the state drives the sheet, so the
// next body evaluation — and this window evaluates its body on a two-second
// timer — presents it again. Closing the sheet opens it: "it opens again every
// time". Removing `showServers = true` from the import flow could not fix that,
// because it is a different path to the same disagreement.
//
// THE RULES
//  1. Exactly one route is presented at a time, and `presented` changes only
//     through the calls below. It is never derived from a report, a timer or a
//     flag, so a repaint cannot change what is on screen.
//  2. Presenting what is already presented does nothing. This is the older half
//     of the same bug: `showServers = true` on an already presented sheet made
//     SwiftUI tear it down and present a fresh one.
//  3. Dismissing clears the slot exactly once. On a normal close both the Close
//     button and SwiftUI's own writeback fire; the second must be ignored, and
//     it must not be able to clear a sheet opened afterwards.
//  4. The system writeback can only ever *dismiss*. There is no path through
//     this type that sets `presented` except `present`.

import Foundation

/// One presentation, with a stamp so `.sheet(item:)` can tell a re-presentation
/// from the same sheet redrawing.
///
/// The stamp matters: `.sheet(item:)` re-creates the sheet window when the item's
/// identity changes, and keeps it when the identity is stable. Using the route
/// itself as the identity would mean closing `.detail("ip")` and reopening
/// `.detail("ip")` is invisible to SwiftUI if the nil writeback were ever missed.
/// A counter that only moves on an actual presentation cannot get that wrong.
public struct PresentedSheet<Route: Equatable>: Identifiable, Equatable {
    public let id: Int
    public let route: Route

    public init(id: Int, route: Route) {
        self.id = id
        self.route = route
    }
}

public struct SheetRouter<Route: Equatable> {

    /// What a call did, so a test can count presentations instead of inferring
    /// them from a state that is supposed to end up identical either way.
    public enum Outcome: Equatable {
        case showed(Route)
        case closed(Route)
        case ignored

        public var didChange: Bool {
            switch self {
            case .showed, .closed: return true
            case .ignored: return false
            }
        }
    }

    /// The sheet that should be on screen, or nil.
    public private(set) var presented: Route?

    /// Increments on every successful `present`. Never on a redraw.
    public private(set) var stamp = 0

    public init(presented: Route? = nil) {
        self.presented = presented
    }

    public var isPresenting: Bool { presented != nil }

    /// The value `.sheet(item:)` is bound to.
    public var item: PresentedSheet<Route>? {
        presented.map { PresentedSheet(id: stamp, route: $0) }
    }

    @discardableResult
    public mutating func present(_ route: Route) -> Outcome {
        // A sheet on macOS is modal: the window behind it cannot be clicked, so
        // a second request while one is up is always stale (a queued click, a
        // timer, an async reply). Replacing would tear a window down mid
        // animation; ignoring is what the user sees as "nothing happened", which
        // is the truth.
        guard presented == nil else { return .ignored }
        presented = route
        stamp += 1
        return .showed(route)
    }

    @discardableResult
    public mutating func dismiss(_ route: Route) -> Outcome {
        // Only the sheet that is actually up can be closed. A late close for a
        // sheet that already went away must not clear a newer one.
        guard presented == route else { return .ignored }
        presented = nil
        return .closed(route)
    }

    /// The writeback from `.sheet(item:)`.
    ///
    /// SwiftUI writes nil when it has ended the sheet itself (Escape, the
    /// window's close button, or the parent sheet being torn down because a
    /// modal `NSOpenPanel` dismissed it). That is a dismissal like any other and
    /// must clear the slot, because a slot that disagrees with the screen is
    /// exactly the bug. It can never create one.
    @discardableResult
    public mutating func syncFromSystem(_ route: Route?) -> Outcome {
        guard route == nil, let current = presented else { return .ignored }
        presented = nil
        return .closed(current)
    }
}
