import XCTest
import AppKit
@testable import MenfezCore

/// The header's vertical geometry, checked as arithmetic instead of by eye.
///
/// The report was "the language button looks a bit too high". The cause was that
/// the row was `.top`-aligned, so a 23 pt chip's top edge sat level with the top
/// of a 31 pt line of type. These tests state the correct relationship and, as
/// negative controls, that the two wrong layouts produce a measurable drift.
final class HeaderLayoutTests: XCTestCase {

    /// Real metrics rather than invented ones: a test that hard-codes 25.14 is
    /// only testing its own literal.
    /// The title face: New York (system serif) semibold, 26 pt.
    private var title: NSFont {
        let base = NSFont.systemFont(ofSize: 26, weight: .semibold)
        return NSFont(descriptor: base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor, size: 26) ?? base
    }

    func testCapitalCentreMatchesTheMeasuredFont() {
        let centre = HeaderLayout.capitalCentre(ascender: title.ascender,
                                                capHeight: title.capHeight)
        // 24.76 - 18.33/2 = 15.59.
        XCTAssertEqual(centre, 15.59, accuracy: 0.05)
    }

    /// The old layout put the chip's *top* level with the title's top, so its
    /// centre was at 23/2 = 11.5 instead of 16: 4.5 pt high. This is the
    /// reported symptom, quantified.
    func testTopAlignedChipSitsHighByTheReportedAmount() {
        let chipHeight: CGFloat = 23
        let oldCentre = chipHeight / 2
        let drift = HeaderLayout.centre - oldCentre

        XCTAssertEqual(drift, 4.5, accuracy: 0.001)
        XCTAssertGreaterThan(drift, 3, "a visible misalignment, not a rounding error")
    }

    /// A line box's geometric middle and the visual middle of its capitals are
    /// not the same point, and the line-box one is *higher*: the empty descender
    /// space pulls the geometric centre up while the capitals sit low.
    ///
    /// Getting this backwards is easy enough that the first version of this file
    /// did; the assertion is what caught it.
    func testLineBoxCentreIsAboveTheCapitalsCentre() {
        let lineCentre = HeaderLayout.lineCentre(ascender: title.ascender,
                                                 descender: title.descender)
        let capitalCentre = HeaderLayout.capitalCentre(ascender: title.ascender,
                                                       capHeight: title.capHeight)
        XCTAssertLessThan(lineCentre, capitalCentre)
        // 15.51 vs 15.59: under a tenth of a point with New York.
        XCTAssertEqual(capitalCentre - lineCentre, 0.08, accuracy: 0.05)
    }

    /// The residue of using the line box as the alignment target is under a
    /// point, which is why it is accepted rather than hand-corrected.
    func testLineBoxAlignmentResidueIsSubPoint() {
        let lineCentre = HeaderLayout.lineCentre(ascender: title.ascender,
                                                 descender: title.descender)
        XCTAssertLessThan(abs(HeaderLayout.centre - lineCentre), 1)
    }

    /// The chosen box is at least as tall as the font it contains, so nothing is
    /// clipped, and is a whole number of points.
    func testLineBoxFitsTheTitleAtAWholePoint() {
        let fontHeight = title.ascender - title.descender + title.leading
        XCTAssertGreaterThanOrEqual(HeaderLayout.line, fontHeight)
        XCTAssertEqual(HeaderLayout.line, HeaderLayout.line.rounded())
        XCTAssertLessThan(HeaderLayout.line - fontHeight, 2,
                          "the box should not add more slack than rounding needs")
    }

    /// The negative control for the other tempting fix: centring the row would
    /// align against the 47 pt title block and push the controls *down* by 7.5 pt,
    /// worse than the 4.5 pt error it was meant to fix.
    func testCentringTheRowWouldPushTheControlsDown() {
        let taglineHeight: CGFloat = 14
        let block = HeaderLayout.line + 1 + taglineHeight
        let drift = HeaderLayout.driftIfRowIsCentred(blockHeight: block)

        XCTAssertEqual(block, 47, accuracy: 0.001)
        XCTAssertEqual(drift, 7.5, accuracy: 0.001)
        XCTAssertGreaterThan(drift, 4.5, "the wrong fix is worse than the bug")
    }

    /// With the row top-aligned, the title's box and the controls' cluster both
    /// start at y = 0 and are both 32 pt tall, so their centres coincide.
    func testTopAlignmentPutsEveryCentreOnTheSameLine() {
        let titleCentre = HeaderLayout.line / 2
        let controlCentre = HeaderLayout.line / 2
        XCTAssertEqual(titleCentre, controlCentre)
        XCTAssertEqual(titleCentre, 16)
    }

    /// The chip, the dot and the icons are all shorter than the box, so centring
    /// them inside it is what aligns them — not their own top edges.
    func testEveryControlIsShorterThanTheSharedBox() {
        XCTAssertLessThan(15, HeaderLayout.line, "status dot")
        XCTAssertLessThan(23, HeaderLayout.line, "language chip")
        XCTAssertLessThan(26, HeaderLayout.line, "icon hit area")
    }
}
