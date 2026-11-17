import XCTest
@testable import MenfezCore

/// Auto-reconnect after a reboot cleared the managed WireGuard config.
final class TunnelRecoveryTests: XCTestCase {

    func testPlanSwitchesToTheLastProfileOnlyOnConfigMissing() {
        XCTAssertEqual(TunnelRecovery.plan(code: ActionResult.configMissing,
                                           lastProfile: "nl-1", available: ["de-1", "nl-1"]),
                       .switchTo("nl-1"))
        XCTAssertEqual(TunnelRecovery.plan(code: nil, lastProfile: "nl-1", available: ["nl-1"]),
                       .none, "any other failure is reported as it is")
        XCTAssertEqual(TunnelRecovery.plan(code: "other", lastProfile: "nl-1", available: ["nl-1"]),
                       .none)
    }

    func testPlanAsksForAServerWithoutAUsableLastProfile() {
        XCTAssertEqual(TunnelRecovery.plan(code: ActionResult.configMissing,
                                           lastProfile: nil, available: ["nl-1"]),
                       .chooseServer)
        XCTAssertEqual(TunnelRecovery.plan(code: ActionResult.configMissing,
                                           lastProfile: "gone", available: ["nl-1"]),
                       .chooseServer, "a deleted profile is not retried")
    }

    func testServerRowShowsOnlyInTunnelOrHybridUpdates() {
        XCTAssertTrue(TunnelRecovery.showsServerRow(inTunnel: true, routeMode: "discord", carrying: true))
        XCTAssertTrue(TunnelRecovery.showsServerRow(inTunnel: true, routeMode: "off", carrying: false),
                      "just asked for tunnel mode, routes not up yet")
        XCTAssertTrue(TunnelRecovery.showsServerRow(inTunnel: false, routeMode: "updates", carrying: true),
                      "DPI with the updates tunnel up")
        XCTAssertFalse(TunnelRecovery.showsServerRow(inTunnel: false, routeMode: "updates", carrying: false))
        XCTAssertFalse(TunnelRecovery.showsServerRow(inTunnel: false, routeMode: "off", carrying: false),
                       "DPI or direct without a tunnel: no server row")
    }

    func testUpdatesTunnelIsNeverShownAsAUserMode() {
        XCTAssertTrue(TunnelRecovery.isUpdatesHybrid(routeMode: "updates", carrying: true))
        XCTAssertFalse(TunnelRecovery.isUpdatesHybrid(routeMode: "discord", carrying: true))
        XCTAssertFalse(TunnelRecovery.showsTunnelDetails(inTunnel: false, routeMode: "updates", carrying: true),
                       "no Mode: Discord updates row beside DPI")
        XCTAssertTrue(TunnelRecovery.showsTunnelDetails(inTunnel: true, routeMode: "discord", carrying: true))
        XCTAssertTrue(TunnelRecovery.showsTunnelDetails(inTunnel: false, routeMode: "all", carrying: true),
                      "a full tunnel left up in direct mode still shows its rows")
    }

    func testChooseServerMessageSaysAddWhenNoProfileExists() {
        XCTAssertEqual(TunnelRecovery.chooseServerMessageKey(hasProfiles: false), "no_profiles")
        XCTAssertEqual(TunnelRecovery.chooseServerMessageKey(hasProfiles: true), "choose_server")
    }

    func testCodeRoundTripsAndIsOptional() throws {
        var missing = ActionResult.failure("tunnel config missing")
        missing.code = ActionResult.configMissing
        XCTAssertEqual(JSON.decode(ActionResult.self, from: JSON.encode(missing))?.code,
                       ActionResult.configMissing)
        XCTAssertNil(JSON.decode(ActionResult.self, from: #"{"ok":false,"error":"x"}"#)?.code,
                     "an older helper without the field still decodes")
    }

    /// Records helper subcommands and answers from a script.
    private final class Script: @unchecked Sendable {
        let lock = NSLock()
        var calls: [String] = []
        let replies: [String: String]
        init(_ replies: [String: String]) { self.replies = replies }
        func client() -> HelperClient {
            HelperClient(helper: "/h") { _, args, _ in
                let sub = args.drop(while: { $0 != "/h" }).dropFirst().first ?? ""
                self.lock.lock(); self.calls.append(sub); self.lock.unlock()
                return CommandResult(status: 0, output: self.replies[sub] ?? #"{"ok":false}"#)
            }
        }
    }

    private let missingJSON = #"{"ok":false,"error":"tunnel config missing","code":"config_missing"}"#

    func testStartSwitchesOnceThenSetsTheMode() {
        let script = Script(["up": missingJSON,
                             "switch": #"{"ok":true,"mode":"discord"}"#,
                             "mode": #"{"ok":true,"mode":"all"}"#])
        let tunnel = HelperTunnel(client: script.client(), lastProfile: { "nl-1" },
                                  profileNames: { ["nl-1"] })
        let outcome = tunnel.start(mode: .all)
        XCTAssertTrue(outcome.ok)
        XCTAssertEqual(outcome.recovery, .reconnected("nl-1"))
        XCTAssertEqual(script.calls, ["up", "switch", "mode"])
    }

    func testFailedSwitchIsReportedNotRetried() {
        let script = Script(["up": missingJSON,
                             "switch": #"{"ok":false,"error":"tunnel did not come up"}"#])
        let tunnel = HelperTunnel(client: script.client(), lastProfile: { "nl-1" },
                                  profileNames: { ["nl-1"] })
        let outcome = tunnel.start(mode: .discord)
        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(outcome.message, "tunnel did not come up")
        XCTAssertEqual(script.calls, ["up", "switch"])
    }

    func testNoLastProfileAsksForAServer() {
        let script = Script(["up": missingJSON])
        let tunnel = HelperTunnel(client: script.client(), lastProfile: { nil },
                                  profileNames: { ["nl-1"] })
        let outcome = tunnel.start(mode: .discord)
        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(outcome.recovery, .chooseServer)
        XCTAssertEqual(script.calls, ["up"])
    }
}
