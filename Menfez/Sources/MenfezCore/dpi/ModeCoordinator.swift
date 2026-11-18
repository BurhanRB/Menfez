// ModeCoordinator.swift — exactly one way into the network, or none.
//
// WHY A STATE MACHINE AND NOT THREE BUTTONS
// -----------------------------------------
// The app has three possible states, and only one of them may be active:
//
//   direct  nothing intercepts; the OS sends traffic where it always did
//   dpi     a loopback CONNECT proxy re-frames the first TLS record
//   tunnel  the WireGuard split tunnel takes routes
//
// They are mutually exclusive for a reason that is easy to forget while
// clicking: both interception shapes claim the same traffic. A proxy while the
// tunnel is up means every CONNECT enters the tunnel and is encrypted twice,
// and the counters then describe two different networks. Before this type the
// rule lived in `DPIConflict` as a *refusal* and in the UI as an ad-hoc
// sequence of stops, which meant a failed stop could leave both running.
//
// The rule enforced here is ordering: **tear down the other side first, always,
// and only then start the target.** If the start fails there is nothing left
// running, so the state is `direct` — never a half-up pair.
//
// WHY TUNNEL WORK IS `async`
// --------------------------
// `up` runs `wg-quick`, which takes seconds; `down` rewrites the route table.
// Doing that on the main actor would freeze the window for the duration. The
// dialog with the helper is therefore hopped off the main actor inside
// `switchTo`. The proxy's start and stop wait on a bind and a port close (up to
// 3 s and 1.5 s), so `ProxyControl` is `async` too and `DPIMode` does the
// waiting on a detached task.

import Foundation

/// What, if anything, is currently intercepting traffic.
public enum RunMode: String, Codable, Sendable, CaseIterable {
    /// Nothing. The OS routes as it always did.
    case direct
    /// The in-process DPI proxy. No root, no helper, no routes.
    case dpi
    /// The WireGuard split tunnel. Needs the privileged helper.
    case tunnel
}

/// The result of one switch, as a value the UI renders without further reads.
public struct ModeState: Equatable, Sendable {
    /// What is actually running now — not what was asked for.
    public var mode: RunMode
    /// The proxy's own counters at the moment the switch finished.
    public var proxy: DPIStatus
    /// Whether the tunnel is up, as observed after the switch.
    public var tunnelUp: Bool
    /// One sentence, already assembled, including what was torn down.
    public var message: String
    /// False when the switch did not reach its target.
    public var ok: Bool
    /// The proxy came up on a different port than last time; a Discord that
    /// is already running points at the old one and must be restarted.
    public var portChanged = false
    /// The helper's own note on a successful tunnel start (e.g. the safety
    /// net is not armed). Separate from `message` so the UI can show it next
    /// to a localised sentence instead of the English one.
    public var helperNote: String?
    /// Set when `up` found no managed config (boot cleared /var/run).
    public var recovery: TunnelRecovery.Outcome?
    /// DPI mode only: true when Discord's updater now goes through the
    /// tunnel, false when that was tried and failed, nil when not tried.
    public var updatesViaTunnel: Bool?

    public init(mode: RunMode, proxy: DPIStatus, tunnelUp: Bool,
                message: String, ok: Bool) {
        self.mode = mode
        self.proxy = proxy
        self.tunnelUp = tunnelUp
        self.message = message
        self.ok = ok
    }
}

/// One privileged action's outcome, in a sentence.
public struct TunnelOutcome: Equatable, Sendable {
    public var ok: Bool
    public var message: String
    /// The helper's note, when it sent one; `message` falls back to English.
    public var note: String?
    /// Set when `up` found no managed config; see `TunnelRecovery`.
    public var recovery: TunnelRecovery.Outcome?

    public init(ok: Bool, message: String) {
        self.ok = ok
        self.message = message
    }
}

/// What to do when `up` fails because the managed config is gone.
///
/// /var/run is cleared at boot, so the root-owned WireGuard config disappears
/// with it. The owner's decision: re-create it from the last server the user
/// chose, once, instead of sending them to the picker.
public enum TunnelRecovery {
    public enum Outcome: Equatable, Sendable {
        /// `switch <name>` brought the tunnel back.
        case reconnected(String)
        /// Nothing to switch to; the user must pick a server.
        case chooseServer
    }

    public enum Plan: Equatable, Sendable {
        /// Not a missing-config failure; report it as it is.
        case none
        case switchTo(String)
        case chooseServer
    }

