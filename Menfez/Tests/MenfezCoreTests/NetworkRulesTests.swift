import XCTest
@testable import MenfezCore

/// Network-based automatic mode (1.0.8, feature 5): when a rule applies, when
/// the user's own choice wins, and the saved list.
final class NetworkRulesTests: XCTestCase {

    private func decide(_ rule: NetworkMode?, enabled: Bool = true, pending: Bool = true,
                        manual: Bool = false, current: RunMode = .direct,
                        tunnelReady: Bool = true) -> NetworkAction {
        NetworkWatch.decide(rule: rule, enabled: enabled, pending: pending, manual: manual,
                            current: current, tunnelReady: tunnelReady)
    }

    func testRuleSwitchesOnlyWhenOnAndOwed() {
        XCTAssertEqual(decide(.dpi), .switchTo(.dpi))
        XCTAssertEqual(decide(.direct, current: .dpi), .switchTo(.direct))
        XCTAssertEqual(decide(.dpi, enabled: false), .none, "off by default: nothing changes")
        XCTAssertEqual(decide(.dpi, pending: false), .none, "once per join")
        XCTAssertEqual(decide(.dpi, current: .dpi), .none, "already there")
    }

    func testUnknownNetworkAndLeaveChangeNothing() {
        XCTAssertEqual(decide(nil, current: .tunnel), .none, "AS-14: unknown network keeps the mode")
        XCTAssertEqual(decide(.leave, current: .dpi), .none)
    }

    func testManualChoiceWinsUntilTheNextNetwork() {
        XCTAssertEqual(decide(.dpi, manual: true), .none)
        var watch = NetworkWatch()
        watch.observe("home")
        watch.userChose()
        XCTAssertEqual(NetworkWatch.decide(rule: .dpi, enabled: true, pending: watch.pending,
                                           manual: watch.manual, current: .direct, tunnelReady: true), .none)
        watch.observe("home")
        XCTAssertTrue(watch.manual, "the same network again is not a change")
        watch.observe("school")
        XCTAssertFalse(watch.manual)
        XCTAssertTrue(watch.pending)
    }

    func testTunnelRuleWithoutTunnelOnlyTells() {
        XCTAssertEqual(decide(.tunnel, tunnelReady: false), .needsTunnel)
        XCTAssertEqual(decide(.tunnel), .switchTo(.tunnel))
        XCTAssertEqual(decide(.tunnel, current: .tunnel, tunnelReady: false), .none)
    }

    func testWatchJoinsOnChangeAndSettles() {
        var watch = NetworkWatch()
        watch.observe(nil)
        XCTAssertFalse(watch.pending, "nothing to apply on an unknown network")
        watch.observe("a")
        XCTAssertTrue(watch.pending)
        watch.settled()
        watch.observe("a")
        XCTAssertFalse(watch.pending, "same network, already settled")
        watch.observe(nil)
        watch.observe("a")
        XCTAssertTrue(watch.pending, "left and came back: a new join")
        watch.settled()
        watch.userChose()
        watch.reapply()
        XCTAssertTrue(watch.pending)
        XCTAssertFalse(watch.manual, "editing the rule is itself the user's choice")
    }

    func testNamesAreTheUsersAndNumberedWithoutClashing() {
        var list = NetworkList()
        XCTAssertEqual(list.nextName(prefix: "Ağ"), "Ağ 1")
        list.networks = [KnownNetwork(id: "a", name: "Ağ 1", mode: .dpi),
                         KnownNetwork(id: "b", name: "Ağ 3", mode: .dpi)]
        XCTAssertEqual(list.nextName(prefix: "Ağ"), "Ağ 2")
        XCTAssertEqual(NetworkList.cleanName("  Okul\nağı "), "Okul ağı")
        XCTAssertNil(NetworkList.cleanName("   "))
        XCTAssertEqual(NetworkList.cleanName(String(repeating: "x", count: 99))?.count, NetworkList.maxName)
        XCTAssertEqual(list.entry("b")?.name, "Ağ 3")
        XCTAssertNil(list.entry(nil))
    }

    func testListSavesPrivatelyAndAnUnreadableFileIsKept() throws {
        let dir = NSTemporaryDirectory() + "menfez-networks-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/networks.json"
        XCTAssertEqual(NetworkList.load(path: path).list.networks, [])
        let saved = NetworkList(networks: [KnownNetwork(id: "abc", name: "Ev", mode: .direct)])
        XCTAssertTrue(saved.save(path: path))
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertEqual(NetworkList.load(path: path).list, saved)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(text.contains("\"version\""))

        // A later version's extra fields and unknown mode do not lose the list.
        try #"{"version":1,"networks":[{"id":"abc","name":"Ev","mode":"auto2","dpi":{"split":5}},{"id":"abc","name":"dup","mode":"dpi"}]}"#
            .write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(NetworkList.load(path: path).list.networks, [KnownNetwork(id: "abc", name: "Ev", mode: .leave)])

        try "not json".write(toFile: path, atomically: true, encoding: .utf8)
        let broken = NetworkList.load(path: path)
        XCTAssertTrue(broken.recovered)
        XCTAssertEqual(broken.list.networks, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + ".bak"))
    }

    func testAutoModeIsOffByDefault() {
        let d = UserDefaults(suiteName: "menfez-networks-" + UUID().uuidString)!
        XCTAssertFalse(NetworkList.isEnabled(d))
        d.set(true, forKey: NetworkList.enabledKey)
        XCTAssertTrue(NetworkList.isEnabled(d))
    }
}
