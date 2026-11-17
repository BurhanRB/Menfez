import XCTest
@testable import MenfezCore

/// The About panel's version string.
///
/// The fallback is the whole point: a `swift run` build has no Info.plist, and a
/// script-generated bundle can carry an empty value. Both used to be a place
/// where an inline force-cast would crash on launch, so both are asserted here.
final class AppVersionTests: XCTestCase {

    func testReadsShortVersionString() {
        let info: [String: Any] = ["CFBundleShortVersionString": "1.2.3"]
        XCTAssertEqual(AppVersion.short(from: info), "1.2.3")
    }

    func testMissingKeyFallsBack() {
        XCTAssertEqual(AppVersion.short(from: [:]), AppVersion.fallback)
        XCTAssertEqual(AppVersion.short(from: nil), AppVersion.fallback)
    }

    /// A generated plist with an unset variable expands to nothing. "1.0" is a
    /// better answer than an empty chip beside the app name.
    func testEmptyOrWhitespaceFallsBack() {
        XCTAssertEqual(AppVersion.short(from: ["CFBundleShortVersionString": ""]),
                       AppVersion.fallback)
        XCTAssertEqual(AppVersion.short(from: ["CFBundleShortVersionString": "   "]),
                       AppVersion.fallback)
        XCTAssertEqual(AppVersion.short(from: ["CFBundleShortVersionString": "\n\t "]),
                       AppVersion.fallback)
    }

    /// A plist key with the wrong type is a broken bundle, not a crash.
    func testNonStringFallsBack() {
        XCTAssertEqual(AppVersion.short(from: ["CFBundleShortVersionString": 42]),
                       AppVersion.fallback)
        XCTAssertEqual(AppVersion.short(from: ["CFBundleShortVersionString": ["1.0"]]),
                       AppVersion.fallback)
    }

    func testSurroundingSpaceIsRemoved() {
        XCTAssertEqual(AppVersion.short(from: ["CFBundleShortVersionString": " 1.0.1\n"]),
                       "1.0.1")
    }

    /// The value the panel shows in a test process is the fallback, because a
    /// test bundle has no `CFBundleShortVersionString`. This is not a tautology:
    /// it is the case that would crash if the lookup were force-unwrapped.
    func testRealBundleLookupIsSafe() {
        let value = AppVersion.short(from: Bundle.main.infoDictionary)
        XCTAssertFalse(value.isEmpty)
    }
}
