// HeaderLayout.swift — the vertical arithmetic of the header row.
//
// WHY THIS IS NOT JUST A `.frame(height:)` IN THE VIEW
// "The language button looks a bit too high" is a geometry claim, and a geometry
// claim can be checked with numbers instead of by eye. What has to hold:
//
//   1. Every control is centred in the same 32 pt box, so their centres coincide
//      instead of their top edges.
//   2. That box is the title's own line box, so the controls align with the type
//      and not with the two-line block the type sits in.
//   3. The row stays top-aligned, because the block is taller than the box;
//      centring the row against the block would push the controls down by half
//      the difference.
//
// (2) has a residue worth naming. SwiftUI centres a `Text`'s *line box*, whose
// middle is (ascender + |descender|) / 2 = 15.51 pt for the 26 pt New York
// semibold title, while the visual middle of the capitals is
// ascender - capHeight / 2 = 15.59. The capitals land 0.08 pt off the
// controls' centre (0.67 pt with the earlier SF bold). That is under
// a point and well under the 4.5 pt error it replaces, so it is accepted rather
// than corrected with a manual offset: a hand-tuned offset would be wrong the
// moment the title's size or the system font changes, and this one is derived.

import Foundation

public enum HeaderLayout {

    /// The shared box: the tallest control and the title's line box.
    ///
    /// The 26 pt New York semibold title is ascender 24.76 / descender -6.27,
    /// so its line height is 31.03. Rounding up to a whole point keeps AppKit from
    /// re-hinting glyphs on a fractional boundary, which reads as slightly fuzzy
    /// text at 1x.
    public static let line: CGFloat = 32

    /// The row's centre line, measured from the top of the box.
    ///
    /// Half of `line`. Every control is centred in the box, so this is where all
    /// of their centres land.
    public static var centre: CGFloat { line / 2 }

    /// Visual middle of a capital letterform, measured from the top of its line
    /// box.
    ///
    /// A capital occupies the baseline up to the cap height and nothing else —
    /// the descender below the baseline is empty for a word without a g, p or y.
    /// So the visual middle is `ascender - capHeight / 2`, not half the line
    /// height. Metrics are passed in so a test can assert the arithmetic without
    /// a running AppKit and a second face can be checked with the same formula.
    public static func capitalCentre(ascender: CGFloat, capHeight: CGFloat) -> CGFloat {
        ascender - capHeight / 2
    }

    /// Middle of a line box, which is what SwiftUI actually centres.
    ///
    /// Exposed next to `capitalCentre` so the difference between "the text is
    /// centred" and "the letters look centred" is visible in one place.
    public static func lineCentre(ascender: CGFloat, descender: CGFloat) -> CGFloat {
        (ascender - descender) / 2
    }

    /// Where the controls' centre would land if the whole row were centred.
    ///
    /// Kept as a named function because it is the tempting fix and it is worse
    /// than the bug: a centred `HStack` aligns the middles of its children's
    /// frames, so the 32 pt boxes centre against the 47 pt title block.
    public static func centreIfRowIsCentred(blockHeight: CGFloat) -> CGFloat {
        blockHeight / 2
    }

    /// How far that wrong answer is from the right one. Non-zero is the bug.
    public static func driftIfRowIsCentred(blockHeight: CGFloat,
                                           line: CGFloat = line) -> CGFloat {
        centreIfRowIsCentred(blockHeight: blockHeight) - line / 2
    }
}
