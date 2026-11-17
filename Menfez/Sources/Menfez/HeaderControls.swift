// HeaderControls.swift — the small controls in the top-right corner.
//
// WHY A SEPARATE FILE
// Four controls share one geometry. Keeping them here means the numbers that
// make them line up are written once, next to the code that uses them, instead
// of being spread across a 1800-line view.
//
// THE ALIGNMENT PROBLEM THIS SOLVES
// The header's left side is a two-line block: the app name at 26 pt and the
// tagline at 11.5 pt. The controls sat in the same HStack with `.top`
// alignment, which pins their *boxes* to the top of the title, not their
// centres. A 23 pt chip whose top is level with a 31 pt line of type has its
// centre about 4.5 pt above the title's optical centre — the "looks a bit too
// high" the user reported. The arithmetic, and the tests for it, live in
// `MenfezCore.HeaderLayout`; `HeaderMetrics` only re-exports the numbers.

import SwiftUI
import MenfezCore

/// The numbers behind the header row, in one place and commented, because a
/// half-point here is a visible misalignment there.
///
/// `line` comes from `MenfezCore.HeaderLayout`, which also owns the arithmetic
/// and the tests for it. Duplicating 32 here would be a second source of truth
/// that could drift the moment the title's size changed.
enum HeaderMetrics {
    /// The shared box: the title's line box and every control's frame.
    static let line: CGFloat = HeaderLayout.line

    /// The row's centre, measured from the top of that box.
    static let centre: CGFloat = HeaderLayout.centre

    static let dot: CGFloat = 15

    static let iconPointSize: CGFloat = 14

    /// The clickable square around an icon. 24 is large enough for the pointer
    /// without making the icons look like buttons in their own right, and lets
    /// five icons fit the fixed 528 pt column (WindowWidthTests).
    static let hit: CGFloat = 24

    /// Gap inside the right-hand cluster. Tighter than `gap` so five icons fit.
    static let iconGap: CGFloat = 4

    /// Gap between the controls. Uniform on purpose: the coffee button must not
    /// read as a call to action, so it gets the same spacing as its neighbours.
    static let gap: CGFloat = 6
}

/// A header icon: one SF Symbol, one hit area, dim until hovered.
///
/// It is deliberately not a bordered style. The header's only "strong" element
/// is the language chip, which shows the current state; everything else is an
/// affordance that should stay quiet until the pointer is near it.
struct HeaderIcon: View {
    let symbol: String
    let help: String
    /// Resting colour. `Palette.secondary` for the optional/donation action, `secondary`
    /// for the documentation ones, so weight follows importance.
    var tint: Color = Palette.secondary
    /// A small accent dot in the corner: something here the user has not seen.
    var badge = false
    let action: () -> Void

    @State private var inside = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: HeaderMetrics.iconPointSize, weight: .regular))
                .foregroundStyle(inside ? Palette.text : tint)
                .frame(width: HeaderMetrics.hit, height: HeaderMetrics.hit)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(inside ? Palette.separator : .clear)
                )
                .contentShape(Rectangle())
                .overlay(alignment: .topTrailing) {
                    if badge {
                        Circle().fill(Palette.accent).frame(width: 6, height: 6).padding(4)
                    }
                }
        }
        .buttonStyle(.plain)
        .onHover { inside = $0 }
        .animation(.easeOut(duration: 0.12), value: inside)
        .help(help)
        .accessibilityLabel(help)
    }
}
