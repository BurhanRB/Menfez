import XCTest
@testable import MenfezCore

/// Re-adding a server after the active one was deleted: the new server is the
/// selection, and Tunnel mode starts in the saved scope, not in whatever route
/// set a server pick outside Tunnel mode left behind.
final class ScopeOnStartTests: XCTestCase {

    func testSelectionKeepsTheChosenServerElseTheOnlyOne() {
        XCTAssertEqual(TunnelRecovery.selection(lastProfile: "nl-1", available: ["de-1", "nl-1"]), "nl-1")
        XCTAssertEqual(TunnelRecovery.selection(lastProfile: nil, available: ["de-1"]), "de-1")
        XCTAssertEqual(TunnelRecovery.selection(lastProfile: "gone", available: ["de-1"]), "de-1")
        XCTAssertNil(TunnelRecovery.selection(lastProfile: nil, available: ["de-1", "nl-1"]))
        XCTAssertNil(TunnelRecovery.selection(lastProfile: nil, available: []))
    }

    func testImportedServerIsSelectedOnlyWhenNoneIs() {
        XCTAssertEqual(TunnelRecovery.selectionAfterImport("new", lastProfile: nil, available: ["new"]), "new",
                       "the owner's case: the deleted server was the only one")
        XCTAssertEqual(TunnelRecovery.selectionAfterImport("new", lastProfile: "gone", available: ["old", "new"]),
                       "new")
        XCTAssertEqual(TunnelRecovery.selectionAfterImport("new", lastProfile: "old", available: ["old", "new"]),
                       "old", "a chosen server stays chosen")
    }

    /// A tunnel that already carries routes in `routeMode`.
    final class CarryingTunnel: TunnelControl, @unchecked Sendable {
        let lock = NSLock()
        var routes: String
        var changes: [String] = []
        var starts = 0
        init(_ routes: String) { self.routes = routes }
        func isTunnelUp() -> Bool { true }
        func isCarryingTraffic() -> Bool { true }
        func routeMode() -> String { lock.lock(); defer { lock.unlock() }; return routes }
        func start(mode: Mode) -> TunnelOutcome {
            lock.lock(); starts += 1; lock.unlock()
            return TunnelOutcome(ok: true, message: "up")
        }
        func stop() -> TunnelOutcome { TunnelOutcome(ok: true, message: "down") }
        func changeMode(_ mode: Mode) -> TunnelOutcome {
            lock.lock(); changes.append(mode.rawValue); routes = mode.rawValue; lock.unlock()
            return TunnelOutcome(ok: true, message: "re-routed")
        }
    }

    final class IdleProxy: ProxyControl {
        var status: DPIStatus { DPIStatus(running: false, port: nil) }
        func enable(tunnelBusy: Bool?) -> DPIModeResult { DPIModeResult(ok: false, message: "", status: status) }
        func disable() -> DPIModeResult { DPIModeResult(ok: true, message: "", status: status) }
        func shutdown() {}
    }

    @MainActor
    func testTunnelClickReRoutesDiscordRoutesToTheSavedScope() async {
        let tunnel = CarryingTunnel("discord")
        let coordinator = ModeCoordinator(dpi: IdleProxy(), tunnel: tunnel)
        let state = await coordinator.switchTo(.tunnel, tunnelMode: .all)
        XCTAssertTrue(state.ok, state.message)
        XCTAssertEqual(state.mode, .tunnel)
        XCTAssertEqual(tunnel.changes, ["all"], "the owner's bug: Discord routes were adopted as Whole internet")
        XCTAssertEqual(tunnel.starts, 0)
    }

    @MainActor
    func testTunnelClickKeepsRoutesAlreadyInTheSavedScope() async {
        let tunnel = CarryingTunnel("all")
        let coordinator = ModeCoordinator(dpi: IdleProxy(), tunnel: tunnel)
        let state = await coordinator.switchTo(.tunnel, tunnelMode: .all)
        XCTAssertTrue(state.ok)
        XCTAssertEqual(tunnel.changes, [])
    }

