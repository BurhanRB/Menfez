import XCTest
@testable import MenfezCore

/// What root may execute. /opt/homebrew is owned by the user on Apple silicon,
/// so anything root finds there is a binary the user chose.
final class RootToolTrustTests: XCTestCase {

    // MARK: - resolve

    /// Every system tool the helper calls must come from the system volume when
    /// root, even if a same-named file is planted in Homebrew.
    func testRootNeverResolvesSystemToolsFromHomebrew() {
        let everywhere: (String) -> Bool = { _ in true }
        for tool in ["route", "networksetup", "ifconfig", "ipconfig", "killall",
                     "dscacheutil", "curl", "host", "scutil", "dig", "open"] {
            let path = Shell.resolve(tool, root: true, isExecutable: everywhere)
            XCTAssertTrue(Shell.systemDirs.contains((path as NSString).deletingLastPathComponent),
                          "\(tool) resolved to \(path)")
        }
        // Not found anywhere: still an absolute system path, never a bare name
        // that would be looked up in the caller's working directory.
        XCTAssertEqual(Shell.resolve("nosuchtool", root: true, isExecutable: { _ in false }),
                       "/usr/bin/nosuchtool")
    }

    func testRootResolvesWireGuardToolsOnlyFromTrustedDir() {
        for tool in ["wg", "wg-quick", "wireguard-go", "bash"] {
            XCTAssertEqual(Shell.resolve(tool, root: true, isExecutable: { _ in true }),
                           Path.trustedBin + "/" + tool)
        }
    }

    func testRootPathHasNoHomebrew() {
        let path = Shell.path(root: true)
        XCTAssertFalse(path.contains("homebrew"))
        XCTAssertFalse(path.contains("/usr/local"))
        XCTAssertTrue(path.hasPrefix(Path.trustedBin + ":"))
    }

    /// A normal user keeps the old lookup: Homebrew first.
    func testUserLookupUnchanged() {
        XCTAssertEqual(Shell.resolve("wg", root: false, isExecutable: { _ in true }),
                       "/opt/homebrew/bin/wg")
        XCTAssertEqual(Shell.resolve("wg", root: false, isExecutable: { _ in false }), "wg")
    }

    // MARK: - trust check

    private let tool = "/Library/PrivilegedHelperTools/menfez/bin/wg"

    private func tree(_ overrides: [String: Shell.FileInfo] = [:]) -> (String) -> Shell.FileInfo? {
        let dir = Shell.FileInfo(uid: 0, mode: S_IFDIR | 0o755)
        var all: [String: Shell.FileInfo] = [
            "/": dir, "/Library": dir, "/Library/PrivilegedHelperTools": dir,
            "/Library/PrivilegedHelperTools/menfez": dir,
            "/Library/PrivilegedHelperTools/menfez/bin": dir,
            tool: Shell.FileInfo(uid: 0, mode: S_IFREG | 0o755),
        ]
        all.merge(overrides) { _, new in new }
        return { all[$0] }
    }

    func testRootOwnedChainIsTrusted() {
        XCTAssertNil(Shell.trustViolation(tool, info: tree()))
    }

    func testUserOwnedToolIsRefused() {
        let why = Shell.trustViolation(tool, info: tree([tool: .init(uid: 501, mode: S_IFREG | 0o755)]))
        XCTAssertEqual(why, "\(tool) is not owned by root")
    }

    func testGroupWritableParentIsRefused() {
        let parent = "/Library/PrivilegedHelperTools/menfez"
        let why = Shell.trustViolation(tool, info: tree([parent: .init(uid: 0, mode: S_IFDIR | 0o775)]))
        XCTAssertEqual(why, "\(parent) is writable by group or others")
    }

    func testOtherWritableToolSymlinkAndMissingAreRefused() {
        XCTAssertNotNil(Shell.trustViolation(tool, info: tree([tool: .init(uid: 0, mode: S_IFREG | 0o757)])))
        XCTAssertNotNil(Shell.trustViolation(tool, info: tree([tool: .init(uid: 0, mode: S_IFLNK | 0o755)])))
        XCTAssertEqual(Shell.trustViolation("/nope/wg", info: tree()), "/nope/wg does not exist")
        XCTAssertNotNil(Shell.trustViolation("relative/wg", info: tree()))
    }

    /// The real filesystem: a temp file belongs to the test user.
    func testRealUserFileIsRefused() throws {
        let file = NSTemporaryDirectory() + "menfez-trust-\(UUID().uuidString)"
        FileManager.default.createFile(atPath: file, contents: Data())
        defer { try? FileManager.default.removeItem(atPath: file) }
        XCTAssertNotNil(Shell.trustViolation(file))
        XCTAssertNil(Shell.trustViolation("/bin/sh"))
    }

    // MARK: - HelperClient

    /// The production client refuses before spawning sudo when the helper
    /// fails the trust check, and says why in both languages.
    func testHelperClientRefusesUntrustedHelper() {
        let client = HelperClient(helper: "/Users/someone/Menfez.app/Contents/MacOS/menfez-route",
                                  trust: { _ in "it is not owned by root" })
        let result = client.run(["status"])
        XCTAssertEqual(result.status, 126)
        XCTAssertTrue(result.output.contains("it is not owned by root"))
        XCTAssertTrue(result.output.contains("Root olarak"))
        XCTAssertFalse(client.act(["down"]).ok)

        // The real check, against a helper that is not installed here.
        XCTAssertEqual(HelperClient(helper: "/nonexistent/menfez-route").run(["status"]).status, 126)
    }

    func testAppCallsOnlyTheRootOwnedHelper() {
        XCTAssertEqual(TunnelSetup.trustedHelper,
                       "/Library/PrivilegedHelperTools/menfez/menfez-route")
    }

    func testRefusalIsBilingual() {
        let message = Shell.untrustedMessage("x")
        XCTAssertTrue(message.contains("Refusing to run as root"))
        XCTAssertTrue(message.contains("Root olarak çalıştırılmadı"))
    }
}