    /// Pure decision. `available` is the profile names on disk now, so a
    /// remembered profile the user has since deleted is not retried.
    /// `stale` means the running tunnel's server is gone from disk
    /// (`isOrphan`): `up` would re-route through it, so it is treated like a
    /// missing config and rebuilt from a profile that still exists.
    public static func plan(code: String?, lastProfile: String?,
                            available: [String], stale: Bool = false) -> Plan {
        guard code == ActionResult.configMissing || stale else { return .none }
        guard let name = lastProfile, available.contains(name) else { return .chooseServer }
        return .switchTo(name)
    }

    /// A WireGuard interface Menfez brought up whose server is no longer in
    /// the profile folder.
    ///
    /// Only our own interface counts: the route state names it, so another
    /// client's utun is never judged. With no profile left at all nothing can
    /// back it. Otherwise the live peer key decides; when it is unknown the
    /// answer is "not orphaned", because a wrong yes tears down a working
    /// tunnel. Matching by key keeps a renamed file attached to its tunnel.
    public static func isOrphan(liveIface: String?, stateIface: String?,
                                livePeerKey: String?, profiles: [Profile]) -> Bool {
        guard let liveIface, liveIface == stateIface else { return false }
        if profiles.isEmpty { return true }
        guard let key = livePeerKey, !key.isEmpty else { return false }
        return !profiles.contains { $0.peerKey == key }
    }

    /// After deleting a profile: stop our interface when it may belong to that
    /// server (the active or last-used one) or when no server is left at all.
    /// Deleting some other server leaves the tunnel alone.
    public static func shouldTearDown(deletedActive: Bool, deletedLastUsed: Bool,
                                      noProfilesLeft: Bool) -> Bool {
        deletedActive || deletedLastUsed || noProfilesLeft
    }

    /// Release an orphan only while it moves our traffic (Tunnel mode or the
    /// hybrid updates tunnel). An idle one carries nothing; starting through
    /// it is refused by `HelperTunnel` instead.
    public static func shouldRelease(liveIface: String?, state: RouteState,
                                     livePeerKey: String?, profiles: [Profile]) -> Bool {
        let carrying = state.mode != Mode.off.rawValue
            && (!state.routes.isEmpty || !state.hosts.isEmpty)
        return carrying && isOrphan(liveIface: liveIface, stateIface: state.iface,
                                    livePeerKey: livePeerKey, profiles: profiles)
    }

    /// The tunnel only fetches Discord's updates beside DPI mode. That is an
    /// internal route mode, never a mode the user picked.
    public static func isUpdatesHybrid(routeMode: String, carrying: Bool) -> Bool {
        carrying && routeMode == Mode.updates.rawValue
    }

    /// The server picker and the detail card's "Server" row: only in tunnel
    /// mode or while the hybrid updates tunnel is up. Elsewhere they would name
    /// a server nothing goes through. A tunnel start with no server still opens
    /// the server sheet (and its import) through `.chooseServer`.
    public static func showsServerRow(inTunnel: Bool, routeMode: String, carrying: Bool) -> Bool {
        inTunnel || isUpdatesHybrid(routeMode: routeMode, carrying: carrying)
    }

    /// The card's tunnel rows (mode, routes, handshake, transfer). The hybrid
    /// updates tunnel gets a one-line note instead, so "updates" never shows
    /// as a mode.
    public static func showsTunnelDetails(inTunnel: Bool, routeMode: String, carrying: Bool) -> Bool {
        inTunnel || (carrying && routeMode != Mode.updates.rawValue)
    }

    /// The UI string key for a `.chooseServer` outcome. "Cleared at restart" is
    /// only true when a profile exists; with none, the user has to add one.
    public static func chooseServerMessageKey(hasProfiles: Bool) -> String {
        hasProfiles ? "choose_server" : "no_profiles"
    }
}

/// The proxy half of the state machine, as a seam.
///
/// `DPIMode` is the real implementation and the only one production uses. This
/// exists so the state machine can be tested against a proxy that *refuses* to
/// start: that is the one transition whose failure cannot be produced with the
/// real engine (a fresh `DPIEngine` on port 0 essentially always binds), and a
/// failure path that is never executed is a failure path that is never correct.
///
/// `@MainActor` because the real `DPIMode` is: the conformance has to be able to
/// call its main-actor methods, and `switchTo` already runs on the main actor.
@MainActor
public protocol ProxyControl: AnyObject {
    var status: DPIStatus { get }
    /// `tunnelBusy` is the accurate conflict answer; nil means "ask the
    /// interface list", the conservative default.
    /// `async` so the real proxy can wait for its bind/close off the main
    /// thread. A synchronous implementation (a test fake) still conforms.
    func enable(tunnelBusy: Bool?) async -> DPIModeResult
    func disable() async -> DPIModeResult
    func shutdown()
}

