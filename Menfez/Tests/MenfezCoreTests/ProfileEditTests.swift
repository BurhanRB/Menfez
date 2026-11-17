import XCTest
@testable import MenfezCore

/// Rename, delete and replace of a profile. Every test works in its own temp
/// directory; the real profile folder is never touched.
final class ProfileEditTests: XCTestCase {

    private var dir = ""

    override func setUpWithError() throws {
        dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("menfez-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func conf(_ endpoint: String) -> String {
        "[Interface]\nPrivateKey = TESTKEY\nAddress = 10.0.0.2/32\n[Peer]\nPublicKey = PUB\nEndpoint = \(endpoint)\nAllowedIPs = 0.0.0.0/0\n"
    }

    @discardableResult
    private func write(_ name: String, _ text: String, in folder: String? = nil) throws -> String {
        let path = ((folder ?? dir) as NSString).appendingPathComponent(name)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// Stands in for the user's Trash so a test run never adds files to it.
    private func fakeTrash(_ bin: String) -> (URL) throws -> Void {
        { try FileManager.default.moveItem(atPath: $0.path,
                                           toPath: (bin as NSString).appendingPathComponent($0.lastPathComponent)) }
    }

    private func names() -> [String] { WireGuardProfiles.list(directory: dir, liveHost: nil).map(\.name) }

    // MARK: validation

    func testValidatedNameAcceptsPlainNamesAndTrims() {
        XCTAssertEqual(WireGuardProfiles.validatedName("  Ev sunucusu_2-b "), "Ev sunucusu_2-b")
        XCTAssertEqual(WireGuardProfiles.validatedName("Bulgaristan"), "Bulgaristan")
    }

    func testValidatedNameRefusesPathsAndOddNames() {
        for bad in ["", "   ", "../x", "a/b", "a\\b", ".hidden", "..", "x.conf", "a\0b",
                    "wgmanaged", "foo-split", String(repeating: "a", count: 65), "a:b"] {
            XCTAssertNil(WireGuardProfiles.validatedName(bad), bad)
        }
    }

    // MARK: rename

    func testRenameMovesTheFileAndKeepsContents() throws {
        try write("old.conf", conf("1.2.3.4:51820"))
        let result = WireGuardProfiles.rename("old", to: "Yeni Ad", directory: dir)
        guard case .success(let p) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(p.name, "Yeni Ad")
        XCTAssertEqual(names(), ["Yeni Ad"])
        let text = try String(contentsOfFile: (dir as NSString).appendingPathComponent("Yeni Ad.conf"))
        XCTAssertEqual(text, conf("1.2.3.4:51820"))
    }

    func testRenameRefusesTraversalAndLeavesEverythingAlone() throws {
        try write("old.conf", conf("1.2.3.4:51820"))
        let result = WireGuardProfiles.rename("old", to: "../escaped", directory: dir)
        guard case .failure(let e) = result else { return XCTFail("renamed out of the folder") }
        XCTAssertEqual(e.kind, .badName)
        XCTAssertEqual(names(), ["old"])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: ((dir as NSString).deletingLastPathComponent as NSString).appendingPathComponent("escaped.conf")))
    }

    func testRenameNeverOverwritesAnotherProfile() throws {
        try write("a.conf", conf("1.1.1.1:1"))
        try write("b.conf", conf("2.2.2.2:2"))
        guard case .failure(let e) = WireGuardProfiles.rename("a", to: "b", directory: dir)
        else { return XCTFail("overwrote b") }
        XCTAssertEqual(e.kind, .exists)
        let b = try String(contentsOfFile: (dir as NSString).appendingPathComponent("b.conf"))
        XCTAssertTrue(b.contains("2.2.2.2"))
    }

    func testRenameOfAMissingProfileFails() {
        guard case .failure(let e) = WireGuardProfiles.rename("ghost", to: "x", directory: dir)
        else { return XCTFail() }
        XCTAssertEqual(e.kind, .missing)
    }

    // MARK: delete

    func testDeleteRemovesOnlyThatProfile() throws {
        try write("a.conf", conf("1.1.1.1:1"))
        try write("b.conf", conf("2.2.2.2:2"))
        XCTAssertTrue(WireGuardProfiles.delete("a", directory: dir, trash: { try FileManager.default.removeItem(at: $0) }))
        XCTAssertEqual(names(), ["b"])
    }

