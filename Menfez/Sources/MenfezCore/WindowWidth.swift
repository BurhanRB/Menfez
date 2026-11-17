// WindowWidth.swift — how the window behaves between its two bounds.
//
// WHY THIS IS A VALUE AND NOT A MAGIC NUMBER
// The window used to be `.frame(width: 520)`, so every layout inside it was
// tuned for exactly 520 and nothing could be checked. Widening it to a range
// means the narrow end is a budget: at 440 the header, the mode chips and the
// primary button all have to fit without clipping. Those three budgets are
// expressed here, so `WindowWidthTests` can fail when a new label or a fourth
// header button breaks the narrow case — instead of a user finding out.

import Foundation

public enum WindowWidth {

    /// Narrowest size that fits the widest header the app can produce.
    ///
    /// The measured header at this width: a 15 pt dot, the 134.5 pt Turkish
    /// tagline, and the right-hand cluster (an ~80 pt language chip plus three
    /// 26 pt icons with 6 pt gaps) leave 68 pt of spacer. Below 440 the tagline
    /// starts truncating against the chip.
    public static let narrowest: CGFloat = 440

    /// The size the window opens at.
    ///
    /// Unchanged from the fixed layout on purpose: an update must not move the
    /// window. It is also the middle of the range, so both directions of
    /// resize are useful.
    public static let initial: CGFloat = 520

    /// Widest size the content is designed for.
    ///
    /// Past this the detail card's value column has nothing left to grow into —
    /// the longest row is an IPv6 literal — and a 700 pt window would just be a
    /// 620 pt panel with 80 pt of empty background.
    public static let widest: CGFloat = 620

    /// The page margin inside the window, on every side.
    public static let inset: CGFloat = 18

    /// Content width available at a given window width.
    public static func contentWidth(at width: CGFloat) -> CGFloat {
        width - inset * 2
    }

    /// The window narrowed or widened, clamped to the range.
    ///
    /// Exists so a resize cannot land outside the designed band even if the
    /// platform asks for it; the window controller and a test use the same rule.
    ///
    /// The bounds are named `narrowest`/`widest` rather than `min`/`max` because
    /// inside this type those names resolve to the instance members and shadow
    /// Swift's global functions — the first version of this file did not compile.
    public static func clamp(_ width: CGFloat) -> CGFloat {
        Swift.min(Swift.max(width, narrowest), widest)
    }
}

/// Width policy for the pieces inside the window.
///
/// These are proportions rather than fixed points so the split stays sensible at
/// both ends of the range: the pickers and the detail card must use the extra
/// width, which is the difference between a responsive window and a wider one
/// with the same 520 pt content in it.
public enum WidthPolicy {

    /// The resolver half of the pickers row.
    ///
    /// Capped because the longest value it ever shows is a resolver address; the
    /// server half is the one with a provider-chosen name and gets the growth.
    public static let dnsPickerMin: CGFloat = 120
    public static let dnsPickerIdeal: CGFloat = 156
    public static let dnsPickerMax: CGFloat = 156

    /// Detail rows: label column width, and the minimum the value gets.
    public static let detailLabel: CGFloat = 96

    /// How wide the value column is at a given content width.
    ///
    /// `content - padding - label - row spacing`, floored so a long address
    /// truncates in the middle (which keeps both ends readable) instead of
    /// squeezing the label.
    public static func detailValueWidth(content: CGFloat) -> CGFloat {
        max(0, content - detailLabel - 12)
    }
}