extension DPIMode: ProxyControl {}

/// The tunnel half of the state machine.
///
/// A protocol rather than a direct call to `HelperClient` because the state
/// machine has to be tested without root: the tests install a fake that records
/// the call order and can fail on demand, and production installs `HelperTunnel`.
///
/// `Sendable` because `switchTo` runs the blocking `wg-quick` call on a detached
/// task, so the value crosses an actor boundary.
public protocol TunnelControl: Sendable {
    /// Read without root. Cheap enough for a click, never called on a timer.
    func isTunnelUp() -> Bool
    /// Whether the tunnel is actually carrying traffic, as opposed to merely
    /// existing.
    ///
    /// The distinction is not pedantry: `wg-quick up` leaves the utun in place
    /// after `down`, and a WireGuard app the user runs for something else leaves
    /// its own. A utun with no routes moves nothing, so reporting it as "a
    /// tunnel is open" is a measurement the app did not take — the exact failure
    /// this codebase spends most of its comments avoiding.
    ///
    /// A default implementation answers `isTunnelUp()`, which is the old,
    /// conservative behaviour: a fake with no route table to read stays usable,
    /// and a real one overrides this.
    func isCarryingTraffic() -> Bool
    /// The same answer from a local report that was just built, so the tick
    /// does not run `wg show interfaces` a second time.
    func isCarryingTraffic(seen report: Report) -> Bool
    func start(mode: Mode) -> TunnelOutcome
    func stop() -> TunnelOutcome
    /// Bring the tunnel up in `updates` mode: only these /32s. See
    /// `DiscordUpdateRoutes`.
    func startUpdates(_ routes: UpdateRoutes) -> TunnelOutcome
    /// The tunnel carries only Discord's updater, beside DPI mode.
    func isUpdatesOnly() -> Bool
}

extension TunnelControl {
    public func isCarryingTraffic() -> Bool { isTunnelUp() }
    public func isCarryingTraffic(seen report: Report) -> Bool { isCarryingTraffic() }
    public func startUpdates(_ routes: UpdateRoutes) -> TunnelOutcome {
        TunnelOutcome(ok: false, message: "no tunnel for updates")
    }
    public func isUpdatesOnly() -> Bool { false }
}

/// A tunnel that cannot exist. Used by tests and by a build with no helper.
///
/// `isTunnelUp` answers false and `start` refuses with a sentence, which means
/// the state machine's decision "the tunnel is not available" is a value rather
/// than a crash or a silent success.
public struct NoTunnel: TunnelControl {
    public init() {}
    public func isTunnelUp() -> Bool { false }
    public func start(mode: Mode) -> TunnelOutcome {
        TunnelOutcome(ok: false,
                      message: "this build has no privileged helper, so the tunnel "
                          + "cannot start; DPI mode needs no helper")
    }
    public func stop() -> TunnelOutcome {
        TunnelOutcome(ok: true, message: "no tunnel to stop")
    }
}

/// The real tunnel: the existing helper, through the existing helper path.
///
/// This adds no privileged entry point. Each call is `sudo -n <helper> up|down`,
/// which the same single sudoers line already covers; the grant is on the
/// binary, not on a list of subcommands. If the helper is not installed the
/// calls simply fail and the state machine reports `direct`.
public final class HelperTunnel: TunnelControl, @unchecked Sendable {
    private let client: HelperClient
    private let interfaces: @Sendable () -> [String]
    private let routeState: @Sendable () -> RouteState
    private let lastProfile: @Sendable () -> String?
    private let profileNames: @Sendable () -> [String]
    private let dnsRouteArgs: @Sendable () -> [String]
    private let profileList: @Sendable () -> [Profile]
    private let livePeerKey: @Sendable () -> String?

