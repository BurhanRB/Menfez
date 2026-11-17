import XCTest
@testable import MenfezCore

final class ChangelogTests: XCTestCase {

    func testNotEmptyAndBulletsMatchInBothLanguages() {
        XCTAssertFalse(Changelog.entries.isEmpty)
        for e in Changelog.entries {
            XCTAssertFalse(e.tr.isEmpty, e.version)
            XCTAssertLessThanOrEqual(e.tr.count, 8, e.version)
            XCTAssertEqual(e.tr.count, e.en.count, e.version)
        }
    }

    /// The bundle's version comes from build-app.sh; the newest entry must be it,
    /// or the panel would describe a release the user does not have.
    func testNewestEntryIsTheBuiltVersion() throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build-app.sh")
        let text = try String(contentsOf: script, encoding: .utf8)
        let line = try XCTUnwrap(text.split(separator: "\n").first { $0.hasPrefix("VERSION=\"") })
        let built = line.dropFirst("VERSION=\"".count).prefix { $0 != "\"" }
        XCTAssertEqual(AppVersion.short(from: ["CFBundleShortVersionString": String(built)]),
                       Changelog.entries.first?.version)
    }

    /// Every bullet opens with a capital letter, Turkish-aware (i → İ).
    func testBulletsStartWithCapital() {
        for e in Changelog.entries {
            for (items, locale) in [(e.tr, "tr_TR"), (e.en, "en_GB")] {
                for item in items {
                    let first = String(item.prefix(1))
                    XCTAssertEqual(first, first.uppercased(with: Locale(identifier: locale)),
                                   "\(e.version): \(item)")
                }
            }
        }
    }

    /// Releases bump the patch number by one (1.0.0, 1.0.1, …). A minor or
    /// major bump is allowed; an equal or out-of-order version never is.
    func testVersionsStepDownByOnePatch() throws {
        func semver(_ v: String) throws -> [Int] {
            let parts = v.split(separator: ".").compactMap { Int($0) }
            XCTAssertEqual(parts.count, 3, "\(v) is not x.y.z")
            return parts.count == 3 ? parts : [0, 0, 0]
        }
        let versions = try Changelog.entries.map { try semver($0.version) }
        for (newer, older) in zip(versions, versions.dropFirst()) {
            XCTAssertTrue(older.lexicographicallyPrecedes(newer),
                          "\(newer) must be newer than \(older)")
            if newer[0] == older[0], newer[1] == older[1] {
                XCTAssertEqual(newer[2], older[2] + 1, "\(older) → \(newer) skips a patch number")
            }
        }
    }
}
