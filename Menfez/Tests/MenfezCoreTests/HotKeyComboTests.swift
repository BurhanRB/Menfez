import XCTest
@testable import MenfezCore

final class HotKeyComboTests: XCTestCase {

    func testNeedsCommandOptionOrControl() {
        XCTAssertNil(HotKeyCombo(keyCode: 46, modifiers: 0, key: "m"))
        XCTAssertNil(HotKeyCombo(keyCode: 46, modifiers: HotKeyCombo.shift, key: "m"), "⇧M is just typing")
        XCTAssertNotNil(HotKeyCombo(keyCode: 46, modifiers: HotKeyCombo.control, key: "m"))
    }

    func testDisplayUsesMenuOrderAndNamedKeys() throws {
        let all = HotKeyCombo.cmd | HotKeyCombo.shift | HotKeyCombo.option | HotKeyCombo.control
        XCTAssertEqual(try XCTUnwrap(HotKeyCombo(keyCode: 46, modifiers: all, key: "m")).display, "⌃⌥⇧⌘M")
        XCTAssertEqual(try XCTUnwrap(HotKeyCombo(keyCode: 49, modifiers: HotKeyCombo.option, key: " ")).display, "⌥Space")
        XCTAssertEqual(try XCTUnwrap(HotKeyCombo(keyCode: 96, modifiers: HotKeyCombo.cmd, key: "\u{F708}")).display, "⌘F5")
    }

    func testCocoaFlagsMapToCarbonMask() {
        let cocoa: UInt = (1 << 17) | (1 << 18) | (1 << 19) | (1 << 20) | (1 << 16) // + caps lock, ignored
        XCTAssertEqual(HotKeyCombo.carbonModifiers(cocoa: cocoa), 0x1B00)
        XCTAssertEqual(HotKeyCombo.carbonModifiers(cocoa: 1 << 20), HotKeyCombo.cmd)
    }

    func testSavesAndClears() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "HotKeyComboTests"))
        defer { defaults.removePersistentDomain(forName: "HotKeyComboTests") }
        XCTAssertNil(HotKeyCombo.load(defaults))
        let combo = try XCTUnwrap(HotKeyCombo(keyCode: 46, modifiers: HotKeyCombo.control | HotKeyCombo.option, key: "m"))
        HotKeyCombo.save(combo, defaults)
        XCTAssertEqual(HotKeyCombo.load(defaults), combo)
        HotKeyCombo.save(nil, defaults)
        XCTAssertNil(HotKeyCombo.load(defaults))
    }

    func testToggleGoesDirectAndBackToTheLastMode() {
        XCTAssertEqual(HotKeyCombo.toggleTarget(current: .tunnel, last: .tunnel), .direct)
        XCTAssertEqual(HotKeyCombo.toggleTarget(current: .dpi, last: nil), .direct)
        XCTAssertEqual(HotKeyCombo.toggleTarget(current: .direct, last: .tunnel), .tunnel)
        XCTAssertEqual(HotKeyCombo.toggleTarget(current: .direct, last: nil), .dpi)
        XCTAssertEqual(HotKeyCombo.toggleTarget(current: .direct, last: .direct), .dpi)
    }
}