    /// `interfaces` and `routeState` are injected for the same reason every other
    /// tunnel probe is: a test must be able to answer "is a tunnel up" and "is it
    /// carrying anything" without one.
    ///
    /// `routeState` reads `/var/run/menfez/route-state.json`, which is world
    /// readable by design (it is what the unprivileged report renders), so this
    /// costs no root.
    public init(client: HelperClient,
                interfaces: @escaping @Sendable () -> [String] = {
                    RouteManager.interfaces()
                },
                routeState: @escaping @Sendable () -> RouteState = {
                    RouteStateStore.load()
                },
                lastProfile: @escaping @Sendable () -> String? = { nil },
                profileNames: @escaping @Sendable () -> [String] = {
                    WireGuardProfiles.list(liveHost: nil).map(\.name)
                },
                dnsRouteArgs: @escaping @Sendable () -> [String] = { [] },
                profileList: @escaping @Sendable () -> [Profile] = {
                    WireGuardProfiles.list(liveHost: nil)
                },
                livePeerKey: (@Sendable () -> String?)? = nil) {
        self.client = client
        self.interfaces = interfaces
        self.routeState = routeState
        self.lastProfile = lastProfile
        self.profileNames = profileNames
        self.dnsRouteArgs = dnsRouteArgs
        self.profileList = profileList
        // `wg show peers` needs root: one `facts` call, only when our own
        // interface is up at a start.
        self.livePeerKey = livePeerKey ?? { client.facts()?.peerPubkey }
    }

    /// Our interface is up but its server was deleted, renamed away or
    /// replaced. `up` reuses a live interface as it is, so starting through
    /// it would revive a server the user removed.
    func runsOrphan() -> Bool {
        guard let iface = interfaces().first, iface == routeState().iface else { return false }
        let profiles = profileList()
        return TunnelRecovery.isOrphan(liveIface: iface, stateIface: iface,
                                       livePeerKey: profiles.isEmpty ? nil : livePeerKey(),
                                       profiles: profiles)
    }

    public func isTunnelUp() -> Bool {
        !interfaces().isEmpty
    }

    /// A tunnel carries traffic when this app put routes in the table for it.
    ///
    /// `wg-quick up` leaves the utun behind after `down`, and a WireGuard client
    /// the user runs for something else leaves its own. Neither moves a packet
    /// of *our* traffic, so the mode must not claim them — see the protocol
    /// comment.
    /// `report.tunnel` is the first of `wg show interfaces` and mode, routes
    /// and hosts come from the same state file, so this is `isCarryingTraffic`
    /// without its two reads.
    public func isCarryingTraffic(seen report: Report) -> Bool {
        guard report.tunnel != nil, report.mode != Mode.off.rawValue else { return false }
        return !report.routes.isEmpty || !report.hosts.isEmpty
    }

    public func isCarryingTraffic() -> Bool {
        guard isTunnelUp() else { return false }
        let state = routeState()
        guard state.mode != Mode.off.rawValue else { return false }
        return !state.routes.isEmpty || !state.hosts.isEmpty
    }

    public func isUpdatesOnly() -> Bool {
        routeState().mode == Mode.updates.rawValue && isTunnelUp()
    }

    public func start(mode: Mode) -> TunnelOutcome {
        bringUp(mode, dns: dnsRouteArgs(), extra: [])
    }

    public func startUpdates(_ routes: UpdateRoutes) -> TunnelOutcome {
        let dns = routes.resolvers.isEmpty ? [] : ["--dns-routes", routes.resolvers.joined(separator: ",")]
        return bringUp(.updates, dns: dns, extra: ["--host-routes", routes.hosts.joined(separator: ",")])
    }

    /// `extra` goes to `up` and `mode` only; `switch` does not take it.
    private func bringUp(_ mode: Mode, dns: [String], extra: [String]) -> TunnelOutcome {
        // `act` decodes the helper's ActionResult, so a refusal carries the
        // helper's own sentence ("cannot pin the endpoint") rather than an exit
        // code. A non-JSON reply means sudo never ran, and `act` surfaces the
        // tail of sudo's message for that case.
        let stale = runsOrphan()
        let result = stale
            ? ActionResult.failure("the running tunnel's server is no longer in your list; choose a server")
            : client.act(["up", "--mode", mode.rawValue] + dns + extra)
        if result.ok {
            let note = result.notes.first
            var outcome = TunnelOutcome(ok: true,
                                        message: note ?? "tunnel up in \(mode.rawValue) mode")
            outcome.note = note
            return outcome
        }
        let failed = TunnelOutcome(ok: false,
                                   message: result.error ?? "the helper refused to bring the tunnel up")
        // Only read the profile list when the code says it is needed.
        let names = result.code == ActionResult.configMissing || stale ? profileNames() : []
        switch TunnelRecovery.plan(code: result.code, lastProfile: lastProfile(),
                                   available: names, stale: stale) {
        case .none:
            return failed
        case .chooseServer:
            var outcome = failed
            outcome.recovery = .chooseServer
            return outcome
        case .switchTo(let name):
            // Exactly one switch per start; its failure is reported, not retried.
            var switched = client.act(["switch", name] + dns)
            // `switch` keeps the stored mode, which the reboot reset; ask for ours.
            if switched.ok, switched.mode != mode.rawValue || !extra.isEmpty {
                switched = client.act(["mode", mode.rawValue] + dns + extra)
            }
            guard switched.ok else {
                return TunnelOutcome(ok: false,
                                     message: switched.error ?? "the helper could not switch to \(name)")
            }
            var outcome = TunnelOutcome(ok: true, message: "reconnected to \(name)")
            outcome.note = switched.notes.first
            outcome.recovery = .reconnected(name)
            return outcome
        }
    }

