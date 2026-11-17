import XCTest
@testable import MenfezCore

final class DebugLogTests: XCTestCase {
    private var dir: String!

    override func setUp() {
        dir = NSTemporaryDirectory() + "debuglog-\(UUID().uuidString)/Logs"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: (dir as NSString).deletingLastPathComponent)
    }

    private func mode(_ path: String) -> mode_t {
        var info = stat()
        lstat(path, &info)
        return info.st_mode & 0o777
    }

    func testCreatesPrivateDirectoryAndFile() throws {
        XCTAssertTrue(DebugLog.append("a\n", to: "t.log", in: dir))
        XCTAssertTrue(DebugLog.append("b\n", to: "t.log", in: dir))
        let file = dir + "/t.log"
        XCTAssertEqual(mode(dir), 0o700)
        XCTAssertEqual(mode(file), 0o600)
        XCTAssertEqual(try String(contentsOfFile: file, encoding: .utf8), "a\nb\n")
    }

    func testRotatesPastTheCap() throws {
        DebugLog.append("0123456789\n", to: "t.log", in: dir, maxBytes: 5)
        DebugLog.append("new\n", to: "t.log", in: dir, maxBytes: 5)
        XCTAssertEqual(try String(contentsOfFile: dir + "/t.log", encoding: .utf8), "new\n")
        XCTAssertEqual(try String(contentsOfFile: dir + "/t.log.1", encoding: .utf8), "0123456789\n")
    }

    func testRefusesASymlinkedFile() throws {
        XCTAssertTrue(Path.ensureDir(dir))
        let target = (dir as NSString).deletingLastPathComponent + "/victim"
        FileManager.default.createFile(atPath: target, contents: Data())
        try FileManager.default.createSymbolicLink(atPath: dir + "/t.log", withDestinationPath: target)
        XCTAssertFalse(DebugLog.append("x\n", to: "t.log", in: dir))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: target)).count, 0)
    }
}
