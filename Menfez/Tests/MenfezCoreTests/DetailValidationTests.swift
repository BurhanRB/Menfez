import XCTest
@testable import MenfezCore

/// `detail ip --value V` runs `host V` and curl on a URL built from V, as root
/// through the helper. Only a parsed address may get that far.
final class DetailValidationTests: XCTestCase {
    final class Recorder: CommandRunner, @unchecked Sendable {
        var calls: [[String]] = []
        func run(_ tool: String, _ args: [String], timeout: TimeInterval) -> CommandResult {
            calls.append([tool] + args)
            return CommandResult(status: 1, output: "")
        }
    }

    func testHostileValuesSpawnNothing() {
        for value in ["-x", "--config=/etc/passwd", "1.1.1.1/../x", "example.com", "1.1.1.1 -v"] {
            let r = Recorder()
            let response = Details.build(what: "ip", value: value, using: r)
            XCTAssertNotNil(response.error, value)
            XCTAssertTrue(r.calls.isEmpty, "\(value) reached \(r.calls)")
        }
    }

    func testValidAddressIsPassedOn() {
        let r = Recorder()
        _ = Details.build(what: "ip", value: "203.0.113.7", using: r)
        XCTAssertEqual(r.calls.first, ["host", "203.0.113.7"])
        XCTAssertTrue(r.calls.contains { $0.last == "https://ipinfo.io/203.0.113.7/json" })
    }
}