    public func stop() -> TunnelOutcome {
        let result = client.act(["down"])
        if result.ok {
            return TunnelOutcome(ok: true,
                                 message: result.notes.first ?? "tunnel stopped")
        }
        return TunnelOutcome(ok: false,
                             message: result.error ?? "the helper could not stop the tunnel")
    }
}

/// Owns which interception is live, and the order of every transition.
@MainActor
public final class ModeCoordinator {

    /// The proxy half. Exposed because the UI reads its counters directly and
    /// because the engine itself is what the tests assert against.
    ///
    /// Typed as the protocol so a test can hand over a proxy that refuses to
    /// start; production always passes a `DPIMode`, which conforms.
    public let dpi: ProxyControl

    private let tunnel: TunnelControl

    /// What DPI mode routes through the tunnel for Discord's updater, or nil
    /// when that is off (setting off, no profile, no helper, nothing
    /// resolved). Blocking; called off the main actor.
    public var updateRoutes: @Sendable () -> UpdateRoutes? = { nil }

    /// What the user asked for and the machine accepted. `.direct` until a
    /// switch succeeds, so the app never claims interception it did not start.
    public private(set) var mode: RunMode = .direct

    /// `dpi` is an optional parameter with no default instance on purpose:
    /// `DPIMode` is `@MainActor`, and a default argument is evaluated in a
    /// nonisolated context, which Swift rejects. Building it inside the init
    /// keeps the isolation where it belongs and still lets a test pass an
    /// engine it already holds.
    @MainActor
    public init(dpi: ProxyControl? = nil,
                tunnel: TunnelControl = NoTunnel()) {
        self.dpi = dpi ?? DPIMode()
        self.tunnel = tunnel
    }

    // MARK: - Observation

    public var proxy: DPIStatus { dpi.status }
    public var tunnelIsUp: Bool { tunnel.isTunnelUp() }

    /// Whether the tunnel is actually moving our traffic.
    ///
    /// Distinct from `tunnelIsUp`, which only observes the interface. This is
    /// what the UI shows and what adoption trusts.
    public var tunnelIsCarryingTraffic: Bool { tunnel.isCarryingTraffic() }

    /// The one invariant this type exists to keep: at most one interception.
    ///
    /// "Interception" means traffic is actually being carried, not merely that a
    /// utun exists. An idle interface beside a running proxy is not a conflict —
    /// it moves none of our packets — and treating it as one was the bug that
    /// made the rootless path unusable.
    ///
    /// Exposed as a value rather than asserted internally so the UI and the
    /// tests can both ask the question, and so a regression in a transition is
    /// visible as a failing assertion instead of as a mysterious double-encrypt.
    ///
    /// The one allowed pair: the proxy beside an `updates`-mode tunnel, which
    /// carries only Discord's updater and claims none of the proxy's traffic
    /// on purpose.
    public var invariantHolds: Bool {
        !(dpi.status.running && tunnel.isCarryingTraffic() && !tunnel.isUpdatesOnly())
    }

