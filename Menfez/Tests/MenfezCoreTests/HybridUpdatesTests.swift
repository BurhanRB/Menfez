import XCTest
@testable import MenfezCore

/// DPI mode with Discord's updater routed through an `updates`-mode tunnel.
/// Route args and helper validation are pure; the coordinator runs against a
/// fake tunnel and a real loopback engine, as in `ModeCoordinatorTests`.
final class HybridUpdatesTests: XCTestCase {

    // MARK: - Host list to /32 args

    func testAddressesKeepPublicIPv4Once() {
        let answers = [["162.159.137.232", "162.159.138.232"],
                       ["104.18.48.115", "162.159.137.232", "10.0.0.1", "2606:4700::1", "nonsense"],
                       []]
        XCTAssertEqual(DiscordUpdateRoutes.addresses(answers),
                       ["162.159.137.232", "162.159.138.232", "104.18.48.115"])
        let many = [(1...40).map { "104.18.0.\($0)" }]
        XCTAssertEqual(DiscordUpdateRoutes.addresses(many).count, RouteManager.maxHostRoutes)
    }

    struct FakeResolver: HostResolver {
        var answers: [String: [String]]
        func resolve(_ host: String, completion: @escaping @Sendable ([String]?) -> Void) {
            completion(answers[host])
        }
    }

    func testPlanResolvesEveryUpdaterHostAndKeepsPublicResolvers() throws {
        let resolver = FakeResolver(answers: ["updates.discord.com": ["162.159.137.232"],
                                              "dl.discordapp.net": ["104.18.48.115"],
                                              "discord.com": ["162.159.137.232"]])
        let plan = try XCTUnwrap(DiscordUpdateRoutes.plan(
            resolver: resolver, systemResolvers: ["192.168.1.1", "195.175.39.39"]))
        XCTAssertEqual(Set(plan.hosts), ["162.159.137.232", "104.18.48.115"])
        XCTAssertEqual(plan.resolvers, ["195.175.39.39"])
        XCTAssertNil(DiscordUpdateRoutes.plan(resolver: FakeResolver(answers: [:]),
                                              systemResolvers: ["1.1.1.1"]),
                     "nothing resolved, nothing to route")
    }

    func testSettingDefaultsOn() {
        let store = UserDefaults(suiteName: "hybrid-\(UUID().uuidString)")!
        XCTAssertTrue(DiscordUpdateRoutes.isEnabled(store))
        store.set(false, forKey: DiscordUpdateRoutes.defaultsKey)
        XCTAssertFalse(DiscordUpdateRoutes.isEnabled(store))
    }

    // MARK: - Helper validation

    func testHostRoutesArgumentIsValidatedLikeResolvers() {
        XCTAssertEqual(RouteManager.hostRoutes(argument: "162.159.137.232,104.18.48.115"),
                       ["162.159.137.232/32", "104.18.48.115/32"])
        let sixteen = (1...16).map { "104.18.0.\($0)" }.joined(separator: ",")
        XCTAssertEqual(RouteManager.hostRoutes(argument: sixteen)?.count, 16)
        for bad in ["", "192.168.1.1", "127.0.0.1", "0.0.0.0", "1.1.1.1/24", "-net",
                    "1.1.1.1,10.0.0.1", "::1", sixteen + ",104.18.0.17"] {
            XCTAssertNil(RouteManager.hostRoutes(argument: bad), bad)
        }
        XCTAssertNil(RouteManager.dnsRoutes(argument: (1...9).map { "8.8.8.\($0)" }.joined(separator: ",")),
                     "the resolver cap is unchanged")
    }

    func testUpdatesModeRoutesOnlyHostsAndResolvers() {
        var manager = RouteManager(settle: 0, statePath: NSTemporaryDirectory() + UUID().uuidString)
        manager.hostRoutes = ["162.159.137.232/32", "104.18.48.115/32"]
        manager.dnsRoutes = ["195.175.39.39/32", "104.18.48.115/32"]
        XCTAssertEqual(manager.wanted(.updates),
                       ["162.159.137.232/32", "104.18.48.115/32", "195.175.39.39/32"])
        XCTAssertEqual(RouteManager.ranges(for: .updates), [])
        XCTAssertEqual(manager.wanted(.discord), RouteManager.discordRanges + manager.dnsRoutes.filter {
            !RouteManager.discordRanges.contains($0) }, "host routes never leak into discord mode")
        XCTAssertFalse(manager.wanted(.all).contains("162.159.137.232/32"))
    }

