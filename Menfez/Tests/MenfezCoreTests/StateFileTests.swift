import XCTest
@testable import MenfezCore

/// The shared state-file writer: modes, atomicity and the directory it shares.
final class StateFileTests: XCTestCase {
    private var dir: String!

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "menfez-statefile-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func mode(_ path: String) -> mode_t {
        var st = stat()
        XCTAssertEqual(lstat(path, &st), 0)
        return st.st_mode & 0o777
    }

    /// A 0600 file written into the shared directory must not flip it to 0700:
    /// that hid the 0644 route state from the unprivileged app.
    func testPrivateFileKeepsSharedDirectoryTraversable() {
        let shared = dir + "/run"
        XCTAssertTrue(StateFile.write("{}\n", to: shared + "/route-state.json"))
        XCTAssertTrue(StateFile.write("{}\n", to: shared + "/other.json", mode: 0o600))
        XCTAssertEqual(mode(shared), 0o755)
        XCTAssertEqual(mode(shared + "/route-state.json"), 0o644)
        XCTAssertEqual(mode(shared + "/other.json"), 0o600)
    }

    func testExplicitPrivateDirectoryMode() {
        let priv = dir + "/support"
        XCTAssertTrue(StateFile.write("x\n", to: priv + "/s.json", mode: 0o600, dirMode: 0o700))
        XCTAssertEqual(mode(priv), 0o700)
    }

    func testOverwriteReplacesContentAndLeavesNoTemporary() throws {
        let file = dir + "/s.json"
        XCTAssertTrue(StateFile.write("one\n", to: file))
        XCTAssertTrue(StateFile.write("two\n", to: file))
        XCTAssertEqual(try String(contentsOfFile: file, encoding: .utf8), "two\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file + ".tmp"))
    }
}