    /// Adopt whatever a previous run left behind, without changing it.
    ///
    /// Called once at launch, after the capability probe.
    ///
    /// A tunnel that this app set up yesterday is still up, and showing
    /// `.direct` while traffic goes through it would be a lie the user could not
    /// see through — every screen would say "nothing is intercepting" while the
    /// route table says otherwise. So an existing tunnel is adopted, **but only
    /// if two things hold**:
    ///
    ///  * `canManageTunnel` — the helper can be driven. Without this, a helper
    ///    that exists but has no sudo grant reports "the tunnel is up" from `wg
    ///    show interfaces` while every command to stop it fails; the mode bar
    ///    would highlight "Tunnel" with a lock icon on the same chip, and the
    ///    "Direct" button could not honour its own click.
    ///  * `tunnel.isCarryingTraffic()` — routes were actually installed. A bare
    ///    utun belongs to some other WireGuard client, or is what `wg-quick`
    ///    leaves behind after `down`.
    ///
    /// A tunnel that is up but not attributable is still *reported* by the app's
    /// status line; it is just not claimed as a mode. No teardown happens here:
    /// this is observation, not a click.
    public func adoptExistingState(canManageTunnel: Bool = true) {
        if dpi.status.running {
            mode = .dpi
        } else if canManageTunnel && tunnel.isCarryingTraffic() && !tunnel.isUpdatesOnly() {
            mode = .tunnel
        } else {
            mode = .direct
        }
    }

    /// Take down a tunnel whose server is gone (see `TunnelRecovery.isOrphan`)
    /// or is about to be deleted. Tunnel mode becomes Direct; beside DPI only
    /// the updates tunnel goes and the proxy keeps running. Queued like a
    /// switch. `ok` is false when a tunnel still carries our traffic.
    @discardableResult
    public func releaseTunnel() async -> ModeState {
        let previous = lastSwitch
        let current = Task { @MainActor () -> ModeState in
            _ = await previous?.value
            if self.mode == .tunnel {
                return await self.performSwitch(.direct, tunnelMode: .discord)
            }
            if self.tunnel.isCarryingTraffic() {
                let stopped = await self.offMain { [tunnel] in tunnel.stop() }
                return self.finish(mode: self.mode, ok: stopped.ok, message: stopped.message, [])
            }
            return self.finish(mode: self.mode, ok: true, message: "", [])
        }
        lastSwitch = current
        return await current.value
    }

    // MARK: - Switching

    /// Move to `target`, tearing the other side down first.
    ///
    /// The two phases are deliberate and separate so no reader has to reason
    /// about interleaving: phase 1 removes everything that is not the target,
    /// phase 2 starts the target. A failure in either phase leaves the machine
    /// with at most one thing running, and a start failure leaves nothing.
    ///
    /// Switches run one at a time, in call order. Every phase awaits work off
    /// the main actor, so without the queue a second click could start its
    /// teardown in the middle of the first switch's start.
    @discardableResult
    public func switchTo(_ target: RunMode,
                         tunnelMode: Mode = .discord) async -> ModeState {
        let previous = lastSwitch
        let current = Task { @MainActor in
            _ = await previous?.value
            let started = Date()
            let state = await self.performSwitch(target, tunnelMode: tunnelMode)
            // Timing behind the debugLogging flag: where a slow switch spent it.
            DebugLog.log("switch -> \(target.rawValue) ok=\(state.ok) "
                         + "\(Int(Date().timeIntervalSince(started) * 1000)) ms: \(state.message)",
                         to: "trace.log")
            return state
        }
        lastSwitch = current
        return await current.value
    }

    private var lastSwitch: Task<ModeState, Never>?

    /// Make the updates tunnel match the mode and the setting: up in DPI mode
    /// when `updateRoutes` has something, gone otherwise (a leftover from a
    /// quit app, or the setting turned off). Queued behind any switch.
    /// Returns the `updatesViaTunnel` value: nil when nothing was tried.
    @discardableResult
    public func syncUpdateTunnel() async -> Bool? {
        let previous = lastSwitch
        let current = Task { @MainActor () -> ModeState in
            let state = await previous?.value
            var result = state ?? self.finish(mode: self.mode, ok: true, message: "", [])
            result.updatesViaTunnel = await self.reconcileUpdateTunnel()
            return result
        }
        lastSwitch = current
        return await current.value.updatesViaTunnel
    }

    /// Not queued; callers hold the switch queue.
    private func reconcileUpdateTunnel() async -> Bool? {
        let updatesOnly = await offMain { [tunnel] in tunnel.isUpdatesOnly() }
        let routes = mode == .dpi ? await offMain { [updateRoutes] in updateRoutes() } : nil
        guard let routes, !routes.hosts.isEmpty else {
            if updatesOnly { _ = await offMain { [tunnel] in tunnel.stop() } }
            return nil
        }
        if updatesOnly { return true }
        // Some other tunnel carrying our traffic is not ours to replace here.
        if await offMain({ [tunnel] in tunnel.isCarryingTraffic() }) { return nil }
        let started = await offMain { [tunnel] in tunnel.startUpdates(routes) }
        DebugLog.log("updates tunnel: ok=\(started.ok) \(started.message)", to: "trace.log")
        if !started.ok {
            // Same as a failed tunnel start: no half-made utun left behind.
            _ = await offMain { [tunnel] in tunnel.stop() }
        }
        return started.ok
    }

