import XCTest
@testable import MenfezCore

// ModeCoordinatorTests — the "one thing at a time" rule, exercised with a fake
// tunnel and a real engine.
//
// The engine is real because it is the half that needs no root: binding a
// loopback port is what the product does, and a fake proxy would leave the
// transition untested. The tunnel half is faked because the real one runs
// `wg-quick` against the live routing table, which a test must never do.

final class ModeCoordinatorTests: XCTestCase {

    // MARK: - Fixtures

    /// A tunnel whose every answer is scripted, and whose call order is recorded.
    ///
    /// `@unchecked Sendable` with a lock: `switchTo` runs `start`/`stop` on a
    /// detached task, so the fake is read from more than one thread. That is the
    /// same contract `HelperTunnel` has to meet, which makes the fake a fair
    /// stand-in rather than a convenience.
    final class FakeTunnel: TunnelControl, @unchecked Sendable {
        enum Call: Equatable { case isUp, start(String), stop }

        private let lock = NSLock()
        private var _up: Bool
        private var _calls: [Call] = []
        private var _startOutcome: TunnelOutcome
        private var _stopOutcome: TunnelOutcome

        /// Whether the fake reports routes as installed. Set to describe a bare
        /// utun that another client left behind.
        var carrying: Bool = true

        init(up: Bool = false) {
            _up = up
            _startOutcome = TunnelOutcome(ok: true, message: "tunnel up")
            _stopOutcome = TunnelOutcome(ok: true, message: "tunnel down")
        }

