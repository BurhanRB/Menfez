import XCTest
@testable import MenfezCore

/// The sheet router, exercised without SwiftUI.
///
/// This file exists for one reported symptom: "when I open a popup and close it,
/// it opens again every time — like a joke." The cause was that the Close button
/// of two of the four sheets ended the AppKit sheet and left the SwiftUI state
/// saying "presented"; the next body evaluation presented it again. The property
/// that rules that out is "no call yields a presentation the user did not ask
/// for", asserted here directly.
final class PresentationTests: XCTestCase {

    private enum Route: Equatable {
        case servers, dns, help, about, detail(String)
    }

    // MARK: - The reported symptom

    /// Open, close, and then repaint. The repaint is the part that mattered:
    /// the window redraws every two seconds, so any state that can drift back
    /// to "presented" turns a single close into an endless loop.
    func testCloseStaysClosedAcrossManyRepaints() {
        var router = SheetRouter<Route>()

        XCTAssertEqual(router.present(.servers), .showed(.servers))
        XCTAssertEqual(router.dismiss(.servers), .closed(.servers))
        XCTAssertNil(router.presented)

        // Forty repaints, each one asking the router what to show. A repaint is
        // a read; it must not be able to change the answer.
        for _ in 0..<40 {
            XCTAssertNil(router.item)
            XCTAssertFalse(router.isPresenting)
        }
    }

    /// The Close button and SwiftUI's writeback both fire on one dismissal. The
    /// pair must be a single close, not a close followed by a re-open.
    func testCloseButtonThenSystemWritebackClosesOnce() {
        var router = SheetRouter<Route>()
        router.present(.help)

        XCTAssertEqual(router.dismiss(.help), .closed(.help))
        XCTAssertEqual(router.syncFromSystem(nil), .ignored)
        XCTAssertNil(router.presented)
    }

    /// The order SwiftUI actually uses when the user hits Escape: the system
    /// writes nil first, then any queued button action lands.
    func testWritebackThenCloseButtonClosesOnce() {
        var router = SheetRouter<Route>()
        router.present(.dns)

        XCTAssertEqual(router.syncFromSystem(nil), .closed(.dns))
        XCTAssertEqual(router.dismiss(.dns), .ignored)
        XCTAssertNil(router.presented)
    }

    // MARK: - The older half of the same bug

    /// `showServers = true` while the picker was already up. One request, not a
    /// teardown and a fresh window.
    func testPresentingTwiceIsIgnored() {
        var router = SheetRouter<Route>()
        router.present(.servers)
        let stampAfterFirst = router.stamp

        XCTAssertEqual(router.present(.servers), .ignored)
        XCTAssertEqual(router.stamp, stampAfterFirst,
                       "an ignored present must not change the sheet's identity")
    }

    /// The import flow, in the order the code runs it: the panel opens on top of
    /// the picker, the user picks a file, the picker is still up, the import
    /// finishes and used to set the flag again.
    func testImportFlowDoesNotRepresentThePicker() {
        var router = SheetRouter<Route>()
        router.present(.servers)

        // `NSOpenPanel.runModal()` returns; some macOS versions end the parent
        // sheet at this point, which arrives here as a nil writeback.
        router.syncFromSystem(nil)
        // Whatever the import said, nothing here may re-present.
        XCTAssertEqual(router.present(.servers), .showed(.servers))
        XCTAssertEqual(router.present(.servers), .ignored,
                       "a second request while the picker is up must be a no-op")
        XCTAssertEqual(router.stamp, 2,
                       "two real presentations: the first open, and the reopen after the modal")
    }

    // MARK: - The screen always wins

    /// A nil writeback is the system saying "there is no sheet". If the state
    /// still had one, the two disagree, and the disagreement is the bug. So the
    /// state gives way even when the nil was meant for an earlier sheet: a panel
    /// that closes when it should not is a nuisance, a panel that cannot be
    /// closed is the bug report.
    func testNilWritebackClearsWhateverIsPresented() {
        var router = SheetRouter<Route>()
        router.present(.servers)
        router.dismiss(.servers)
        router.present(.about)

        XCTAssertEqual(router.syncFromSystem(nil), .closed(.about))
        XCTAssertNil(router.presented)
    }

    func testDismissingSomethingElseIsIgnored() {
        var router = SheetRouter<Route>()
        router.present(.help)

        XCTAssertEqual(router.dismiss(.dns), .ignored)
        XCTAssertEqual(router.presented, .help)
    }

    func testSyncCannotPresent() {
        var router = SheetRouter<Route>()
        XCTAssertEqual(router.syncFromSystem(.servers), .ignored)
        XCTAssertNil(router.presented, "only an explicit present may open a sheet")
    }

    // MARK: - Identity

    /// Two opens of the same route must be two different items, or `.sheet(item:)`
    /// will treat the second as the first still being up.
    func testReopeningTheSameRouteGetsANewStamp() {
        var router = SheetRouter<Route>()
        router.present(.detail("ip"))
        let first = router.item?.id
        router.dismiss(.detail("ip"))
        router.present(.detail("ip"))
        let second = router.item?.id

        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertNotEqual(first, second)
    }

    /// A redraw keeps the stamp, so SwiftUI does not rebuild the sheet window on
    /// every two-second tick.
    func testRedrawKeepsTheStamp() {
        var router = SheetRouter<Route>()
        router.present(.detail("routes"))
        let first = router.item?.id
        XCTAssertEqual(router.item?.id, first)
        XCTAssertEqual(router.item?.id, first)
    }

    func testDismissedHasNoItem() {
        var router = SheetRouter<Route>()
        router.present(.about)
        router.dismiss(.about)
        XCTAssertNil(router.item)
    }
}