    private func performSwitch(_ target: RunMode,
                               tunnelMode: Mode) async -> ModeState {
        var notes: [String] = []

        // Phase 1 — teardown of the non-target side.
        switch target {
        case .dpi:
            // Only a tunnel that is actually carrying our traffic has to go
            // first: a proxy started over it would send every CONNECT through
            // the tunnel and the counters would describe two different networks.
            //
            // WHY `isCarryingTraffic` AND NOT `isTunnelUp`
            // The interface check is what made the rootless path fail on a
            // machine that merely *has* a utun: another WireGuard client, or the
            // husk `wg-quick` leaves after `down`, made the switch try to stop a
            // tunnel it had no permission to touch, sudo refused, and DPI mode
            // could not be turned on at all — on exactly the machines this
            // redesign exists for. A tunnel with no routes moves none of our
            // packets, so starting the proxy beside it is safe and needs no root.
            if tunnel.isCarryingTraffic() {
                let stopped = await offMain { [tunnel] in tunnel.stop() }
                guard stopped.ok else {
                    // Our traffic is being carried and cannot be released.
                    // Starting the proxy now would create the double
                    // interception this type exists to prevent, so the switch
                    // stops here and the state keeps telling the truth about
                    // what is running.
                    return finish(mode: .tunnel, ok: false,
                                  message: "could not stop the tunnel: \(stopped.message)",
                                  notes)
                }
                notes.append("tunnel stopped")
            }
        case .tunnel:
            // The updates-only tunnel would answer "already carrying traffic"
            // below and keep only the updater's /32s.
            if tunnel.isUpdatesOnly() {
                let stopped = await offMain { [tunnel] in tunnel.stop() }
                guard stopped.ok else {
                    return finish(mode: mode, ok: false,
                                  message: "could not stop the tunnel: \(stopped.message)", notes)
                }
            }
            if dpi.status.running {
                let t = Date()
                _ = await dpi.disable()
                notes.append("proxy stopped")
                DebugLog.log("switch: proxy stop \(Int(Date().timeIntervalSince(t) * 1000)) ms",
                             to: "trace.log")
            }
        case .direct:
            if dpi.status.running {
                _ = await dpi.disable()
                notes.append("proxy stopped")
            }
            // Same rule as above: only a tunnel that carries our traffic needs
            // stopping, and only that one can block the switch. An idle utun
            // belonging to another client is not ours to tear down and not
            // something "direct" has to wait for.
            if tunnel.isCarryingTraffic() {
                let stopped = await offMain { [tunnel] in tunnel.stop() }
                guard stopped.ok else {
                    return finish(mode: .tunnel, ok: false,
                                  message: "could not stop the tunnel: \(stopped.message)",
                                  notes)
                }
                notes.append("tunnel stopped")
            }
            return finish(mode: .direct, ok: true,
                          message: "everything is off; traffic goes direct", notes)
        }

        // Phase 2 — start exactly one thing.
        switch target {
        case .dpi:
            // `tunnelBusy: false` is accurate here: phase 1 just made sure no
            // tunnel is carrying this app's traffic, and the proxy's own
            // conflict check must not re-refuse on a bare interface.
            let result = await dpi.enable(tunnelBusy: false)
            guard result.ok else {
                // Phase 1 already stopped the tunnel, so the honest exit is
                // "nothing is running". Reporting `.dpi` here because the user
                // clicked "DPI" would be the exact claim this app must not make.
                _ = await dpi.disable()
                return finish(mode: .direct, ok: false,
                              message: result.message, notes)
            }
            var state = finish(mode: .dpi, ok: true, message: result.message, notes)
            state.portChanged = result.portChanged
            state.updatesViaTunnel = await reconcileUpdateTunnel()
            return state

        case .tunnel:
            // Only skip the start when routes are already installed. An
            // interface that exists but carries nothing is exactly what
            // `wg-quick` leaves behind after `down`, and answering "already up"
            // to that click would tell the user they are covered while nothing
            // is routed. `up` is safe to re-run: it sees the existing iface and
            // only adds the missing routes.
            if tunnel.isCarryingTraffic() {
                return finish(mode: .tunnel, ok: true,
                              message: "the tunnel was already carrying traffic", notes)
            }
            let upStart = Date()
            let started = await offMain { [tunnel] in tunnel.start(mode: tunnelMode) }
            DebugLog.log("switch: helper up \(Int(Date().timeIntervalSince(upStart) * 1000)) ms, "
                         + "\(started.note ?? started.message)", to: "trace.log")
            guard started.ok else {
                // A failed `up` can leave a half-configured interface behind
                // (wg-quick creates the utun before it fails). A best-effort
                // `down` is what makes "failure means direct" true on disk and
                // not only in this object.
                _ = await offMain { [tunnel] in tunnel.stop() }
                var failed = finish(mode: .direct, ok: false,
                                    message: started.message, notes)
                failed.recovery = started.recovery
                return failed
            }
            // Defensive: nothing should have been able to start the proxy
            // during phase 1, but if it did, the target wins and the proxy goes.
            if dpi.status.running {
                _ = await dpi.disable()
                notes.append("proxy stopped")
            }
            var state = finish(mode: .tunnel, ok: true, message: started.message, notes)
            state.helperNote = started.note
            state.recovery = started.recovery
            return state

        case .direct:
            // Handled in phase 1; unreachable.
            return finish(mode: .direct, ok: true, message: "", notes)
        }
    }

