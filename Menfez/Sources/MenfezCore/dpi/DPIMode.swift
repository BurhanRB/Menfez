// DPIMode.swift — the app-side switch for DPI mode.
//
// WHY THIS IS A SEPARATE TYPE FROM DPIEngine
// ------------------------------------------
// The engine knows nothing about WireGuard, modes, the UI or Discord. It binds
// a port and splits records. This type owns the policy the app needs around it:
//
//   * DPI mode and the tunnel are mutually exclusive (see the comment on
//     `enable`);
//   * leaving DPI mode stops the proxy;
//   * a refused start is a sentence the UI can show, not a thrown error it
//     might swallow.
//
// Keeping that split means the engine can be tested with no tunnel, no UI and
// no Discord installed — which is exactly how the tests run.

import Foundation

/// The result of asking to enter or leave DPI mode.
public struct DPIModeResult: Sendable {
    public var ok: Bool
    /// What the UI shows. Always a full sentence, never a bare code.
    public var message: String
    /// True when the refusal was caused by the tunnel being up, so the UI can
    /// offer "switch the tunnel off" instead of a dead end.
    public var blockedByTunnel: Bool
    public var status: DPIStatus
    /// True when the proxy could not get its previous port back, so a Discord
    /// already running against the old port has to be restarted.
    public var portChanged = false

    public init(ok: Bool, message: String, blockedByTunnel: Bool = false,
                status: DPIStatus) {
        self.ok = ok
        self.message = message
        self.blockedByTunnel = blockedByTunnel
        self.status = status
    }
}

@MainActor
public final class DPIMode {

    public let engine: DPIEngine

    /// Injected so the app can pass `RouteManager.interfaces()` and a test can
    /// pass a fixed list. No other seam is needed: the engine is real in both.
    ///
    /// Kept for the one caller that has nothing better: `tunnelBusy` is the
    /// accurate answer and everything in the app passes it, but a check on a
    /// bare interface list is the safe default for a caller that does not.
    private let tunnelInterfaces: () -> [String]

    /// Injected so the app can pass `NSWorkspace`-backed code, which lives in
    /// the app target (see DiscordLauncher for why the core cannot import
    /// AppKit).
    public var discordRunning: () -> Bool

    public init(engine: DPIEngine = DPIEngine(),
                tunnelInterfaces: @escaping () -> [String] = { RouteManager.interfaces() },
                discordRunning: @escaping () -> Bool = { false }) {
        self.engine = engine
        self.tunnelInterfaces = tunnelInterfaces
        self.discordRunning = discordRunning
    }

    public var status: DPIStatus { engine.status() }

    /// Enter DPI mode.
    ///
    /// REFUSES ONLY WHEN THE TUNNEL IS ACTUALLY CARRYING THIS APP'S TRAFFIC,
    /// and does not stop the tunnel itself. The conflict rule belongs to
    /// `ModeCoordinator`, which tears the tunnel down and then starts the proxy;
    /// this method is the proxy half and is also called directly by the app.
    ///
    /// WHY THE CONFLICT CHECK IS STILL HERE
    /// Callers that bypass the coordinator — a test, a future CLI — must not
    /// start a proxy over a live tunnel. With `all` routes the proxy's own
    /// upstream dial would enter the tunnel and every CONNECT would be encrypted
    /// twice, and the counters would describe two different networks.
    ///
    /// WHY IT NO LONGER KEYS ON INTERFACE PRESENCE ALONE
    /// It used to, and that made the rootless path unusable: a utun left behind
    /// by another WireGuard client, or the husk `wg-quick` leaves after `down`,
    /// made the check refuse — with a message telling the user to switch a
    /// tunnel off that they had no way to switch off and no reason to care
    /// about. `tunnelBusy` is the caller's answer to "is this tunnel carrying
    /// traffic", and for any caller that only knows about interfaces it defaults
    /// to the old, conservative behaviour.
    ///
    /// `async` because `engine.start()` blocks for up to 3 s waiting for the
    /// bind; that wait runs on a detached task so the main thread never stalls.
    public func enable(tunnelBusy: Bool? = nil) async -> DPIModeResult {
        // A caller that does not know better (a test, a future CLI) gets the
        // conservative answer from the interface list; the app passes the
        // accurate one, because only it reads the route state.
        let busy = tunnelBusy ?? !tunnelInterfaces().isEmpty
        if let refusal = DPIConflict.refusal(busy: busy) {
            return DPIModeResult(ok: false, message: refusal,
                                 blockedByTunnel: true, status: status)
        }
        let engine = self.engine
        return await Task.detached(priority: .userInitiated) {
            Self.start(engine)
        }.value
    }

