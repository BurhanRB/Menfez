import XCTest
@testable import MenfezCore

/// The helper's `proxy pac|off|status` (1.0.8, helper 6), against a fake
/// networksetup that keeps each service's setting in memory.
final class SystemProxyTests: XCTestCase {

    /// networksetup for `services` (name → setting); "*name" is disabled.
    final class FakeNetworksetup: CommandRunner, @unchecked Sendable {
        var order: [String]
        var settings: [String: SystemProxy.Setting]
        var refuseSet = false
        var listFails = false
        private(set) var calls: [[String]] = []

        init(_ services: [(String, SystemProxy.Setting)]) {
            order = services.map(\.0)
            settings = Dictionary(uniqueKeysWithValues: services.map {
                ($0.0.hasPrefix("*") ? String($0.0.dropFirst()) : $0.0, $0.1)
            })
        }

        func run(_ tool: String, _ args: [String], timeout: TimeInterval) -> CommandResult {
            XCTAssertEqual(tool, "networksetup")
            calls.append(args)
            switch args.first {
            case "-listallnetworkservices":
                if listFails { return CommandResult(status: 1, output: "") }
                return CommandResult(status: 0, output: "An asterisk (*) denotes that a network service is disabled.\n"
                                     + order.joined(separator: "\n") + "\n")
            case "-getautoproxyurl":
                guard let s = settings[args[1]] else { return CommandResult(status: 1, output: "not found") }
                return CommandResult(status: 0, output: "URL: \(s.url ?? "(null)")\nEnabled: \(s.enabled ? "Yes" : "No")\n")
            case "-setautoproxyurl":
                if refuseSet { return CommandResult(status: 1, output: "error") }
                settings[args[1]]?.url = args[2]
                settings[args[1]]?.enabled = true
                return CommandResult(status: 0, output: "")
            case "-setautoproxystate":
                if refuseSet { return CommandResult(status: 1, output: "error") }
                settings[args[1]]?.enabled = args[2] == "on"
                return CommandResult(status: 0, output: "")
            default:
                return CommandResult(status: 1, output: "unexpected")
            }
        }
    }

    private var statePath = ""

