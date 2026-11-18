import XCTest
@testable import MenfezCore

final class SingleInstanceTests: XCTestCase {
    private let id = "com.menfez.app"
    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testYieldsToAnOlderCopy() {
        let me = SingleInstance.Running(pid: 200, bundleID: id, launched: t0.addingTimeInterval(5))
        let old = SingleInstance.Running(pid: 100, bundleID: id, launched: t0)
        XCTAssertEqual(SingleInstance.yieldTo(me: me, others: [me, old]), old)
    }

    func testOlderCopyKeepsRunning() {
        let me = SingleInstance.Running(pid: 100, bundleID: id, launched: t0)
        let newer = SingleInstance.Running(pid: 200, bundleID: id, launched: t0.addingTimeInterval(5))
        XCTAssertNil(SingleInstance.yieldTo(me: me, others: [me, newer]))
    }

    func testSameMomentOnlyTheHigherPidQuits() {
        let a = SingleInstance.Running(pid: 100, bundleID: id, launched: t0)
        let b = SingleInstance.Running(pid: 200, bundleID: id, launched: t0)
        XCTAssertNil(SingleInstance.yieldTo(me: a, others: [a, b]))
        XCTAssertEqual(SingleInstance.yieldTo(me: b, others: [a, b]), a)
    }

    func testOtherAppsAndUnbundledRunsAreIgnored() {
        let me = SingleInstance.Running(pid: 200, bundleID: id, launched: t0.addingTimeInterval(5))
        let other = SingleInstance.Running(pid: 100, bundleID: "com.hnc.Discord", launched: t0)
        XCTAssertNil(SingleInstance.yieldTo(me: me, others: [other]))
        let bare = SingleInstance.Running(pid: 200, bundleID: nil, launched: nil)
        XCTAssertNil(SingleInstance.yieldTo(me: bare, others: [SingleInstance.Running(pid: 1, bundleID: nil, launched: nil)]))
    }
}

final class DiscordStateTests: XCTestCase {
    func testStates() {
        let flag = ["/Applications/Discord.app/Contents/MacOS/Discord", "--proxy-server=http://127.0.0.1:6000"]
        XCTAssertEqual(DiscordLauncher.state(running: false, arguments: flag, port: 6000), .closed)
        XCTAssertEqual(DiscordLauncher.state(running: true, arguments: flag, port: 6000), .viaDPI)
        XCTAssertEqual(DiscordLauncher.state(running: true, arguments: flag, port: 6001), .withoutDPI)
        XCTAssertEqual(DiscordLauncher.state(running: true, arguments: [flag[0]], port: 6000), .withoutDPI)
        XCTAssertEqual(DiscordLauncher.state(running: true, arguments: flag, port: nil), .withoutDPI)
        XCTAssertEqual(DiscordLauncher.state(running: true, arguments: nil, port: 6000), .running)
    }
}
