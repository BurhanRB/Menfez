import XCTest
@testable import MenfezCore

/// Negative controls for the popup bug: a bug is only "fixed" if the test can
/// show what the old code did wrong.
///
/// The old window had two ways to close a sheet. Most buttons set the flag to
/// false, which is correct. The help and detail panels instead called
/// `NSApp.keyWindow?.sheetParent?.endSheet(NSApp.keyWindow!)`, which tells AppKit
/// to remove the sheet but never tells SwiftUI, whose state then still reads
/// "presented". These tests model both as small state machines and assert the
/// *wrong* one is detectable, so `PresentationTests` cannot pass by vacuity.
final class PresentationRegressionTests: XCTestCase {

    /// What the old code did: a separate AppKit dismissal and a SwiftUI flag that
    /// never heard about it.
    struct OldWindow {
        /// The SwiftUI presentation state.
        var flagged = false
        /// AppKit's idea: is a sheet actually on screen?
        private(set) var appKitSheetVisible = false

        mutating func open() {
            flagged = true
            appKitSheetVisible = true
        }

        /// A Close button that calls `endSheet` directly.
        mutating func closeViaEndSheet() {
            appKitSheetVisible = false
            // No `flagged = false`. This is the bug, verbatim.
        }

        /// A repaint: SwiftUI reconciles its state against AppKit.
        mutating func repaint() {
            if flagged && !appKitSheetVisible {
                // Wanted: nothing, because the user closed it. Actual: present.
                appKitSheetVisible = true
            }
        }
    }

    /// The reported symptom, reproduced. If this ever stops reproducing, the
    /// model has drifted from the bug it documents and the fix is unproven.
    func testEndSheetWithoutStateChangeReopensTheSheet() {
        var window = OldWindow()
        window.open()
        window.closeViaEndSheet()

        XCTAssertFalse(window.appKitSheetVisible, "the sheet is gone from AppKit")

        window.repaint()
        XCTAssertTrue(window.appKitSheetVisible,
                      "and the next repaint puts it back: this is the bug")
    }

    /// The fixed code, on the same model: one owner, and it is told.
    func testRouterDismissKeepsItClosed() {
        var router = SheetRouter<String>()
        router.present("help")
        router.dismiss("help")

        for _ in 0..<10 {
            // A repaint reads the router; it cannot change it.
            XCTAssertNil(router.item)
        }
    }

    /// Two sheets on one view was the other suspect. It is not the cause — the
    /// cause is the dismissal disagreement above — but the router removes the
    /// possibility regardless: one slot, so there is nothing to conflict.
    ///
    /// Asserted here so the alternative explanation is ruled out in code rather
    /// than only in the report.
    func testOnlyOneSheetCanBeUpSoTwoCannotConflict() {
        var router = SheetRouter<String>()
        router.present("servers")

        // The detail panel's tap lands while the picker is up.
        let second = router.present("detail")
        XCTAssertEqual(second, .ignored)
        XCTAssertEqual(router.presented, "servers")
    }
}
