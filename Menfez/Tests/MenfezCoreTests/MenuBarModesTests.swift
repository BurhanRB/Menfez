import XCTest
@testable import MenfezCore

final class MenuBarModesTests: XCTestCase {

    func testEveryModeListedOnceInWindowOrder() {
        XCTAssertEqual(MenuBarModes.order, [.direct, .dpi, .tunnel])
        XCTAssertEqual(Set(MenuBarModes.order), Set(RunMode.allCases))
    }

    /// `Model.setMode` switches on "direct", "dpi" and "tunnel"; the menu must
    /// pass exactly those, and each must round-trip to its mode.
    func testPathsAreWhatSetModeAccepts() {
        XCTAssertEqual(MenuBarModes.order.map(MenuBarModes.path), ["direct", "dpi", "tunnel"])
        for mode in RunMode.allCases {
            XCTAssertEqual(RunMode(rawValue: MenuBarModes.path(mode)), mode)
        }
    }

    func testLabelKeysMatchTheWindow() {
        XCTAssertEqual(MenuBarModes.order.map(MenuBarModes.labelKey),
                       ["mode_direct", "mode_dpi", "mode_tunnel"])
    }

    /// The template icon has no colour, so each mode needs its own figure.
    func testEachModeHasItsOwnIcon() {
        XCTAssertEqual(MenuBarModes.icon(.direct), .idle)
        XCTAssertEqual(MenuBarModes.icon(.dpi), .flow)
        XCTAssertEqual(MenuBarModes.icon(.tunnel), .flowBadge)
    }

    func testIconsRender() {
        for v in [LogoMark.Variant.idle, .flow, .flowBadge] {
            let img = LogoMark.template(v)
            XCTAssertEqual(img?.width, 44)
        }
        XCTAssertEqual(LogoMark.appIcon(size: 64)?.width, 64)
    }

    /// The figures differ where the modes do: the doorway is solid only for
    /// Direct, and only Tunnel has the dot above the arch.
    func testFiguresShowTheMode() {
        func alpha(_ v: LogoMark.Variant, _ x: Int, _ y: Int) -> UInt8 {
            let img = LogoMark.template(v, points: 22, scale: 1)!
            var px = [UInt8](repeating: 0, count: 22 * 22 * 4)
            let ctx = CGContext(data: &px, width: 22, height: 22, bitsPerComponent: 8, bytesPerRow: 88,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: 22, height: 22))
            return px[(y * 22 + x) * 4 + 3]   // row 0 is the top
        }
        let door = (10, 14), dot = (10, 2)
        XCTAssertEqual(alpha(.idle, door.0, door.1), 255)
        XCTAssertEqual(alpha(.flow, door.0, door.1), 0)
        XCTAssertEqual(alpha(.flow, dot.0, dot.1), 0)
        XCTAssertEqual(alpha(.flowBadge, dot.0, dot.1), 255)
    }
}