    /// The bug: one imported server could never be removed. The last one goes
    /// too, active or not, and the listing is then empty (the no-profiles flow).
    /// A deleted server goes to the Trash, not away for good.
    func testDeleteMovesTheFileToTheTrash() throws {
        try write("a.conf", conf("3.3.3.3:3"))
        let bin = (dir as NSString).appendingPathComponent("bin")
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        XCTAssertTrue(WireGuardProfiles.delete("a", directory: dir, trash: fakeTrash(bin)))
        XCTAssertTrue(names().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: (bin as NSString).appendingPathComponent("a.conf")))
    }

    /// No Trash on the volume (a network share): the file is still removed.
    func testDeleteFallsBackToRemovingWhenTrashFails() throws {
        try write("a.conf", conf("3.3.3.3:3"))
        struct NoTrash: Error {}
        XCTAssertTrue(WireGuardProfiles.delete("a", directory: dir, trash: { _ in throw NoTrash() }))
        XCTAssertTrue(names().isEmpty)
    }

    func testTheLastAndActiveProfileCanBeDeleted() throws {
        try write("only.conf", conf("9.9.9.9:51820"))
        let listed = WireGuardProfiles.list(directory: dir, liveHost: "9.9.9.9")
        XCTAssertEqual(listed.first?.active, true)
        XCTAssertTrue(WireGuardProfiles.delete("only", directory: dir, trash: { try FileManager.default.removeItem(at: $0) }))
        XCTAssertTrue(WireGuardProfiles.list(directory: dir, liveHost: "9.9.9.9").isEmpty)
    }

    func testDeleteRefusesPathsOutsideTheFolder() throws {
        let outside = (dir as NSString).deletingLastPathComponent
        let victim = try write("menfez-victim-\(UUID().uuidString).conf", "x", in: outside)
        defer { try? FileManager.default.removeItem(atPath: victim) }
        let stem = ((victim as NSString).lastPathComponent as NSString).deletingPathExtension
        XCTAssertFalse(WireGuardProfiles.delete("../\(stem)", directory: dir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim))
        XCTAssertFalse(WireGuardProfiles.delete("ghost", directory: dir))
    }

    // MARK: replace

    func testReplaceWritesNewConfigUnderTheSameName() throws {
        try write("srv.conf", conf("1.1.1.1:1"))
        let src = try write("download.conf", conf("5.6.7.8:51820"), in: NSTemporaryDirectory())
        defer { try? FileManager.default.removeItem(atPath: src) }
        let result = WireGuardProfiles.importConfig(from: src, overwrite: true, directory: dir, as: "srv")
        guard case .success(let p) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(p.name, "srv")
        XCTAssertEqual(p.endpoint, "5.6.7.8:51820")
        XCTAssertEqual(names(), ["srv"])
    }

    func testReplaceWithANonConfigKeepsTheOldFile() throws {
        try write("srv.conf", conf("1.1.1.1:1"))
        let src = try write("junk-\(UUID().uuidString).conf", "hello", in: NSTemporaryDirectory())
        defer { try? FileManager.default.removeItem(atPath: src) }
        guard case .failure(let e) = WireGuardProfiles.importConfig(from: src, overwrite: true,
                                                                    directory: dir, as: "srv")
        else { return XCTFail() }
        XCTAssertEqual(e.kind, .notAConfig)
        let text = try String(contentsOfFile: (dir as NSString).appendingPathComponent("srv.conf"))
        XCTAssertTrue(text.contains("1.1.1.1"))
    }

    func testReplaceRefusesAnUnsafeTargetName() throws {
        let src = try write("ok-\(UUID().uuidString).conf", conf("5.6.7.8:1"), in: NSTemporaryDirectory())
        defer { try? FileManager.default.removeItem(atPath: src) }
        guard case .failure(let e) = WireGuardProfiles.importConfig(from: src, overwrite: true,
                                                                    directory: dir, as: "../x")
        else { return XCTFail() }
        XCTAssertEqual(e.kind, .badName)
    }
}
