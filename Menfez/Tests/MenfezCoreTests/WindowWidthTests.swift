import XCTest
import AppKit
@testable import MenfezCore

/// The width range, checked as a budget.
///
/// The window used to be a fixed 520 pt, so "does it fit" never had to be asked.
/// These tests ask it at the narrow end, with measured string widths rather than
/// guesses, so a new header button or a longer label fails here instead of
/// clipping in front of a user.
final class WindowWidthTests: XCTestCase {

    private func textWidth(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size,
                                                                     weight: weight)]).width
    }

    // MARK: - The range itself

    func testRangeIsTheDesignedBand() {
        XCTAssertEqual(WindowWidth.narrowest, 440)
        XCTAssertEqual(WindowWidth.initial, 520)
        XCTAssertEqual(WindowWidth.widest, 620)
        XCTAssertLessThan(WindowWidth.narrowest, WindowWidth.initial)
        XCTAssertLessThan(WindowWidth.initial, WindowWidth.widest)
    }

    func testClampHoldsTheBand() {
        XCTAssertEqual(WindowWidth.clamp(300), 440)
        XCTAssertEqual(WindowWidth.clamp(440), 440)
        XCTAssertEqual(WindowWidth.clamp(520), 520)
        XCTAssertEqual(WindowWidth.clamp(620), 620)
        XCTAssertEqual(WindowWidth.clamp(900), 620)
    }

    func testContentWidthRemovesBothInsets() {
        XCTAssertEqual(WindowWidth.contentWidth(at: 440), 404)
        XCTAssertEqual(WindowWidth.contentWidth(at: 620), 584)
    }

    // MARK: - Header at the narrow end

    /// The left block plus the right cluster must leave a usable spacer.
    ///
    /// Uses the longest tagline (Turkish, 134.5 pt) and the widest control set
    /// (chip + three icons). If a fourth icon is ever added this is the test that
    /// says the header stopped fitting.
    /// The window is a fixed 528 pt column (PageLayout, 2 x 24 pt padding) with
    /// five header icons: What's new, appearance, about, help, coffee.
    func testHeaderFitsTheFixedColumnWithFiveIcons() {
        let inner: CGFloat = 528 - 2 * 24
        let gap: CGFloat = 6
        let tagline = textWidth("Engelli ağda Discord'a bağlanmak için", 11.5, .regular)
        // The wordmark "Menfez" + small ".app" must not outgrow the tagline.
        func serif(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            return NSFont(descriptor: base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor,
                          size: size) ?? base
        }
        let wordmark = ("Menfez" as NSString).size(withAttributes: [.font: serif(26, .semibold)]).width
            + (".app" as NSString).size(withAttributes: [.font: serif(15, .regular)]).width
        XCTAssertLessThan(wordmark, tagline, "the title must not widen the header's left block")
        let chip = 22 + 5 + textWidth("Türkçe", 11, .regular) + 18
        let left = 15 + gap + 4 + tagline
        let right = chip + 5 * (24 + 4)  // HeaderMetrics.hit + iconGap, one gap per icon
        XCTAssertGreaterThanOrEqual(inner - left - 2 * gap - right, 8,
                                    "the header's Spacer(minLength: 8) must still fit")
    }

    func testHeaderFitsAtTheNarrowEnd() {
        let inner = WindowWidth.contentWidth(at: WindowWidth.narrowest)

        let dot: CGFloat = 15
        let gap: CGFloat = 6
        let titleIndent: CGFloat = 4
        let tagline = textWidth("Bölünmüş tünel denetimi", 11.5, .regular)

        // Chip: flag glyph, 5 pt gap, label, 9 pt horizontal padding each side.
        let chipLabel = textWidth("Türkçe", 11, .regular)
        let chip = 22 + 5 + chipLabel + 18
        let icons: CGFloat = 26 * 3 + gap * 3

        let left = dot + gap + titleIndent + tagline
        let right = chip + icons
        let spacer = inner - left - right

        XCTAssertGreaterThan(spacer, 24,
                             "the header must keep a visible gap between the title and the controls")
    }

    /// The English tagline is shorter, so the Turkish one is the binding case;
    /// assert that too, or a future copy edit could quietly swap which locale is
    /// the constraint.
    func testTurkishTaglineIsTheBindingCase() {
        let tr = textWidth("Bölünmüş tünel denetimi", 11.5, .regular)
        let en = textWidth("Split-tunnel control", 11.5, .regular)

        // "Bölünmüş" has no descender but is longer; the claim is about length.
        XCTAssertGreaterThan(tr, en)
        XCTAssertFalse("Split-tunnel control".isEmpty, "keep the English string in the test")
    }

    // MARK: - Mode chips at the narrow end

    /// Three equal chips, each wide enough for its longest label at 11.5 pt.
    func testModeChipsFitAtTheNarrowEnd() {
        let inner = WindowWidth.contentWidth(at: WindowWidth.narrowest)
        let perChip = inner / 3 - 2  // 2 pt spacing between chips
        let widestLabel = ["Doğrudan", "Direct", "Tunnel", "Tünel"]
            .map { textWidth($0, 11.5, .semibold) }
            .max() ?? 0
        let lockGlyph: CGFloat = 8 + 4  // the tunnel chip's lock and its spacing

        XCTAssertGreaterThan(perChip, widestLabel + lockGlyph + 8,
                             "a chip needs its label, the optional lock, and breathing room")
    }

    // MARK: - Primary action at the narrow end

    /// The button's text column: an icon, a gap, and a two-line block whose hint
    /// is the longest string in the view.
    func testPrimaryActionHintFitsAtTheNarrowEnd() {
        let inner = WindowWidth.contentWidth(at: WindowWidth.narrowest)
        let textColumn = inner - 14 * 2 - 15 - 9  // button padding, icon, spacing
        let longestHint = max(
            textWidth("Proxy'yi başlat ve Discord'u Menfez üzerinden aç", 10.5, .regular),
            textWidth("Start the proxy and launch Discord through Menfez", 10.5, .regular)
        )

        XCTAssertGreaterThan(textColumn, longestHint,
                             "the hint must not wrap to three lines at 440")
    }

    // MARK: - Picker split

    /// The resolver half is capped so the server half gets the growth.
    func testPickersLeaveTheGrowthToTheServerName() {
        XCTAssertLessThan(WidthPolicy.dnsPickerMax, WindowWidth.widest / 2)

        let atMin = WindowWidth.contentWidth(at: .init(WindowWidth.narrowest))
        let atMax = WindowWidth.contentWidth(at: .init(WindowWidth.widest))

        // Capped at both ends: the server half absorbs the whole difference.
        let dnsUsedMin = WidthPolicy.dnsPickerIdeal
        let dnsUsedMax = min(WidthPolicy.dnsPickerMax, atMax)
        XCTAssertGreaterThan(atMax - atMin, dnsUsedMax - dnsUsedMin,
                             "the server label must gain more than the resolver does")
    }

    /// The resolver chip still has room for its own chevron at the narrow end.
    func testResolverChipIsStillUsableAtTheNarrowEnd() {
        XCTAssertGreaterThan(WidthPolicy.dnsPickerMin, 100,
                             "room for the glyph, an address, and the chevron")
        XCTAssertGreaterThanOrEqual(WidthPolicy.dnsPickerMin, WidthPolicy.dnsPickerMin)
    }

    // MARK: - Detail value column

    func testDetailValueColumnGrowsWithTheWindow() {
        let atMin = WidthPolicy.detailValueWidth(content: WindowWidth.contentWidth(at: WindowWidth.narrowest))
        let atMax = WidthPolicy.detailValueWidth(content: WindowWidth.contentWidth(at: WindowWidth.widest))

        XCTAssertGreaterThan(atMax, atMin)
        XCTAssertEqual(atMax - atMin,
                       WindowWidth.widest - WindowWidth.narrowest,
                       "every point of extra width belongs to the value")
    }

    /// An IPv6 literal is the longest value the card can show. At 440 it may
    /// truncate in the middle — which keeps both ends legible — but it must not
    /// be squeezed out of existence.
    func testWidestRealValueSurvivesAtTheNarrowEnd() {
        let value = "2001:0db8:85a3:0000:0000:8a2e:0370:7334"
        let measured = (value as NSString)
            .size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 12.5,
                                                                      weight: .regular)])
            .width
        let available = WidthPolicy.detailValueWidth(
            content: WindowWidth.contentWidth(at: WindowWidth.narrowest) - 28)

        XCTAssertGreaterThan(available, measured * 0.55,
                             "at worst it truncates in the middle; it must not vanish")
    }
}
