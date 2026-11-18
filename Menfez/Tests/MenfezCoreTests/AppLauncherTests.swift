import XCTest
@testable import MenfezCore

final class AppLauncherTests: XCTestCase {

    func testFlagAppArguments() {
        let slack = AppLauncher.app("com.tinyspeck.slackmacgap")!
        XCTAssertEqual(AppLauncher.arguments(for: slack, port: 64799),
                       ["-b", "com.tinyspeck.slackmacgap", "--args", "--proxy-server=http://127.0.0.1:64799"])
    }

    func testNoArgumentsWithoutPortOrForOtherRoutes() {
        let slack = AppLauncher.app("com.tinyspeck.slackmacgap")!
        XCTAssertNil(AppLauncher.arguments(for: slack, port: nil))
        XCTAssertNil(AppLauncher.arguments(for: slack, port: 0))
        XCTAssertNil(AppLauncher.arguments(for: slack, port: 70000))
        XCTAssertNil(AppLauncher.arguments(for: AppLauncher.app("org.telegram.desktop")!, port: 64799))
        XCTAssertNil(AppLauncher.arguments(for: AppLauncher.app("com.roblox.RobloxPlayer")!, port: 64799))
        // Not from the catalog: refused even if it claims the flag route.
        let rogue = AppLauncher.App(name: "x", bundleID: "-a/evil", route: .flag)
        XCTAssertNil(AppLauncher.arguments(for: rogue, port: 64799))
    }

    func testCatalogIsUniqueAndHasNoDiscord() {
        let ids = AppLauncher.catalog.map(\.bundleID)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertFalse(ids.contains(DiscordLauncher.bundleID))
        XCTAssertTrue(ids.allSatisfy { !$0.hasPrefix("-") && !$0.contains(" ") })
    }

    func testAddress() {
        XCTAssertEqual(AppLauncher.address(port: 64799), "127.0.0.1:64799")
    }

    func testFlaggedPIDs() {
        let ps = """
          101 /Applications/Slack.app/Contents/MacOS/Slack --proxy-server=http://127.0.0.1:64799
          102 /Applications/Slack.app/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper --type=renderer --proxy-server=http://127.0.0.1:64799
          103 /Applications/Discord.app/Contents/MacOS/Discord --proxy-server=http://127.0.0.1:64799
          104 /Applications/Signal.app/Contents/MacOS/Signal --proxy-server=http://127.0.0.1:647990
          105 /Applications/Element.app/Contents/MacOS/Element
          106 /usr/bin/curl --proxy-server=http://127.0.0.1:64799
        """
        XCTAssertEqual(AppLauncher.flaggedPIDs(psOutput: ps, port: 64799), [101])
        XCTAssertEqual(AppLauncher.flaggedPIDs(psOutput: ps, port: nil), [101, 104])
    }
}
