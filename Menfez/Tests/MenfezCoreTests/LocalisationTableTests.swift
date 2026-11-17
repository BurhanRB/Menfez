import XCTest
import MenfezCore

/// The app's TR/EN string table lives in the app target, which this test
/// target cannot import. A dictionary literal with a duplicate key traps at
/// runtime (c643400 shipped one and the app crashed on its first string), so
/// the table is checked here from its source text instead.
final class LocalisationTableTests: XCTestCase {

    private func keys(_ lang: String, in source: String) throws -> [String] {
        let start = try XCTUnwrap(source.range(of: "        .\(lang): [\n"))
        let end = try XCTUnwrap(source.range(of: "\n        ],\n", range: start.upperBound..<source.endIndex))
        let body = source[start.upperBound..<end.lowerBound]
        let regex = try NSRegularExpression(pattern: #"^\s*"([^"]+)":"#, options: .anchorsMatchLines)
        let text = String(body)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
            String(text[Range($0.range(at: 1), in: text)!])
        }
    }

    func testTablesHaveNoDuplicatesAndTheSameKeys() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Menfez/MenfezApp.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        let tr = try keys("tr", in: source)
        let en = try keys("en", in: source)
        XCTAssertGreaterThan(tr.count, 50, "parser found the table")

        for (name, list) in [("tr", tr), ("en", en)] {
            let dupes = Dictionary(grouping: list, by: { $0 }).filter { $0.value.count > 1 }.keys
            XCTAssertTrue(dupes.isEmpty, "\(name) has duplicate keys: \(dupes.sorted())")
        }
        XCTAssertEqual(Set(tr).subtracting(en).sorted(), [], "keys only in tr")
        XCTAssertEqual(Set(en).subtracting(tr).sorted(), [], "keys only in en")

        // Every Discord failure the probe can report has a label.
        for failure in [DiscordProbe.Failure.dns, .connect, .tls, .proxy, .blocked] {
            XCTAssertTrue(tr.contains(failure.labelKey), "missing label \(failure.labelKey)")
        }
    }
}
