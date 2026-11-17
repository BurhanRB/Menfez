import XCTest
@testable import MenfezCore

/// "Launch at login": SMAppService first, a LaunchAgent plist when that does
/// not end up enabled. Every test writes into a temp directory only.
final class LoginItemTests: XCTestCase {

    private final class FakeService: LoginService {
        var status: LoginServiceStatus = .notRegistered
        var statusAfterRegister: LoginServiceStatus = .enabled
        var registerThrows = false
        var unregisterCalls = 0
        struct Refused: Error {}

        func register() throws {
            if registerThrows { throw Refused() }
            status = statusAfterRegister
        }
        func unregister() throws {
            unregisterCalls += 1
            status = .notRegistered
        }
    }

    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("loginitem-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func item(_ s: FakeService) -> LoginItem {
        LoginItem(service: s, agentURL: LoginItem.agentURL(home: home),
                  program: ["/usr/bin/open", "-a", "/Applications/Menfez.app"])
    }

    private var agentExists: Bool {
        FileManager.default.fileExists(atPath: LoginItem.agentURL(home: home).path)
    }

    func testServiceEnabledWritesNoAgent() throws {
        let s = FakeService()
        let li = item(s)
        XCTAssertFalse(li.isEnabled)
        XCTAssertEqual(try li.enable(), .service)
        XCTAssertTrue(li.isEnabled)
        XCTAssertFalse(agentExists)
    }

    func testRegisterThrowsFallsBackToAgent() throws {
        let s = FakeService()
        s.registerThrows = true
        let li = item(s)
        XCTAssertEqual(try li.enable(), .launchAgent)
        XCTAssertTrue(agentExists)
        XCTAssertTrue(li.isEnabled)

        let data = try Data(contentsOf: LoginItem.agentURL(home: home))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["Label"] as? String, "com.menfez.app.loginitem")
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["ProgramArguments"] as? [String],
                       ["/usr/bin/open", "-a", "/Applications/Menfez.app"])
    }

    func testRequiresApprovalKeepsRegistrationAndWritesNoAgent() throws {
        let s = FakeService()
        s.statusAfterRegister = .requiresApproval
        let li = item(s)
        XCTAssertEqual(try li.enable(), .needsApproval)
        XCTAssertEqual(s.unregisterCalls, 0, "the pending registration is kept")
        XCTAssertEqual(s.status, .requiresApproval)
        XCTAssertFalse(agentExists, "no LaunchAgent beside a pending registration")
        XCTAssertTrue(li.isEnabled)
        XCTAssertTrue(li.needsApproval)

        try li.disable()
        XCTAssertEqual(s.unregisterCalls, 1)
        XCTAssertFalse(li.isEnabled)
    }

    func testOtherStatusAfterRegisterFallsBackToAgent() throws {
        let s = FakeService()
        s.statusAfterRegister = .notFound
        let li = item(s)
        XCTAssertEqual(try li.enable(), .launchAgent)
        XCTAssertEqual(s.unregisterCalls, 1)
        XCTAssertTrue(agentExists)
    }

    func testOnlyInstalledCopiesQualify() {
        let home = URL(fileURLWithPath: "/Users/x")
        XCTAssertTrue(LoginItem.isInstalled(bundlePath: "/Applications/Menfez.app", home: home))
        XCTAssertTrue(LoginItem.isInstalled(bundlePath: "/Users/x/Applications/Menfez.app", home: home))
        XCTAssertFalse(LoginItem.isInstalled(bundlePath: "/Users/x/Downloads/Menfez.app", home: home))
        XCTAssertFalse(LoginItem.isInstalled(
            bundlePath: "/private/var/folders/ab/AppTranslocation/X/d/Menfez.app", home: home))
        XCTAssertFalse(LoginItem.isInstalled(bundlePath: "/Applications/../tmp/Menfez.app", home: home))
        XCTAssertFalse(LoginItem.isInstalled(bundlePath: "/ApplicationsX/Menfez.app", home: home))
    }

    func testDisableRemovesAgent() throws {
        let s = FakeService()
        s.registerThrows = true
        let li = item(s)
        try li.enable()
        try li.disable()
        XCTAssertFalse(agentExists)
        XCTAssertFalse(li.isEnabled)
        XCTAssertEqual(s.unregisterCalls, 0, "nothing registered, nothing to unregister")
    }

    func testDisableUnregistersService() throws {
        let s = FakeService()
        let li = item(s)
        try li.enable()
        try li.disable()
        XCTAssertEqual(s.unregisterCalls, 1)
        XCTAssertFalse(li.isEnabled)
    }

    func testAgentPathIsPerUser() {
        XCTAssertEqual(LoginItem.agentURL(home: URL(fileURLWithPath: "/Users/x")).path,
                       "/Users/x/Library/LaunchAgents/com.menfez.app.loginitem.plist")
    }
}
