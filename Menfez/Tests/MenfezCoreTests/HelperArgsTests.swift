import XCTest
@testable import MenfezCore

/// `down --if-generation V`: anything but a plain integer is a usage error,
/// never an unconditional teardown.
final class HelperArgsTests: XCTestCase {
    func testGenerationParsing() {
        XCTAssertEqual(Validate.generation("0"), 0)
        XCTAssertEqual(Validate.generation("42"), 42)
        for bad in [nil, "", "abc", "-1", "--down", "4 2", "+3", "1e3", "٣"] {
            XCTAssertNil(Validate.generation(bad), String(describing: bad))
        }
    }

    /// L6: root without SUDO_USER has no user home; it must not become /var/root.
    func testRealHomeAsRootWithoutSudoUser() {
        XCTAssertEqual(Path.realHome(euid: 0, sudoUser: nil), Path.noHome)
        XCTAssertEqual(Path.realHome(euid: 0, sudoUser: ""), Path.noHome)
        XCTAssertEqual(Path.realHome(euid: 0, sudoUser: "root"), Path.noHome)
        XCTAssertEqual(Path.realHome(euid: 0, sudoUser: NSUserName()), NSHomeDirectory())
        XCTAssertEqual(Path.realHome(euid: 501, sudoUser: nil), NSHomeDirectory())
    }

    func testImportErrorKindIsSendable() {
        let kind: any Sendable = WireGuardProfiles.ImportError.Kind.missing
        XCTAssertNotNil(kind)
    }
}