    private nonisolated static func start(_ engine: DPIEngine) -> DPIModeResult {
        do {
            let started = try engine.start()
            guard let port = started.port else {
                // Cannot happen after a successful start (the engine waits for
                // a port), but a nil port here would make the Discord menu item
                // launch nothing, so it is refused rather than guessed.
                engine.stop()
                return DPIModeResult(ok: false,
                                     message: "the proxy started without a port; DPI mode is off",
                                     status: engine.status())
            }
            var result = DPIModeResult(
                ok: true,
                message: "DPI proxy listening on 127.0.0.1:\(port) · "
                    + "split at \(started.splitAt) bytes · launch Discord from the menu",
                status: started)
            result.portChanged = engine.portChanged
            return result
        } catch let error as DPIEngineError {
            // `.alreadyRunning` is not a failure from the user's point of view:
            // DPI mode is already on. Reporting the port is more useful than an
            // error, and it keeps the UI consistent with what is listening.
            if case .alreadyRunning(let port) = error {
                return DPIModeResult(
                    ok: true,
                    message: "DPI proxy was already listening on 127.0.0.1:\(port)",
                    status: engine.status())
            }
            return DPIModeResult(ok: false, message: error.description, status: engine.status())
        } catch {
            return DPIModeResult(ok: false,
                                 message: "could not start the DPI proxy: "
                                    + error.localizedDescription,
                                 status: engine.status())
        }
    }

    /// Leave DPI mode. Established tunnels get the engine's `drainTimeout` to
    /// finish, then are closed.
    /// `async` because `stop()` waits up to 1.5 s for the port to close.
    public func disable() async -> DPIModeResult {
        let engine = self.engine
        return await Task.detached(priority: .userInitiated) {
            engine.stop()
            return DPIModeResult(ok: true,
                                 message: "DPI proxy stopped",
                                 status: engine.status())
        }.value
    }

    /// Quit: close the listener *and* every tunnel.
    ///
    /// Stays synchronous: it runs from `willTerminate`, which cannot await, and
    /// the listener must be gone before the process is.
    public func shutdown() {
        engine.shutdown()
    }

    // MARK: - Discord

    /// Launch Discord through the proxy.
    ///
    /// Refuses with a specific sentence when Discord is already running, because
    /// Electron reads `--proxy-server` only at process start: launching a second
    /// copy silently does nothing to the running one, and the user would be left
    /// believing the app is covered when it is not.
    ///
    /// `async` because `open` can take up to its 15 s timeout.
    @discardableResult
    public func launchDiscord(using runner: CommandRunner = SystemRunner()) async
        -> Result<[String], DiscordLauncher.LaunchError> {
        let status = engine.status()
        guard status.running else {
            return .failure(.proxyNotRunning)
        }
        // Read on the main actor: the closure is the app's NSWorkspace check.
        let running = discordRunning()
        return await Task.detached(priority: .userInitiated) {
            DiscordLauncher.launch(port: status.port, discordRunning: running,
                                   using: runner)
        }.value
    }

    /// Whether the menu item should be enabled, and why not when it should not.
    public var discordAvailability: (enabled: Bool, reason: String?) {
        guard let port = engine.status().port, engine.status().running else {
            return (false, "start DPI mode first")
        }
        if discordRunning() {
            return (false, "quit Discord first — the proxy flag is read only at launch")
        }
        return (true, "launches Discord with --proxy-server=http://127.0.0.1:\(port)")
    }

    // MARK: - Probe

    /// Run the one-shot comparison. Never called on a timer.
    ///
    /// Deliberately not `async` on the caller's actor: `DPIProbe.run` shells out
    /// to curl twice and takes up to ~16 s in the worst case, so the UI must run
    /// it off the main actor.
    public nonisolated func probe(host: String = DPIProbe.defaultHost,
                                  using runner: CommandRunner = SystemRunner())
        -> DPIProbeOutcome {
        // Read the port once: a stop between the two attempts must not make the
        // proxied attempt dial a closed port and call the network broken.
        let port = engine.status().port
        return DPIProbe.run(port: engine.status().running ? port : nil,
                            host: host, using: runner)
    }
}
