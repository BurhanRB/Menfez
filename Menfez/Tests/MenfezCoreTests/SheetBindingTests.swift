import XCTest
@testable import MenfezCore

/// The contract between `ContentView` and `.sheet(item:)`.
///
/// `SheetRouter` is tested on its own in `PresentationTests`. This file is about
/// the half that lives in the view: the binding. The view cannot be instantiated
/// in a test (it needs a `Model`, which reads the network on init), but the
/// binding's rule is two closures, and both are asserted here the way the view
/// implements them:
///
///     get: { router.item }
///     set: { router.syncFromSystem($0?.route) }
///
/// The property that matters is asymmetrical — the setter may clear and may not
/// set — so it gets its own test rather than being folded into the router's.
final class SheetBindingTests: XCTestCase {

    private enum Route: Equatable { case help, about }

    /// A stand-in for the view's binding, using the same two closures.
    private final class Harness {
        var router = SheetRouter<Route>()

        var binding: PresentedSheet<Route>? {
            get { router.item }
            set { router.syncFromSystem(newValue?.route) }
        }

        /// What a button does.
        func open(_ route: Route) { router.present(route) }
        /// What a Close button does.
        func close(_ route: Route) { router.dismiss(route) }
    }

    /// The reported sequence, through the binding as SwiftUI drives it: open,
    /// read (repaint), Close, then SwiftUI's writeback, then more repaints.
    func testFullOpenCloseRepaintCycleThroughTheBinding() {
        let h = Harness()
        h.open(.help)
        XCTAssertNotNil(h.binding, "opening must present")

        // Forty repaints, each reading the binding.
        for _ in 0..<40 { XCTAssertNotNil(h.binding) }

        h.close(.help)
        XCTAssertNil(h.binding, "closing must dismiss immediately")

        // SwiftUI then writes nil back for the sheet it just removed.
        h.binding = nil
        XCTAssertNil(h.binding)

        // The window redraws for another minute. It must stay closed: this is the
        // exact sequence that used to reopen the panel.
        for _ in 0..<30 { XCTAssertNil(h.binding) }
    }

    /// The setter must not be able to present. SwiftUI only ever writes nil, but
    /// a future refactor might pass a value; the router refuses regardless.
    func testWritingANonNilValueCannotPresent() {
        let h = Harness()
        h.binding = PresentedSheet(id: 7, route: .about)
        XCTAssertNil(h.binding, "a write can close a sheet, never open one")
    }

    /// Two panels in a row. The second opens after the first is closed, so the
    /// stamp moves and SwiftUI treats it as a new sheet rather than the old one
    /// still being up.
    func testSequentialPanelsGetDistinctIdentities() {
        let h = Harness()
        h.open(.help)
        let first = h.binding?.id
        h.close(.help)
        h.binding = nil
        h.open(.about)
        let second = h.binding?.id

        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(h.binding?.route, .about)
    }

    /// A queued open while a panel is up is ignored, so a double-click on the
    /// help button cannot replace the panel with a fresh copy of itself.
    func testDoubleClickOnAHeaderButtonDoesNotRebuildThePanel() {
        let h = Harness()
        h.open(.about)
        let id = h.binding?.id

        h.open(.about)
        h.open(.about)

        XCTAssertEqual(h.binding?.id, id, "same panel, same identity, no rebuild")
    }
}