        var up: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _up }
            set { lock.lock(); _up = newValue; lock.unlock() }
        }

        var calls: [Call] {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }

        /// Calls that changed something, without the observation reads.
        var mutations: [Call] { calls.filter { $0 != .isUp } }

        func failStart(_ message: String) {
            lock.lock(); _startOutcome = TunnelOutcome(ok: false, message: message)
            lock.unlock()
        }

        func failStop(_ message: String) {
            lock.lock(); _stopOutcome = TunnelOutcome(ok: false, message: message)
            lock.unlock()
        }

        func isTunnelUp() -> Bool {
            lock.lock()
            _calls.append(.isUp)
            let value = _up
            lock.unlock()
            return value
        }

        /// Routes exist only for a live fake, never for an idle interface.
        func isCarryingTraffic() -> Bool {
            lock.lock()
            let value = _up && carrying
            lock.unlock()
            return value
        }

        func start(mode: Mode) -> TunnelOutcome {
            lock.lock(); defer { lock.unlock() }
            _calls.append(.start(mode.rawValue))
            if _startOutcome.ok { _up = true }
            return _startOutcome
        }

        func stop() -> TunnelOutcome {
            lock.lock(); defer { lock.unlock() }
            _calls.append(.stop)
            if _stopOutcome.ok { _up = false }
            return _stopOutcome
        }
    }

    private func makeEngine() -> DPIEngine { DPIEngine() }

    /// A proxy that never binds. Used only for the refusal path.
    ///
    /// It reports `running: false` always, so a coordinator that read `running`
    /// as success instead of trusting the result would fail the assertion.
    @MainActor
    final class FailingProxy: ProxyControl {
        private(set) var enableCalls = 0
        private(set) var disableCalls = 0
        private(set) var shutdownCalls = 0
        var status: DPIStatus { DPIStatus(running: false, port: nil) }

        func enable(tunnelBusy: Bool?) -> DPIModeResult {
            enableCalls += 1
            return DPIModeResult(ok: false,
                                 message: "the DPI proxy could not listen: address already in use",
                                 status: status)
        }

        func disable() -> DPIModeResult {
            disableCalls += 1
            return DPIModeResult(ok: true, message: "stopped", status: status)
        }

        func shutdown() { shutdownCalls += 1 }
    }

    // MARK: - The happy path

    /// The proxy's bind now waits off the main actor, so a second click can
    /// arrive mid-switch. It must wait its turn: "DPI then Direct" ends with
    /// nothing running, not with a proxy that finished binding after "Direct".
    @MainActor
    func testOverlappingSwitchesRunInCallOrder() async {
        let engine = makeEngine()
        defer { engine.shutdown() }
        let coordinator = ModeCoordinator(
            dpi: DPIMode(engine: engine, tunnelInterfaces: { [] }),
            tunnel: FakeTunnel())

        let first = Task { await coordinator.switchTo(.dpi) }
        let second = Task { await coordinator.switchTo(.direct) }
        let toDPI = await first.value
        let toDirect = await second.value

        XCTAssertEqual(toDPI.mode, .dpi)
        XCTAssertEqual(toDirect.mode, .direct)
        XCTAssertEqual(coordinator.mode, .direct)
        XCTAssertFalse(engine.status().running, "the later switch must win")
    }

    /// direct → dpi → tunnel → dpi, asserting after every step that exactly one
    /// thing is running (or nothing, for `direct`).
    @MainActor
    func testSwitchingLeavesExactlyOneThingRunning() async throws {
        let engine = makeEngine()
        defer { engine.shutdown() }
        let tunnel = FakeTunnel()
        let coordinator = ModeCoordinator(
            dpi: DPIMode(engine: engine, tunnelInterfaces: { [] }),
            tunnel: tunnel)
        coordinator.adoptExistingState(canManageTunnel: true)

        XCTAssertEqual(coordinator.mode, .direct)
        XCTAssertFalse(coordinator.proxy.running)
        XCTAssertFalse(tunnel.up)

        // direct → dpi
        let first = await coordinator.switchTo(.dpi)
        XCTAssertTrue(first.ok, first.message)
        XCTAssertEqual(first.mode, .dpi)
        XCTAssertTrue(coordinator.proxy.running)
        XCTAssertFalse(tunnel.up)
        XCTAssertTrue(coordinator.invariantHolds)

        // dpi → tunnel: the proxy must be gone before the tunnel arrives.
        let second = await coordinator.switchTo(.tunnel)
        XCTAssertTrue(second.ok, second.message)
        XCTAssertEqual(second.mode, .tunnel)
        XCTAssertFalse(coordinator.proxy.running,
                       "the proxy must be torn down by a switch to the tunnel")
        XCTAssertTrue(tunnel.up)
        XCTAssertTrue(coordinator.invariantHolds)
        XCTAssertTrue(second.message.contains("proxy stopped"),
                      "the message must say what was torn down: \(second.message)")

        // tunnel → dpi: and the reverse order, tunnel first then proxy.
        let third = await coordinator.switchTo(.dpi)
        XCTAssertTrue(third.ok, third.message)
        XCTAssertEqual(third.mode, .dpi)
        XCTAssertTrue(coordinator.proxy.running)
        XCTAssertFalse(tunnel.up,
                       "the tunnel must be torn down by a switch to the proxy")
        XCTAssertTrue(coordinator.invariantHolds)
        XCTAssertTrue(third.message.contains("tunnel stopped"),
                      "the message must say what was torn down: \(third.message)")

        // The proxy really is listening: a switch that only set a flag would
        // still report `running` from the engine, so ask the engine for a port.
        XCTAssertNotNil(coordinator.proxy.port)
    }

    /// Teardown always precedes start. Asserted on the recorded order, because
    /// the end state alone cannot tell "stopped then started" from "started
    /// then stopped" — and the second would briefly run both.
    @MainActor
    func testTeardownHappensBeforeStart() async {
        let engine = makeEngine()
        defer { engine.shutdown() }
        let tunnel = FakeTunnel(up: true)
        let coordinator = ModeCoordinator(
            dpi: DPIMode(engine: engine, tunnelInterfaces: { [] }),
            tunnel: tunnel)

        let result = await coordinator.switchTo(.dpi)
        XCTAssertTrue(result.ok, result.message)

        // The only mutation before the proxy existed was the tunnel stop.
        XCTAssertEqual(tunnel.mutations, [.stop])
    }

    /// Asking for the mode that is already running is a no-op, not a restart:
    /// a restart would move the proxy to a new port and invalidate a Discord
    /// that was launched against the old one.
    @MainActor
    func testSwitchToCurrentModeKeepsThePort() async {
        let engine = makeEngine()
        defer { engine.shutdown() }
        let coordinator = ModeCoordinator(
            dpi: DPIMode(engine: engine, tunnelInterfaces: { [] }),
            tunnel: FakeTunnel())

        let first = await coordinator.switchTo(.dpi)
        let port = first.proxy.port
        XCTAssertNotNil(port)

        let second = await coordinator.switchTo(.dpi)
        XCTAssertTrue(second.ok)
        XCTAssertEqual(second.proxy.port, port,
                       "a second switch must not move the listener")
    }

    // MARK: - Failure means direct

    /// THE ROOTLESS REGRESSION.
    ///
    /// A machine with a utun that is *not* carrying our traffic — another
    /// WireGuard client, or the husk `wg-quick` leaves after `down` — must not
    /// be able to block DPI mode. Before this rule, the switch tried to stop
    /// that tunnel, sudo answered "a password is required", and the one mode
    /// that needs no root could not be turned on at all.
    ///
    /// This is the state the first screenshot of the redesigned app showed, and
    /// it is the exact failure the whole change exists to remove, so it gets its
    /// own test rather than being folded into the happy path.
    @MainActor
    func testDPIStartsDespiteAnIdleTunnelItCannotStop() async {
        let engine = makeEngine()
        defer { engine.shutdown() }

        let tunnel = FakeTunnel(up: true)
        tunnel.carrying = false          // an interface, but no routes
        tunnel.failStop("sudo: a password is required")

        let coordinator = ModeCoordinator(
            dpi: DPIMode(engine: engine, tunnelInterfaces: { ["utun5"] }),
            tunnel: tunnel)

        let state = await coordinator.switchTo(.dpi)

        XCTAssertTrue(state.ok, "DPI mode must work with no root: \(state.message)")
        XCTAssertEqual(state.mode, .dpi)
        XCTAssertTrue(coordinator.proxy.running)
        XCTAssertNotNil(coordinator.proxy.port)
        // The tunnel was never asked to stop, so nothing could fail.
        XCTAssertFalse(tunnel.mutations.contains(.stop),
                       "an idle tunnel must not be torn down or even tried")
        XCTAssertTrue(coordinator.invariantHolds)
    }

    /// The same machine can also go back to `direct` without root.
    @MainActor
    func testDirectIsReachableWithAnIdleTunnelItCannotStop() async {
        let engine = makeEngine()
        defer { engine.shutdown() }

        let tunnel = FakeTunnel(up: true)
        tunnel.carrying = false
        tunnel.failStop("sudo: a password is required")

        let coordinator = ModeCoordinator(
            dpi: DPIMode(engine: engine, tunnelInterfaces: { ["utun5"] }),
            tunnel: tunnel)

        _ = await coordinator.switchTo(.dpi)
        let off = await coordinator.switchTo(.direct)

        XCTAssertTrue(off.ok, off.message)
        XCTAssertEqual(off.mode, .direct)
        XCTAssertFalse(coordinator.proxy.running)
    }

    /// A tunnel that IS carrying our traffic still blocks the switch when it
    /// cannot be stopped. The rule narrows; it does not disappear.
    @MainActor
    func testCarryingTunnelStillBlocksDPIWhenItCannotBeStopped() async {
        let engine = makeEngine()
        defer { engine.shutdown() }

        let tunnel = FakeTunnel(up: true)
        tunnel.carrying = true
        tunnel.failStop("sudo: a password is required")

        let coordinator = ModeCoordinator(
            dpi: DPIMode(engine: engine, tunnelInterfaces: { ["utun5"] }),
            tunnel: tunnel)

        let state = await coordinator.switchTo(.dpi)
        XCTAssertFalse(state.ok)
        XCTAssertFalse(coordinator.proxy.running)
        XCTAssertTrue(coordinator.invariantHolds)
    }

    /// A failed tunnel start leaves nothing running. `wg-quick`
    /// creates the interface before it fails, so the coordinator also asks for
    /// a teardown — this asserts both halves.
    @MainActor
    func testTunnelStartFailureEndsInDirect() async {
        let engine = makeEngine()
        defer { engine.shutdown() }
        let tunnel = FakeTunnel()
        tunnel.failStart("could not pin the endpoint")
        let coordinator = ModeCoordinator(
            dpi: DPIMode(engine: engine, tunnelInterfaces: { [] }),
            tunnel: tunnel)

        let result = await coordinator.switchTo(.tunnel)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.mode, .direct,
                       "a failed start must not claim the tunnel is up")
        XCTAssertFalse(coordinator.proxy.running,
                       "the proxy must not be left running behind a failed switch")
        XCTAssertFalse(tunnel.up)
        XCTAssertTrue(coordinator.invariantHolds)
        XCTAssertTrue(result.message.contains("could not pin the endpoint"),
                      "the helper's own sentence must survive: \(result.message)")
        // The best-effort teardown must have been attempted.
        XCTAssertTrue(tunnel.mutations.contains(.stop))
    }

    /// Switching to DPI while the tunnel refuses to stop must not start the
    /// proxy. Both running is the one state this type exists to prevent, so the
    /// switch has to fail instead — and the reported mode must stay `tunnel`,
    /// because that is what is still intercepting.
    @MainActor
    func testDPIStartIsRefusedWhenTunnelWillNotStop() async {
        let engine = makeEngine()
        defer { engine.shutdown() }
        let tunnel = FakeTunnel(up: true)
        tunnel.failStop("the tunnel is busy")
        let coordinator = ModeCoordinator(
            dpi: DPIMode(engine: engine, tunnelInterfaces: { ["utun5"] }),
            tunnel: tunnel)

        let result = await coordinator.switchTo(.dpi)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.mode, .tunnel)
        XCTAssertFalse(coordinator.proxy.running,
                       "starting the proxy over a live tunnel would double-encrypt")
        XCTAssertTrue(coordinator.invariantHolds)
    }

    /// A proxy that refuses to bind leaves the tunnel stopped and the state
    /// `direct` — the switch does not pretend the proxy came up.
    ///
    /// The real engine binds port 0 and essentially always succeeds, so the
    /// refusal is injected: this is the one failure path that a test can only
    /// reach through the `ProxyControl` seam.
    @MainActor
    func testDPIFailureEndsInDirectAfterStoppingTheTunnel() async {
        let tunnel = FakeTunnel(up: true)
        let proxy = FailingProxy()
        let coordinator = ModeCoordinator(dpi: proxy, tunnel: tunnel)

        let result = await coordinator.switchTo(.dpi)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.mode, .direct,
                       "a refused proxy must not report DPI mode")
        XCTAssertFalse(coordinator.proxy.running)
        XCTAssertFalse(tunnel.up, "the tunnel was stopped first and stays stopped")
        XCTAssertTrue(coordinator.invariantHolds)
        XCTAssertTrue(result.message.contains("could not listen"),
                      "the engine's own sentence must survive: \(result.message)")
        XCTAssertTrue(result.message.contains("tunnel stopped"),
                      "the message must say what was torn down: \(result.message)")
    }

    /// Asking to start the tunnel when an idle interface already exists must
    /// still start it, not answer "already up".
    ///
    /// The husk case: `wg-quick` leaves the utun after `down`. Reporting "up"
    /// there would tell the user they were covered while nothing was routed.
    @MainActor
    func testTunnelStartIsNotSkippedForAnIdleInterface() async {
        let engine = makeEngine()
        defer { engine.shutdown() }
        let tunnel = FakeTunnel(up: true)
        tunnel.carrying = false
        let coordinator = ModeCoordinator(
            dpi: DPIMode(engine: engine, tunnelInterfaces: { ["utun5"] }),
            tunnel: tunnel)

        let state = await coordinator.switchTo(.tunnel)
        XCTAssertTrue(state.ok, state.message)
        XCTAssertTrue(tunnel.mutations.contains(.start("discord")),
                      "an idle interface must not be mistaken for a running tunnel")
        XCTAssertEqual(state.mode, .tunnel)
    }

    /// And a tunnel that is genuinely carrying traffic is not restarted: the
    /// routes are already installed and re-running `up` would churn them.
    @MainActor
    func testTunnelStartIsSkippedWhenAlreadyCarrying() async {
        let engine = makeEngine()
        defer { engine.shutdown() }
        let tunnel = FakeTunnel(up: true)
        tunnel.carrying = true
        let coordinator = ModeCoordinator(
            dpi: DPIMode(engine: engine, tunnelInterfaces: { ["utun5"] }),
            tunnel: tunnel)

        let state = await coordinator.switchTo(.tunnel)
        XCTAssertTrue(state.ok, state.message)
        XCTAssertFalse(tunnel.mutations.contains { if case .start = $0 { return true }; return false },
                       "a carrying tunnel must not be started again")
    }

    // MARK: - Switching to direct

    /// Direct is the panic button: both halves go down.
    @MainActor
    func testSwitchToDirectStopsEverything() async {
        let engine = makeEngine()
        defer { engine.shutdown() }
        let tunnel = FakeTunnel()
        let coordinator = ModeCoordinator(
            dpi: DPIMode(engine: engine, tunnelInterfaces: { [] }),
            tunnel: tunnel)

        _ = await coordinator.switchTo(.dpi)
        XCTAssertTrue(coordinator.proxy.running)

        let off = await coordinator.switchTo(.direct)
        XCTAssertTrue(off.ok)
        XCTAssertEqual(off.mode, .direct)
        XCTAssertFalse(coordinator.proxy.running)
        XCTAssertFalse(tunnel.up)
        XCTAssertTrue(coordinator.invariantHolds)
    }

    // MARK: - Adoption

    /// A tunnel left up by a previous launch must be adopted, not ignored.
    /// Reporting `direct` while the route table carries a tunnel would make
    /// every screen lie.
    @MainActor
    func testAdoptExistingTunnel() {
        let engine = makeEngine()
        defer { engine.shutdown() }
        let coordinator = ModeCoordinator(
            dpi: DPIMode(engine: engine, tunnelInterfaces: { ["utun5"] }),
            tunnel: FakeTunnel(up: true))

        coordinator.adoptExistingState(canManageTunnel: true)
        XCTAssertEqual(coordinator.mode, .tunnel)
    }

    /// A tunnel that is up but cannot be managed must NOT be adopted as this
    /// app's mode.
    ///
    /// The bug this pins: `wg show interfaces` lists a utun whether or not the
    /// helper has a sudo grant. Adopting on that alone put the mode bar on
    /// "Tunnel" while the same chip was disabled and locked, and the "Direct"
    /// button could not honour its click because every teardown failed. The
    /// tunnel is real and is still reported in the status line — it is just not
    /// attributed to a mode this app cannot control.
    @MainActor
    func testAdoptDoesNotClaimATunnelItCannotManage() {
        let engine = makeEngine()
        defer { engine.shutdown() }
        let coordinator = ModeCoordinator(
            dpi: DPIMode(engine: engine, tunnelInterfaces: { ["utun5"] }),
            tunnel: FakeTunnel(up: true))

        coordinator.adoptExistingState(canManageTunnel: false)
        XCTAssertEqual(coordinator.mode, .direct)
        // Still honest about the machine: the tunnel exists.
        XCTAssertTrue(coordinator.tunnelIsUp)
    }

    /// A bare utun that carries none of our traffic is not adopted either.
    ///
    /// `wg-quick up` leaves the interface behind after `down`, and another
    /// WireGuard client leaves its own. Either one makes `wg show interfaces`
    /// non-empty while nothing is intercepted, so interface presence alone is
    /// not evidence — the route state is.
    @MainActor
    func testAdoptIgnoresAnIdleInterface() {
        let engine = makeEngine()
        defer { engine.shutdown() }
        let tunnel = FakeTunnel(up: true)
        tunnel.carrying = false
        let coordinator = ModeCoordinator(
            dpi: DPIMode(engine: engine, tunnelInterfaces: { ["utun5"] }),
            tunnel: tunnel)

        coordinator.adoptExistingState(canManageTunnel: true)
        XCTAssertEqual(coordinator.mode, .direct,
                       "an interface with no routes is not interception")
    }

    /// The real `HelperTunnel` reads the route state, not just the interface.
    ///
    /// This is the bug that shipped in the first screenshot: `utun5` existed
    /// with `mode: off` and no routes, and the status line claimed a tunnel was
    /// open. The three cases below are the whole rule.
    func testHelperTunnelCarriesTrafficOnlyWhenRoutesExist() {
        let client = HelperClient(helper: "/nonexistent") { _, _, _ in
            CommandResult(status: 0, output: "")
        }

        // Interface, no routes, mode off: not carrying.
        let idle = HelperTunnel(client: client,
                                interfaces: { ["utun5"] },
                                routeState: { RouteState.empty })
        XCTAssertTrue(idle.isTunnelUp())
        XCTAssertFalse(idle.isCarryingTraffic())

        // Interface with routes and a non-off mode: carrying.
        let live = HelperTunnel(client: client,
                                interfaces: { ["utun5"] },
                                routeState: {
                                    RouteState(mode: "discord",
                                               iface: "utun5",
                                               routes: ["162.159.128.0/19"],
                                               hosts: ["162.159.130.1"])
                                })
        XCTAssertTrue(live.isCarryingTraffic())

        // No interface at all: not carrying, whatever the state file says.
        let gone = HelperTunnel(client: client,
                                interfaces: { [] },
                                routeState: {
                                    RouteState(mode: "discord",
                                               routes: ["162.159.128.0/19"])
                                })
        XCTAssertFalse(gone.isCarryingTraffic())

        // Interface and routes, but the mode was turned off: the routes are
        // leftovers, not interception.
        let off = HelperTunnel(client: client,
                               interfaces: { ["utun5"] },
                               routeState: {
                                   RouteState(mode: "off",
                                              routes: ["162.159.128.0/19"])
                               })
        XCTAssertFalse(off.isCarryingTraffic())
    }

    /// A proxy that is already listening is adopted too. This is the case that
    /// matters after a crash-free relaunch of the UI while the engine, which is
    /// in-process, would have died with the old one — so the test starts it
    /// explicitly to describe the state.
    @MainActor
    func testAdoptExistingProxy() throws {
        let engine = makeEngine()
        defer { engine.shutdown() }
        try engine.start()
        let coordinator = ModeCoordinator(
            dpi: DPIMode(engine: engine, tunnelInterfaces: { [] }),
            tunnel: FakeTunnel())

        coordinator.adoptExistingState(canManageTunnel: true)
        XCTAssertEqual(coordinator.mode, .dpi)
    }

    // MARK: - Quit

    /// The quit path closes the listener and every tunnel it owns.
    ///
    /// This is the property that makes a proxy safe to ship: a listener that
    /// outlives its owner leaves Discord pointed at a dead port, and every
    /// request fails with "connection refused" while nothing explains why.
    @MainActor
    func testShutdownClosesTheListener() throws {
        let engine = makeEngine()
        let coordinator = ModeCoordinator(
            dpi: DPIMode(engine: engine, tunnelInterfaces: { [] }),
            tunnel: FakeTunnel())

        let state = try engine.start()
        let port = try XCTUnwrap(state.port)
        coordinator.adoptExistingState(canManageTunnel: true)
        XCTAssertEqual(coordinator.mode, .dpi)

        // The shutdown path the app calls from `willTerminateNotification`.
        coordinator.shutdown()

        XCTAssertFalse(engine.status().running, "the listener must be closed")
        XCTAssertNil(engine.status().port)
        XCTAssertEqual(coordinator.mode, .direct)

        // And the port really is closed, not merely forgotten: retried briefly
        // because the kernel can take a moment to stop accepting after cancel().
        var refused = false
        for _ in 0..<20 {
            do {
                let client = try RawClient(port: port)
                client.close()
            } catch {
                refused = true
                break
            }
            usleep(50_000)
        }
        XCTAssertTrue(refused, "port \(port) still accepted a connection after shutdown")
    }

    /// Shutdown with a live tunnel must not tear the tunnel down: it is machine
    /// state with its own revert timer, and killing it because a window closed
    /// is a larger action than the user asked for.
    @MainActor
    func testShutdownLeavesTheTunnelAlone() async {
        let engine = makeEngine()
        defer { engine.shutdown() }
        let tunnel = FakeTunnel()
        let coordinator = ModeCoordinator(
            dpi: DPIMode(engine: engine, tunnelInterfaces: { [] }),
            tunnel: tunnel)

        _ = await coordinator.switchTo(.tunnel)
        XCTAssertTrue(tunnel.up)
        let before = tunnel.mutations.count

        coordinator.shutdown()
        XCTAssertTrue(tunnel.up, "quitting the app must not stop the tunnel")
        XCTAssertEqual(tunnel.mutations.count, before,
                       "shutdown must not issue a tunnel command")
    }

    /// Shutdown is idempotent: a second termination notification (or a test)
    /// must not throw or double-free.
    @MainActor
    func testShutdownIsIdempotent() throws {
        let engine = makeEngine()
        let coordinator = ModeCoordinator(
            dpi: DPIMode(engine: engine, tunnelInterfaces: { [] }),
            tunnel: FakeTunnel())

        try engine.start()
        coordinator.shutdown()
        coordinator.shutdown()
        XCTAssertFalse(engine.status().running)
    }
}