    /// The exact helper argv, including the reboot recovery path where
    /// `switch` gets no `--host-routes` and `mode updates` re-applies them.
    func testHelperTunnelSendsHostAndResolverRoutes() {
        final class Log: @unchecked Sendable {
            let lock = NSLock(); var argv: [[String]] = []
        }
        let log = Log()
        let missing = #"{"ok":false,"error":"tunnel config missing","code":"config_missing"}"#
        let client = HelperClient(helper: "/h") { _, args, _ in
            let sub = Array(args.drop(while: { $0 != "/h" }).dropFirst())
            log.lock.lock(); log.argv.append(sub); log.lock.unlock()
            switch sub.first {
            case "up": return CommandResult(status: 1, output: missing)
            case "switch": return CommandResult(status: 0, output: #"{"ok":true,"mode":"discord"}"#)
            default: return CommandResult(status: 0, output: #"{"ok":true,"mode":"updates"}"#)
            }
        }
        let tunnel = HelperTunnel(client: client, lastProfile: { "nl-1" }, profileNames: { ["nl-1"] })
        let outcome = tunnel.startUpdates(UpdateRoutes(hosts: ["162.159.137.232", "104.18.48.115"],
                                                       resolvers: ["195.175.39.39"]))
        XCTAssertTrue(outcome.ok)
        XCTAssertEqual(log.argv, [
            ["up", "--mode", "updates", "--dns-routes", "195.175.39.39",
             "--host-routes", "162.159.137.232,104.18.48.115"],
            ["switch", "nl-1", "--dns-routes", "195.175.39.39"],
            ["mode", "updates", "--dns-routes", "195.175.39.39",
             "--host-routes", "162.159.137.232,104.18.48.115"],
        ])
    }

    // MARK: - Coordinator setup and teardown

    final class Tunnel: TunnelControl, @unchecked Sendable {
        private let lock = NSLock()
        private var _mode: String?
        private var _calls: [String] = []
        var failUpdates = false
        var stopDelay: TimeInterval = 0

        var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
        private func record(_ c: String) { lock.lock(); _calls.append(c); lock.unlock() }

        func isTunnelUp() -> Bool { lock.lock(); defer { lock.unlock() }; return _mode != nil }
        func isCarryingTraffic() -> Bool { isTunnelUp() }
        func isUpdatesOnly() -> Bool { lock.lock(); defer { lock.unlock() }; return _mode == "updates" }
        func start(mode: Mode) -> TunnelOutcome {
            record("start \(mode.rawValue)")
            lock.lock(); _mode = mode.rawValue; lock.unlock()
            return TunnelOutcome(ok: true, message: "up")
        }
        func startUpdates(_ routes: UpdateRoutes) -> TunnelOutcome {
            record("updates \(routes.hosts.joined(separator: ","))")
            if failUpdates { return TunnelOutcome(ok: false, message: "sudo refused") }
            lock.lock(); _mode = "updates"; lock.unlock()
            return TunnelOutcome(ok: true, message: "up")
        }
        func stop() -> TunnelOutcome {
            if stopDelay > 0 { Thread.sleep(forTimeInterval: stopDelay) }
            record("stop")
            lock.lock(); _mode = nil; lock.unlock()
            return TunnelOutcome(ok: true, message: "down")
        }
    }

    private let routes = UpdateRoutes(hosts: ["162.159.137.232"], resolvers: ["195.175.39.39"])

    @MainActor
    private func coordinator(_ tunnel: Tunnel, engine: DPIEngine,
                             routes: UpdateRoutes?) -> ModeCoordinator {
        let c = ModeCoordinator(dpi: DPIMode(engine: engine, tunnelInterfaces: { [] }), tunnel: tunnel)
        c.updateRoutes = { routes }
        return c
    }

    @MainActor
    func testDPIModeBringsUpUpdatesTunnelAndDirectTearsItDown() async {
        let engine = DPIEngine()
        defer { engine.shutdown() }
        let tunnel = Tunnel()
        let c = coordinator(tunnel, engine: engine, routes: routes)

        let on = await c.switchTo(.dpi)
        XCTAssertEqual(on.mode, .dpi)
        XCTAssertEqual(on.updatesViaTunnel, true)
        XCTAssertEqual(tunnel.calls, ["updates 162.159.137.232"])
        XCTAssertTrue(c.invariantHolds, "proxy beside an updates-only tunnel is allowed")

        let off = await c.switchTo(.direct)
        XCTAssertEqual(off.mode, .direct)
        XCTAssertEqual(tunnel.calls.last, "stop")
        XCTAssertFalse(tunnel.isTunnelUp())
    }

    @MainActor
    func testLeavingDPIForTunnelReplacesUpdatesTunnel() async {
        let engine = DPIEngine()
        defer { engine.shutdown() }
        let tunnel = Tunnel()
        let c = coordinator(tunnel, engine: engine, routes: routes)
        await c.switchTo(.dpi)
        let state = await c.switchTo(.tunnel)
        XCTAssertEqual(state.mode, .tunnel)
        XCTAssertEqual(tunnel.calls, ["updates 162.159.137.232", "stop", "start discord"])
        XCTAssertFalse(engine.status().running)
    }

    @MainActor
    func testNoRoutesMeansNoTunnel() async {
        let engine = DPIEngine()
        defer { engine.shutdown() }
        let tunnel = Tunnel()
        let c = coordinator(tunnel, engine: engine, routes: nil)
        let state = await c.switchTo(.dpi)
        XCTAssertEqual(state.mode, .dpi)
        XCTAssertNil(state.updatesViaTunnel)
        XCTAssertEqual(tunnel.calls, [], "no profile or setting off: nothing changes")
    }

    @MainActor
    func testFailedUpdatesTunnelKeepsDPIAndCleansUp() async {
        let engine = DPIEngine()
        defer { engine.shutdown() }
        let tunnel = Tunnel()
        tunnel.failUpdates = true
        let c = coordinator(tunnel, engine: engine, routes: routes)
        let state = await c.switchTo(.dpi)
        XCTAssertTrue(state.ok)
        XCTAssertEqual(state.mode, .dpi)
        XCTAssertEqual(state.updatesViaTunnel, false)
        XCTAssertEqual(tunnel.calls, ["updates 162.159.137.232", "stop"])
    }

    @MainActor
    func testSyncRemovesLeftoverAndFollowsSetting() async {
        let engine = DPIEngine()
        defer { engine.shutdown() }
        let tunnel = Tunnel()
        _ = tunnel.startUpdates(routes)   // left by a quit app
        let c = coordinator(tunnel, engine: engine, routes: routes)
        c.adoptExistingState()
        XCTAssertEqual(c.mode, .direct, "an updates-only tunnel is not tunnel mode")
        let left = await c.syncUpdateTunnel()
        XCTAssertNil(left)
        XCTAssertFalse(tunnel.isTunnelUp(), "leftover removed outside DPI mode")

        await c.switchTo(.dpi)
        XCTAssertTrue(tunnel.isUpdatesOnly())
        c.updateRoutes = { nil }          // setting turned off
        await c.syncUpdateTunnel()
        XCTAssertFalse(tunnel.isTunnelUp())
        XCTAssertEqual(c.mode, .dpi)
    }

    // MARK: - Quit

    @MainActor
    func testQuitTearsDownUpdatesTunnelAndProxy() async {
        let engine = DPIEngine()
        defer { engine.shutdown() }
        let tunnel = Tunnel()
        let c = coordinator(tunnel, engine: engine, routes: routes)
        await c.switchTo(.dpi)
        XCTAssertTrue(tunnel.isUpdatesOnly())

        XCTAssertTrue(c.shutdownForQuit(timeout: 2))
        XCTAssertFalse(tunnel.isTunnelUp(), "the updates tunnel goes with the app")
        XCTAssertFalse(engine.status().running)
        XCTAssertEqual(c.mode, .direct)

        // Next launch in DPI mode brings it back with no click.
        let again = await c.switchTo(.dpi)
        XCTAssertEqual(again.updatesViaTunnel, true)
    }

    @MainActor
    func testQuitLeavesTheUsersTunnelAlone() async {
        let engine = DPIEngine()
        defer { engine.shutdown() }
        let tunnel = Tunnel()
        let c = coordinator(tunnel, engine: engine, routes: routes)
        await c.switchTo(.tunnel)
        XCTAssertFalse(c.shutdownForQuit(timeout: 2))
        XCTAssertFalse(tunnel.calls.contains("stop"), "tunnel mode is the user's, not torn down on quit")
        XCTAssertTrue(tunnel.isTunnelUp())
    }

    @MainActor
    func testQuitDoesNotWaitPastTheTimeout() async {
        let engine = DPIEngine()
        defer { engine.shutdown() }
        let tunnel = Tunnel()
        let c = coordinator(tunnel, engine: engine, routes: routes)
        await c.switchTo(.dpi)
        tunnel.stopDelay = 1.5
        let started = Date()
        XCTAssertFalse(c.shutdownForQuit(timeout: 0.2))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0, "a slow helper must not slow quit")
    }

    /// The settings.json fail-open is only for DPI users without the tunnel.
    func testTunnelCoversUpdatesSkipsFailOpen() {
        func covers(_ last: Bool?, up: Bool = false, on: Bool = false,
                    profile: Bool = false, helper: Bool = false) -> Bool {
            DiscordUpdateRoutes.tunnelCoversUpdates(lastResult: last, hybridUp: up, enabled: on,
                                                    hasProfile: profile, hasHelper: helper)
        }
        XCTAssertTrue(covers(true))
        XCTAssertFalse(covers(false, up: true, on: true, profile: true, helper: true),
                       "the switch said the tunnel failed: fail open")
        XCTAssertTrue(covers(nil, up: true))
        XCTAssertTrue(covers(nil, on: true, profile: true, helper: true))
        XCTAssertFalse(covers(nil, on: false, profile: true, helper: true))
        XCTAssertFalse(covers(nil, on: true, profile: false, helper: true))
        XCTAssertFalse(covers(nil, on: true, profile: true, helper: false))
        XCTAssertFalse(covers(nil))
    }
}