    func testHelperChangeModeSendsTheScopeWithTunnelDNS() {
        let lock = NSLock()
        var seen: [String] = []
        let client = HelperClient(helper: "/h") { _, args, _ in
            lock.lock(); seen = Array(args.drop(while: { $0 != "/h" }).dropFirst()); lock.unlock()
            return CommandResult(status: 0, output: #"{"ok":true,"mode":"all"}"#)
        }
        let tunnel = HelperTunnel(client: client, interfaces: { ["utun5"] },
                                  routeState: { RouteState(mode: "discord", iface: "utun5") },
                                  dnsRouteArgs: { ["--tunnel-dns", "1.1.1.1"] })
        XCTAssertEqual(tunnel.routeMode(), "discord")
        XCTAssertTrue(tunnel.changeMode(.all).ok)
        XCTAssertEqual(seen, ["mode", "all", "--tunnel-dns", "1.1.1.1"])
    }

    // MARK: - A pick outside Tunnel mode only selects

    func testChosenRowIsTheLiveServerInTunnelElseTheSelection() {
        XCTAssertTrue(TunnelRecovery.isChosen(name: "a", active: true, inTunnel: true, selection: "b"))
        XCTAssertFalse(TunnelRecovery.isChosen(name: "b", active: false, inTunnel: true, selection: "b"))
        XCTAssertTrue(TunnelRecovery.isChosen(name: "b", active: false, inTunnel: false, selection: "b"),
                      "Direct: the pick shows although nothing runs it")
        XCTAssertFalse(TunnelRecovery.isChosen(name: "a", active: true, inTunnel: false, selection: "b"),
                       "Direct: an idle interface's server is not the selection")
    }

    func testOtherThanSelectionNeedsBothKeys() {
        let profiles = [Profile(name: "a", file: "/a", peerKey: "KA"),
                        Profile(name: "b", file: "/b", peerKey: "KB")]
        XCTAssertTrue(TunnelRecovery.runsOtherThanSelection(livePeerKey: "KA", lastProfile: "b", profiles: profiles))
        XCTAssertFalse(TunnelRecovery.runsOtherThanSelection(livePeerKey: "KB", lastProfile: "b", profiles: profiles))
        XCTAssertFalse(TunnelRecovery.runsOtherThanSelection(livePeerKey: nil, lastProfile: "b", profiles: profiles),
                       "unknown live key: keep the tunnel")
        XCTAssertFalse(TunnelRecovery.runsOtherThanSelection(livePeerKey: "KA", lastProfile: nil, profiles: profiles),
                       "no selection: nothing to switch to")
    }

    /// The idle interface `down` keeps runs server a; b was picked in Direct.
    /// The Tunnel click must start b in the asked scope, not revive a.
    func testStartOverIdleInterfaceOfAnotherServerSwitchesToTheSelection() {
        let lock = NSLock()
        var calls: [String] = []
        let replies = ["facts": #"{"tunnel":"utun5","peer_pubkey":"KA"}"#,
                       "switch": #"{"ok":true,"mode":"discord"}"#,
                       "mode": #"{"ok":true,"mode":"all"}"#]
        let client = HelperClient(helper: "/h") { _, args, _ in
            let sub = args.drop(while: { $0 != "/h" }).dropFirst().first ?? ""
            lock.lock(); calls.append(sub); lock.unlock()
            return CommandResult(status: 0, output: replies[sub] ?? #"{"ok":false}"#)
        }
        let tunnel = HelperTunnel(client: client, interfaces: { ["utun5"] },
                                  routeState: { RouteState(mode: "off", iface: "utun5") },
                                  lastProfile: { "b" }, profileNames: { ["a", "b"] },
                                  profileList: { [Profile(name: "a", file: "/a", peerKey: "KA"),
                                                  Profile(name: "b", file: "/b", peerKey: "KB")] })
        let outcome = tunnel.start(mode: .all)
        XCTAssertTrue(outcome.ok, outcome.message)
        XCTAssertEqual(outcome.recovery, .reconnected("b"))
        XCTAssertEqual(calls, ["facts", "switch", "mode"])
    }
}