    /// Quit path: close the proxy listener and every tunnel it owns.
    ///
    /// WHY THE PROXY MUST DIE WITH THE APP
    /// A listener that outlives its owner is both a leak and a hazard: Discord
    /// launched with `--proxy-server=http://127.0.0.1:<port>` would keep pointing
    /// at a port nobody is listening on, and every request would fail with
    /// "connection refused" while nothing on screen explained why. So the
    /// listener and all its deferred tunnels are cancelled synchronously here.
    ///
    /// WHY THE WIREGUARD TUNNEL IS *NOT* TORN DOWN HERE
    /// The tunnel is machine state, not app state. It has its own revert timer,
    /// its own `down` command, and its own start-up reconciliation; killing it
    /// because the window closed would be a larger action than the user asked
    /// for, and unlike the proxy it does not turn into a broken pointer when its
    /// owner exits. The app therefore leaves it alone and the next launch adopts
    /// it (see `adoptExistingState`).
    public func shutdown() {
        dpi.shutdown()
        if mode == .dpi { mode = .direct }
    }

    /// Quit: stop the proxy, and take down the updates-only tunnel, which
    /// exists only to serve DPI mode. The user's own tunnel mode is left alone.
    /// The helper call is bounded by `timeout` so quitting never hangs; a
    /// tunnel that outlives it is removed by the cleanup at next launch.
    /// Returns true when the updates tunnel was stopped within the timeout.
    @discardableResult
    public func shutdownForQuit(timeout: TimeInterval = 2) -> Bool {
        shutdown()
        final class Result: @unchecked Sendable { var stopped = false }
        let tunnel = self.tunnel
        let done = DispatchSemaphore(value: 0)
        let result = Result()
        DispatchQueue.global(qos: .userInitiated).async {
            // Written before the signal, read only after a successful wait.
            if tunnel.isUpdatesOnly() { result.stopped = tunnel.stop().ok }
            done.signal()
        }
        return done.wait(timeout: .now() + timeout) == .success && result.stopped
    }

    // MARK: - Plumbing

    /// Run a blocking tunnel call off the main actor.
    ///
    /// The closure captures the `TunnelControl` value, never `self`: a
    /// `@MainActor` object must not be reachable from a detached task, and
    /// capturing the protocol value is also what makes the seam testable.
    private func offMain<T: Sendable>(
        _ work: @escaping @Sendable () -> T
    ) async -> T {
        await Task.detached(priority: .userInitiated) { work() }.value
    }

    private func finish(mode: RunMode, ok: Bool,
                        message: String, _ notes: [String]) -> ModeState {
        self.mode = mode
        // One line for the UI: what happened, then what else changed. The port
        // is included by the caller's message, so a user who wants to point
        // another client at the proxy by hand does not have to dig.
        let parts = ([message] + notes).filter { !$0.isEmpty }
        return ModeState(mode: mode,
                         proxy: dpi.status,
                         tunnelUp: tunnel.isTunnelUp(),
                         message: parts.joined(separator: " · "),
                         ok: ok)
    }
}