    override func setUp() {
        statePath = NSTemporaryDirectory() + "proxy-\(UUID().uuidString)/proxy-state.json"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: (statePath as NSString).deletingLastPathComponent)
    }

    private let off = SystemProxy.Setting(url: nil, enabled: false)

    // MARK: - Parsing

    func testServiceListSkipsLegendAndDisabled() {
        let text = """
        An asterisk (*) denotes that a network service is disabled.
        Thunderbolt Bridge
        *USB 10/100/1000 LAN
        Wi-Fi
        iPhone USB 2
        -rogue

        """
        XCTAssertEqual(SystemProxy.enabledServices(text), ["Thunderbolt Bridge", "Wi-Fi", "iPhone USB 2"])
    }

    func testAutoProxyOutput() {
        XCTAssertEqual(SystemProxy.setting("URL: (null)\nEnabled: No\n"), off)
        XCTAssertEqual(SystemProxy.setting("URL: http://wpad.corp/proxy.pac\nEnabled: Yes\n"),
                       SystemProxy.Setting(url: "http://wpad.corp/proxy.pac", enabled: true))
        XCTAssertNil(SystemProxy.setting("** Error: The parameters were not valid.\n"))
        XCTAssertNil(SystemProxy.setting("URL: (null)\n"))
    }

    func testPortValidation() {
        XCTAssertEqual(SystemProxy.port("8080"), 8080)
        XCTAssertEqual(SystemProxy.port("1024"), 1024)
        XCTAssertEqual(SystemProxy.port("65535"), 65535)
        for bad in [nil, "", "80", "1023", "65536", "-1", "8080 ", "0x1f90", "８０８０", "8080;rm", "123456"] {
            XCTAssertNil(SystemProxy.port(bad), String(describing: bad))
        }
    }

    func testOurURL() {
        XCTAssertEqual(SystemProxy.pacURL(port: 52100), "http://127.0.0.1:52100/menfez.pac")
        XCTAssertEqual(SystemProxy.ourPort(url: "http://127.0.0.1:52100/menfez.pac"), 52100)
        XCTAssertNil(SystemProxy.ourPort(url: "http://127.0.0.1:52100/other.pac"))
        XCTAssertNil(SystemProxy.ourPort(url: "http://wpad.corp/menfez.pac"))
        XCTAssertNil(SystemProxy.ourPort(url: nil))
    }

    func testLivePortFromSystemSettings() {
        XCTAssertEqual(SystemProxy.livePort(settings: ["ProxyAutoConfigEnable": 1,
                                                       "ProxyAutoConfigURLString": "http://127.0.0.1:4000/menfez.pac"]), 4000)
        XCTAssertNil(SystemProxy.livePort(settings: ["ProxyAutoConfigEnable": 0,
                                                     "ProxyAutoConfigURLString": "http://127.0.0.1:4000/menfez.pac"]))
        XCTAssertNil(SystemProxy.livePort(settings: ["ProxyAutoConfigEnable": 1,
                                                     "ProxyAutoConfigURLString": "http://wpad/x.pac"]))
        XCTAssertNil(SystemProxy.livePort(settings: nil))
    }

    func testWanted() {
        XCTAssertEqual(SystemProxy.wanted(enabled: true, dpiRunning: true, port: 5000), 5000)
        XCTAssertNil(SystemProxy.wanted(enabled: false, dpiRunning: true, port: 5000))
        XCTAssertNil(SystemProxy.wanted(enabled: true, dpiRunning: false, port: 5000))
        XCTAssertNil(SystemProxy.wanted(enabled: true, dpiRunning: true, port: nil))
    }

    // MARK: - Planning

    func testRememberKeepsTheOriginalAndNeverRecordsOurOwnURL() {
        let corp = SystemProxy.Setting(url: "http://wpad.corp/p.pac", enabled: true)
        let first = SystemProxy.remember(current: ["Wi-Fi": corp], previous: nil, port: 5000)
        XCTAssertEqual(first.saved["Wi-Fi"], corp)
        // Second `pac` (new port): Wi-Fi now shows our URL; the original stays.
        let ours = SystemProxy.Setting(url: SystemProxy.pacURL(port: 5000), enabled: true)
        let second = SystemProxy.remember(current: ["Wi-Fi": ours, "Ethernet": off], previous: first, port: 6000)
        XCTAssertEqual(second.saved["Wi-Fi"], corp)
        XCTAssertEqual(second.saved["Ethernet"], off)
        XCTAssertEqual(second.port, 6000)
        // A lost record: our URL is never taken for the user's.
        XCTAssertEqual(SystemProxy.remember(current: ["Wi-Fi": ours], previous: nil, port: 6000).saved["Wi-Fi"], off)
    }

    func testRestorePlanSkipsVanishedServices() {
        let state = SystemProxy.State(port: 5000, saved: [
            "Wi-Fi": SystemProxy.Setting(url: "http://wpad.corp/p.pac", enabled: false),
            "Ethernet": off,
            "Gone": off,
        ])
        XCTAssertEqual(SystemProxy.restoreCommands(state: state, existing: ["Wi-Fi", "Ethernet"]), [
            ["-setautoproxystate", "Ethernet", "off"],
            ["-setautoproxyurl", "Wi-Fi", "http://wpad.corp/p.pac"],
            ["-setautoproxystate", "Wi-Fi", "off"],
        ])
    }

    func testStateRoundTrip() throws {
        let state = SystemProxy.State(port: 5000, saved: ["My Wi-Fi 2": off])
        XCTAssertTrue(SystemProxy.save(state, path: statePath))
        XCTAssertEqual(SystemProxy.load(path: statePath).state, state)
        let attrs = try FileManager.default.attributesOfItem(atPath: statePath)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    // MARK: - Root side, fake networksetup

    func testPacThenOffPutsEverythingBack() {
        let corp = SystemProxy.Setting(url: "http://wpad.corp/p.pac", enabled: true)
        let fake = FakeNetworksetup([("Wi-Fi", corp), ("USB LAN 2", off), ("*Bridge", off)])
        XCTAssertTrue(SystemProxy.pac(port: 5000, statePath: statePath, using: fake).ok)
        let ours = SystemProxy.Setting(url: SystemProxy.pacURL(port: 5000), enabled: true)
        XCTAssertEqual(fake.settings["Wi-Fi"], ours)
        XCTAssertEqual(fake.settings["USB LAN 2"], ours)
        XCTAssertEqual(fake.settings["Bridge"], off, "a disabled service is left alone")
        XCTAssertEqual(SystemProxy.status(using: fake), SystemProxy.Status(active: true, port: 5000))

        // A port change keeps the original record.
        XCTAssertTrue(SystemProxy.pac(port: 6000, statePath: statePath, using: fake).ok)
        XCTAssertEqual(SystemProxy.load(path: statePath).state?.saved["Wi-Fi"], corp)

        XCTAssertTrue(SystemProxy.off(statePath: statePath, using: fake).ok)
        XCTAssertEqual(fake.settings["Wi-Fi"], corp)
        XCTAssertEqual(fake.settings["USB LAN 2"]?.enabled, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: statePath))
        XCTAssertEqual(SystemProxy.status(using: fake), SystemProxy.Status(active: false))
    }

    func testFailedSetIsRolledBack() {
        let fake = FakeNetworksetup([("Wi-Fi", off)])
        fake.refuseSet = true
        XCTAssertFalse(SystemProxy.pac(port: 5000, statePath: statePath, using: fake).ok)
        fake.refuseSet = false
        XCTAssertEqual(fake.settings["Wi-Fi"], off)
    }

    func testOffWithoutARecordStillSwitchesOurURLOff() {
        let fake = FakeNetworksetup([("Wi-Fi", SystemProxy.Setting(url: SystemProxy.pacURL(port: 5000), enabled: true)),
                                     ("Ethernet", SystemProxy.Setting(url: "http://wpad/x.pac", enabled: true))])
        XCTAssertTrue(SystemProxy.off(statePath: statePath, using: fake).ok)
        XCTAssertEqual(fake.settings["Wi-Fi"]?.enabled, false)
        XCTAssertEqual(fake.settings["Ethernet"]?.enabled, true, "someone else's PAC is not ours to switch off")
    }

    func testOffKeepsTheRecordWhenServicesCannotBeListed() {
        XCTAssertTrue(SystemProxy.save(SystemProxy.State(port: 5000, saved: ["Wi-Fi": off]), path: statePath))
        let fake = FakeNetworksetup([("Wi-Fi", off)])
        fake.listFails = true
        XCTAssertFalse(SystemProxy.off(statePath: statePath, using: fake).ok)
        XCTAssertTrue(FileManager.default.fileExists(atPath: statePath))
    }

    func testUnreadableRecordChangesNothing() throws {
        try FileManager.default.createDirectory(atPath: (statePath as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try "garbage".write(toFile: statePath, atomically: true, encoding: .utf8)
        let fake = FakeNetworksetup([("Wi-Fi", off)])
        XCTAssertFalse(SystemProxy.pac(port: 5000, statePath: statePath, using: fake).ok)
        XCTAssertFalse(SystemProxy.off(statePath: statePath, using: fake).ok)
        XCTAssertTrue(fake.calls.allSatisfy { !$0[0].hasPrefix("-set") })
        XCTAssertEqual(try String(contentsOfFile: statePath, encoding: .utf8), "garbage")
    }

    // MARK: - Older helper (§6.1)

    /// A helper before 6 does not know `proxy`: it prints usage and exits 2.
    /// The app must see a failure (not ok) and offer the update.
    func testOlderHelperRefusesProxyAndIsOfferedTheUpdate() {
        let client = HelperClient(helper: "/h") { _, _, _ in
            CommandResult(status: 2, output: "usage: menfez-route <command>")
        }
        XCTAssertFalse(client.act(["proxy", "pac", "5000"]).ok)
        XCTAssertGreaterThanOrEqual(HelperVersion.current, 6)
        XCTAssertTrue(HelperVersion.needsUpdate(installed: 5))
    }
}
