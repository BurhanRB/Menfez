// DPIEngine.swift — the local CONNECT proxy that performs the split.
//
// SHAPE
// -----
//   Discord → this listener (127.0.0.1, last run's port, else ephemeral) → TCP → Discord edge
//
// One CONNECT tunnel per client connection. The first bytes the client sends
// after the CONNECT are examined only to decide whether the stream starts with
// a TLS handshake record; if it does and the record is longer than
// `TLSRecordReframer.firstRecordPayloadLimit`, the first 5 + 40 bytes are
// re-emitted as `record1(40) ‖ record2(rest)` and everything after is a
// byte-for-byte pipe. See TLSRecordReframer.swift for why that is the bypass.
//
// BINDING, AND WHY IT IS LOOPBACK-ONLY
// ------------------------------------
// The listener is created with `requiredLocalEndpoint = 127.0.0.1:0`. Binding
// the wildcard address would make this an open relay: any machine on the same
// Wi-Fi could CONNECT through it and every connection would leave from this
// Mac's address, with no authentication anywhere in the CONNECT path (the
// spike's proxy had none either). The bind address is therefore the only thing
// standing between the network and an open relay. It is set in exactly one
// place, `makeParameters`, and a test asserts that a non-loopback address
// cannot reach it.
//
// BOUNDED RESOURCES
// -----------------
//   * connections: `maxConnections` (default 128), enforced at accept time,
//     before any buffer is allocated for the connection.
//   * CONNECT header: 8 KiB, enforced while reading (ConnectHeadReader), so a
//     10 MB header line is refused at 8 KiB instead of being buffered.
//   * per direction: one `chunkBytes` (16 KiB) buffer at a time — the next read
//     is issued only after the previous send completes, which hands flow
//     control back to TCP instead of growing a queue.
//   * the first-record splitter holds at most 45 bytes.
// So a served connection peaks at roughly 8 KiB of head (once, before the
// tunnel exists) plus 2 × 16 KiB in flight, and the whole engine at
// 128 × ~40 KiB ≈ 5 MiB. None of it grows with how long a connection lives or
// how much it transfers.
//
// THREADING
// ---------
// Every Network.framework callback is delivered on one serial queue (`netQueue`),
// so the tunnel state machine needs no locks. Counters, the listener handle and
// the last activity timestamp are shared with `start`/`stop`/`status` and are
// guarded by `stateLock`. `start` deliberately does not run on `netQueue`: it
// waits for the listener to become ready, and waiting on the queue that
// delivers readiness would never return.
//
// NO CRASHES FROM CLIENT BYTES
// ----------------------------
// Every parse failure is a value (`ConnectParseError`), every socket result is
// optional, and the connection path contains no force-unwrap, no `try!` and no
// `fatalError`. A malformed ClientHello is forwarded untouched; this proxy
// never looks below the record header.

import Foundation
import Network

public enum DPIEngineError: Error, Equatable, CustomStringConvertible {
    case alreadyRunning(port: Int)
    case notRunning
    case conflict(String)
    case listenerFailed(String)

    public var description: String {
        switch self {
        case .alreadyRunning(let port):
            return "the DPI proxy is already listening on 127.0.0.1:\(port)"
        case .notRunning:
            return "the DPI proxy is not running"
        case .conflict(let message):
            return message
        case .listenerFailed(let why):
            return "the DPI proxy could not listen: \(why)"
        }
    }
}

public final class DPIEngine: @unchecked Sendable {

    // MARK: - Configuration

    public struct Configuration: Sendable {
        /// How long a CONNECT tunnel may take to reach the origin.
        ///
        /// 10 s, the same value the spike's proxy used. A DNS lookup plus a TCP
        /// handshake to a Cloudflare edge takes well under a second; 10 s
        /// survives a slow tether and is short enough that a dead origin does
        /// not hold a connection slot for a noticeable time.
        public var connectTimeout: TimeInterval = 10

        /// How long a client may take to send its CONNECT head.
        ///
        /// 10 s. The client sends this before any server response, so anything
        /// slower is not a client about to use the tunnel. This is also the
        /// only thing bounding a connection that opens and sends nothing.
        public var headerTimeout: TimeInterval = 10

        /// Idle timeout once the tunnel is established.
        ///
        /// 120 s. Discord's gateway heartbeats roughly every 41 s, so a 60 s
        /// timeout would sit only 19 s from killing a healthy idle websocket,
        /// and a backgrounded or throttled Electron app slips past that
        /// easily. 120 s tolerates two missed heartbeats while still making it
        /// impossible for a hung connection to hold a slot forever.
        public var idleTimeout: TimeInterval = 120

        /// Hard cap on simultaneously served connections.
        ///
        /// 128. One Discord client holds a handful of TCP flows (gateway, CDN,
        /// media, a few API calls) — typically under 20 — so 128 is several
        /// instances' worth of headroom while keeping the worst-case buffer
        /// footprint near 5 MiB. It is also below the point where one serial
        /// callback queue becomes the bottleneck for this traffic shape, and
        /// below the kernel's listen backlog, so an overflow is refused here
        /// with a readable 503 instead of turning into a silent SYN drop.
        public var maxConnections: Int = 128

        /// Bytes per read.
        ///
        /// 16 KiB: a TLS record carries at most 16 KiB of payload plus a 5-byte
        /// header and a 16-byte AEAD tag, so a whole record usually arrives in
        /// one read and the split costs no extra round trip.
        public var chunkBytes: Int = 16 * 1024

        /// Size of the CONNECT head. 8 KiB is the large-header limit production
        /// HTTP servers use; a bigger head would be refused by the origin
        /// anyway, so buffering one only helps whoever sent it.
        public var maxHeaderBytes: Int = ConnectRequestParser.maxHeaderBytes

        /// How long `stop()` lets established tunnels finish before closing them.
        ///
        /// 5 s: long enough for an in-flight API call or upload chunk, short
        /// enough that leaving DPI mode means Discord stops using the proxy
        /// now. Without it, gateway heartbeats keep a tunnel under the idle
        /// timeout forever and traffic keeps flowing while the UI says off.
        public var drainTimeout: TimeInterval = 5

        /// Refuse targets other than port 443 on a public host (see
        /// `ConnectRequest.policyRefusal`). Off only in tests, whose fake
        /// origins live on loopback ephemeral ports.
        var restrictTargets = true

        /// First TLS record payload size; see `TLSRecordReframer`. Overridden
        /// by the `dpi.firstRecordPayloadLimit` default when it is in range.
        public var firstRecordPayloadLimit = TLSRecordReframer.firstRecordPayloadLimit

        /// Resolves CONNECT hostnames before dialling (see DoHResolver.swift).
        /// nil, or a failed lookup, leaves the name to system DNS.
        public var resolver: HostResolver? = DoHResolver.shared

        public init() {}
    }

    // MARK: - State

    private var config: Configuration
    private let stateLock = NSLock()
    private let netQueue = DispatchQueue(label: "menfez.dpi.net")
    private let timerQueue = DispatchQueue(label: "menfez.dpi.timer")

    private var listener: NWListener?
    private var startDate: Date?

    // `reframed`, `passthrough`, `rejected` and `overCapacity` are cumulative
    // for the life of this object rather than per run: a tunnel that outlives
    // a stop/start pair still belongs to a real observation. `connections` is
    // the number open now (`tunnels.count`); `uptimeS` describes the current
    // run and `running` says whether a listener is up.
    private var connections = 0
    private var reframed = 0
    private var passthrough = 0
    private var rejected = 0
    private var overCapacity = 0
    private var lastError: String?
    private var tunnels: [ObjectIdentifier: Tunnel] = [:]
    private var portChangedFlag = false
    /// True while `start` holds a ready listener it has not assigned yet, so
    /// a connection accepted in that window is served, not dropped.
    private var starting = false

    /// Where the last bound port is remembered. nil (the default, and what the
    /// tests use) means every start takes an ephemeral port.
    private let portStore: UserDefaults?
    public static let portDefaultsKey = "dpi.lastPort"

    public init(configuration: Configuration = Configuration(),
                portStore: UserDefaults? = nil) {
        self.config = configuration
        self.portStore = portStore
        // Lets a network whose DPI needs a different cut be retuned with
        // `defaults write` instead of a rebuild. Out of range keeps the config.
        if let store = portStore, store.object(forKey: Self.splitDefaultsKey) != nil {
            let value = store.integer(forKey: Self.splitDefaultsKey)
            if Self.splitRange.contains(value) { config.firstRecordPayloadLimit = value }
        }
        if !Self.splitRange.contains(config.firstRecordPayloadLimit) {
            config.firstRecordPayloadLimit = TLSRecordReframer.firstRecordPayloadLimit
        }
    }

    public static let splitDefaultsKey = "dpi.firstRecordPayloadLimit"
    /// 200 keeps the splitter's buffer tiny and the cut inside any ClientHello.
    public static let splitRange = 1...200

    /// The split point in force, for logging and the UI.
    public var splitAt: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return config.firstRecordPayloadLimit
    }

    /// Change the split for connections accepted from now on (a length found
    /// for this network, 1.0.8). Out of range is ignored; open ones keep theirs.
    public func setSplit(_ value: Int) {
        guard Self.splitRange.contains(value) else { return }
        stateLock.lock()
        config.firstRecordPayloadLimit = value
        stateLock.unlock()
    }

    // MARK: - Lifecycle

    /// Bind the loopback listener and return the status that names its port.
    ///
    /// A second start is **refused** with `.alreadyRunning(port:)`, not ignored
    /// and not given a second port: two listeners would mean one port the UI is
    /// not showing, and a "start" that returns success while doing nothing is
    /// exactly the kind of claim this engine is built not to make.
    @discardableResult
    public func start() throws -> DPIStatus {
        stateLock.lock()
        let existingPort = listener?.port.map { Int($0.rawValue) }
        let alreadyListening = listener != nil
        stateLock.unlock()

        if alreadyListening {
            throw DPIEngineError.alreadyRunning(port: existingPort ?? 0)
        }

        // Discord reads `--proxy-server` only at launch, so a copy started
        // against the previous run's port keeps using it. Rebinding that port
        // keeps it connected across off/on, mode switches and app restarts.
        // The probe skips a port someone else now holds: reuse is on, and
        // sharing a port with a stranger's listener is not a fallback.
        stateLock.lock()
        starting = true
        stateLock.unlock()
        defer { stateLock.lock(); starting = false; stateLock.unlock() }

        let preferred = portStore.map { $0.integer(forKey: Self.portDefaultsKey) } ?? 0
        let listener: NWListener
        let failure: FailureBox
        if preferred > 0, preferred <= 65535,
           let port = NWEndpoint.Port(rawValue: UInt16(preferred)),
           !PortProbe.isListening(port: preferred),
           let bound = try? bind(port: port, recordFailure: false) {
            (listener, failure) = bound
        } else {
            (listener, failure) = try bind(port: .any, recordFailure: true)
        }
        let boundPort = Int(listener.port?.rawValue ?? 0)

        stateLock.lock()
        if self.listener != nil {
            // Another start won while this one waited. Refuse rather than
            // replace: the winner's port is the one the UI was told about.
            let port = Int(self.listener?.port?.rawValue ?? 0)
            stateLock.unlock()
            listener.cancel()
            throw DPIEngineError.alreadyRunning(port: port)
        }
        if let message = failure.value {
            // Died between ready and here; `listenerStopped` ignored it
            // because it was not yet the current listener.
            stateLock.unlock()
            listener.cancel()
            throw DPIEngineError.listenerFailed(message)
        }
        self.listener = listener
        self.startDate = Date()
        portChangedFlag = preferred > 0 && boundPort != preferred
        let status = snapshotLocked()
        stateLock.unlock()
        portStore?.set(boundPort, forKey: Self.portDefaultsKey)
        return status
    }

    /// True when the last `start` could not rebind the port the previous run
    /// used, so a Discord launched against that port must be restarted.
    public var portChanged: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return portChangedFlag
    }

    /// Open a loopback listener on `port` and block until it is ready.
    private func bind(port: NWEndpoint.Port,
                      recordFailure: Bool) throws -> (NWListener, FailureBox) {
        let listener: NWListener
        do {
            listener = try NWListener(using: Self.makeParameters(port: port))
        } catch {
            throw DPIEngineError.listenerFailed(error.localizedDescription)
        }

        // Signalled by the state handler, which runs on `netQueue` — a queue
        // that is free while this thread waits, unlike a lock-held wait.
        let ready = DispatchSemaphore(value: 0)
        let failure = FailureBox()

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready:
                ready.signal()
            case .cancelled:
                if let listener { self?.listenerStopped(listener, why: "listener cancelled") }
            case .failed(let error):
                // A failed try on the remembered port is retried on an
                // ephemeral one, so it is not the user's last error.
                if recordFailure {
                    self?.record(error: "listener stopped: \(error.localizedDescription)")
                }
                failure.set(error.localizedDescription)
                ready.signal()
                if let listener {
                    self?.listenerStopped(listener,
                                          why: "listener stopped: \(error.localizedDescription)")
                }
            default:
                // `.waiting` is not a verdict; the timeout below covers it.
                break
            }
        }
        listener.start(queue: netQueue)

        // 3 s is generous for a loopback bind. Waiting matters because the port
        // in the returned status is the one Discord gets launched with;
        // returning nil there would make the menu item unusable on the first
        // click.
        if ready.wait(timeout: .now() + 3) == .timedOut {
            listener.cancel()
            throw DPIEngineError.listenerFailed(
                "the loopback listener did not become ready within 3 s")
        }
        if let message = failure.value {
            listener.cancel()
            throw DPIEngineError.listenerFailed(message)
        }
        return (listener, failure)
    }

    /// The listener died after `start` returned (network stack reset, sleep).
    ///
    /// Clearing it makes `status()` say stopped instead of "running" on a
    /// dead port. No automatic rebind: the user's next start reuses the
    /// remembered port anyway, and a silent restart loop could hide a real
    /// fault. Our own `stop`/`shutdown` clear `listener` before cancelling,
    /// so the identity check makes this a no-op for them.
    /// The live listener, for tests that need to kill it from outside.
    var currentListener: NWListener? {
        stateLock.lock(); defer { stateLock.unlock() }
        return listener
    }

    func listenerStopped(_ dead: NWListener, why: String) {
        stateLock.lock()
        guard listener === dead else { stateLock.unlock(); return }
        listener = nil
        startDate = nil
        lastError = why
        stateLock.unlock()
        dead.cancel()
    }

    /// Stop listening. Established tunnels get `drainTimeout` to finish and
    /// are then closed, which is what makes leaving DPI mode not kill an
    /// in-flight request the moment the user clicks — and still mean "off".
    public func stop() {
        stateLock.lock()
        let victim = listener
        let victimPort = victim?.port
        listener = nil
        startDate = nil
        let draining = Array(tunnels.values)
        stateLock.unlock()

        // Only the tunnels open now: a start within the window gets its own.
        // Cancelling one that already finished is a no-op.
        if !draining.isEmpty {
            timerQueue.asyncAfter(deadline: .now() + config.drainTimeout) {
                for tunnel in draining { tunnel.cancel() }
            }
        }

        // `NWListener.cancel()` is asynchronous: it returns before the socket
        // is closed. A caller that stops and immediately starts again got
        // "address already in use" on the old port, and `status()` said stopped
        // while the port still accepted. Waiting for the port to be free is the
        // difference between "the button turned it off" and "the button appears
        // to do nothing the second time".
        victim?.cancel()
        if let port = victimPort.map({ Int($0.rawValue) }) {
            waitForPortToClose(port, timeout: 1.5)
        }
    }

    /// Block until nothing accepts on `port`, or the deadline passes.
    ///
    /// Polls rather than using a completion handler because `cancel()` has no
    /// "closed" callback; the socket is gone when a connect fails.
    private func waitForPortToClose(_ port: Int, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !PortProbe.isListening(port: port) { return }
            usleep(20_000)
        }
    }

    /// Stop listening and close every tunnel immediately.
    ///
    /// Separate from `stop()` because the polite version is what a mode switch
    /// wants, and this is what quitting the app and the tests want.
    public func shutdown() {
        stateLock.lock()
        let victim = listener
        listener = nil
        startDate = nil
        let open = Array(tunnels.values)
        tunnels.removeAll()
        connections = 0
        stateLock.unlock()

        let closedPort = victim?.port.map { Int($0.rawValue) }
        victim?.cancel()
        for tunnel in open { tunnel.cancel() }
        if let port = closedPort { waitForPortToClose(port, timeout: 1.5) }
    }

    public func status() -> DPIStatus {
        stateLock.lock()
        defer { stateLock.unlock() }
        return snapshotLocked()
    }

    // MARK: - Browser PAC (1.0.8)

    /// The user's browser list while "Use in browsers too" is on; nil means
    /// `GET /menfez.pac` is refused like any other non-CONNECT request.
    private var pacEntries: [String]?

    public func setBrowserSites(_ entries: [String]?) {
        stateLock.lock()
        pacEntries = entries
        stateLock.unlock()
    }

    /// The PAC reply for this listener's port, or nil when not serving one.
    fileprivate func pacReply() -> String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let entries = pacEntries, let port = listener?.port.map({ Int($0.rawValue) }) else { return nil }
        return PACFile.response(entries: entries, port: port)
    }

    /// The URL a client should be pointed at, or nil when stopped.
    public var proxyURL: URL? {
        let snapshot = status()
        guard snapshot.running, let port = snapshot.port else { return nil }
        return URL(string: "http://127.0.0.1:\(port)")
    }

    private func snapshotLocked() -> DPIStatus {
        DPIStatus(running: listener != nil,
                  port: listener?.port.map { Int($0.rawValue) },
                  connections: connections,
                  reframed: reframed,
                  passthrough: passthrough,
                  rejected: rejected,
                  overCapacity: overCapacity,
                  uptimeS: startDate.map { Int(Date().timeIntervalSince($0)) },
                  splitAt: config.firstRecordPayloadLimit,
                  lastError: lastError)
    }

    // MARK: - Accept

    private func accept(_ connection: NWConnection) {
        stateLock.lock()
        guard listener != nil || starting else {
            stateLock.unlock()
            connection.cancel()
            return
        }
        guard connections < config.maxConnections else {
            // Refused at accept time, before a tunnel object or any buffer is
            // allocated for it.
            overCapacity += 1
            rejected += 1
            lastError = "refused: \(config.maxConnections) connections already open"
            stateLock.unlock()
            Self.writeAndClose(connection,
                               queue: netQueue,
                               status: 503, reason: "Service Unavailable",
                               body: "the proxy is serving \(config.maxConnections) connections")
            return
        }

        connections += 1
        let tunnel = Tunnel(engine: self, client: connection, config: config,
                            queue: netQueue)
        tunnels[ObjectIdentifier(tunnel)] = tunnel
        stateLock.unlock()

        tunnel.begin()
    }

    /// Called by a tunnel once, as soon as the first record has been classified.
    ///
    /// Recorded here rather than at close because a Discord connection can live
    /// for hours: waiting for the close would leave the UI showing "0 split"
    /// while the split was doing exactly its job. The outcome is reported at
    /// most once per tunnel — `Tunnel.reported` guards it.
    private func record(outcome: Tunnel.Outcome) {
        stateLock.lock()
        defer { stateLock.unlock() }
        switch outcome {
        case .split:       reframed += 1
        case .passthrough: passthrough += 1
        }
    }

    /// Called by a tunnel once, when it is done for any reason.
    private func finish(_ tunnel: Tunnel) {
        let id = ObjectIdentifier(tunnel)
        stateLock.lock()
        defer { stateLock.unlock() }
        guard tunnels.removeValue(forKey: id) != nil else { return }
        connections = max(0, connections - 1)
    }

    private func noteRefusal(_ message: String) {
        stateLock.lock()
        rejected += 1
        lastError = message
        stateLock.unlock()
    }

    private func record(error message: String) {
        stateLock.lock()
        lastError = message
        stateLock.unlock()
    }

    // MARK: - Parameters

    /// Loopback-only parameters; an ephemeral port unless one is asked for.
    ///
    /// Not private so a test can assert the bind address without opening a
    /// listener: a required local endpoint that is not 127.0.0.1 would silently
    /// turn this proxy into a relay for the whole LAN.
    static func makeParameters(port: NWEndpoint.Port = .any) -> NWParameters {
        let parameters = NWParameters(tls: nil, tcp: tcpOptions())
        // Reuse keeps a restart from failing on a lingering TIME_WAIT. It does
        // not widen the bind: the address below still decides that.
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host("127.0.0.1"), port: port)
        return parameters
    }

    static func tcpOptions(connectTimeout: TimeInterval = 10) -> NWProtocolTCP.Options {
        let tcp = NWProtocolTCP.Options()
        // A proxy adds one hop, and Nagle on that hop would delay the second
        // record behind an ACK. The point is that both records leave together.
        tcp.noDelay = true
        tcp.connectionTimeout = max(1, Int(connectTimeout.rounded(.up)))
        return tcp
    }

    /// Send a one-line HTTP error and close. Used only before a tunnel exists.
    private static func writeAndClose(_ connection: NWConnection,
                                      queue: DispatchQueue,
                                      status: Int, reason: String, body: String,
                                      extraHeaders: String = "") {
        let text = "HTTP/1.1 \(status) \(reason)\r\n"
            + "Content-Type: text/plain; charset=utf-8\r\n"
            + "Content-Length: \(body.utf8.count)\r\n"
            + "Connection: close\r\n"
            + extraHeaders
            + "\r\n"
            + body
        connection.start(queue: queue)
        connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Tunnel

    /// One client connection: read the CONNECT head, dial, then two pumps.
    ///
    /// Reference type whose state is touched only on `queue` (the engine's
    /// serial network queue), which is what makes the absent locks safe. The
    /// only cross-thread touches are the counter updates above, which take the
    /// engine's lock.
    // Sendable by confinement: all state is touched only on `queue`.
    fileprivate final class Tunnel: @unchecked Sendable {
        enum Outcome { case split, passthrough }

        private enum Phase {
            case readingHead
            case dialing
            case established
            case closed
        }

        private let engine: DPIEngine
        private let client: NWConnection
        private let config: Configuration
        private let queue: DispatchQueue

        private var upstream: NWConnection?
        private var headReader: ConnectHeadReader
        private var splitter: FirstRecordSplitter
        private var phase: Phase = .readingHead
        /// Set once the first record's outcome is known and counted. Guarded by
        /// `queue`, like everything else in the tunnel.
        private var reported = false
        /// Which directions have delivered their FIN. When both have, the
        /// tunnel is finished and is closed immediately instead of being left
        /// to the idle timer — otherwise every closed Discord connection would
        /// hold a slot for the full idle timeout and the 128-connection cap
        /// would be consumed by tunnels nobody is using.
        private var clientFinished = false
        private var upstreamFinished = false
        private var headerTimer: DispatchWorkItem?
        private var dialTimer: DispatchWorkItem?
        private var idleTimer: DispatchSourceTimer?
        /// Set on every read/write completion, read only on `queue`. Guarded by
        /// the engine's lock because the idle handler reads it from `timerQueue`.
        private let lastActivity = Activity()
        /// A request that has already been answered must not be answered twice;
        /// the second send would arrive after the close and be logged as a
        /// socket error that never happened.
        private var refused = false

        init(engine: DPIEngine, client: NWConnection,
             config: Configuration, queue: DispatchQueue) {
            self.engine = engine
            self.client = client
            self.config = config
            self.queue = queue
            self.headReader = ConnectHeadReader(maxBytes: config.maxHeaderBytes)
            self.splitter = FirstRecordSplitter(limit: config.firstRecordPayloadLimit)
        }

        func begin() {
            client.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .failed, .cancelled:
                    self.close()
                default:
                    break
                }
            }
            client.start(queue: queue)
            armHeaderTimer()
            readHead()
        }

        // MARK: Head

        private func armHeaderTimer() {
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.queue.async {
                    guard self.phase == .readingHead else { return }
                    self.refuse(status: 408, reason: "Request Timeout",
                                body: "no CONNECT request within "
                                    + "\(Int(self.config.headerTimeout)) s",
                                note: "timed out waiting for the CONNECT head")
                }
            }
            headerTimer = item
            engine.timerQueue.asyncAfter(deadline: .now() + config.headerTimeout,
                                         execute: item)
        }

        private func readHead() {
            client.receive(minimumIncompleteLength: 1,
                           maximumLength: config.chunkBytes) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                guard self.phase == .readingHead else { return }

                if error != nil {
                    self.close()
                    return
                }
                guard let data, !data.isEmpty else {
                    // Closed before sending a head; nothing to answer.
                    if isComplete { self.close() }
                    return
                }

                let result: (head: [UInt8], remainder: [UInt8])?
                do {
                    result = try self.headReader.append([UInt8](data))
                } catch let parseError as ConnectParseError {
                    self.headerTimer?.cancel()
                    self.headerTimer = nil
                    self.refuse(parseError: parseError)
                    return
                } catch {
                    self.headerTimer?.cancel()
                    self.headerTimer = nil
                    self.refuse(status: 400, reason: "Bad Request",
                                body: "malformed CONNECT request",
                                note: "refused: malformed request")
                    return
                }

                guard let result else {
                    self.readHead()
                    return
                }
                self.headerTimer?.cancel()
                self.headerTimer = nil

                // The one non-CONNECT request served: the browser PAC.
                if PACFile.isRequest(head: result.head), let reply = self.engine.pacReply() {
                    self.serve(reply)
                    return
                }

                let request: ConnectRequest
                do {
                    request = try ConnectRequestParser.parse(head: result.head)
                } catch let parseError as ConnectParseError {
                    self.refuse(parseError: parseError)
                    return
                } catch {
                    self.refuse(status: 400, reason: "Bad Request",
                                body: "malformed CONNECT request",
                                note: "refused: malformed request")
                    return
                }
                self.dial(request, remainder: result.remainder)
            }
        }

        private func refuse(parseError: ConnectParseError) {
            switch parseError {
            case .headerTooLarge(let limit):
                // 431 is the accurate code, and Chromium renders it readably.
                refuse(status: 431, reason: "Request Header Fields Too Large",
                       body: "CONNECT header exceeds \(limit) bytes",
                       note: "refused: header over \(limit) bytes")
            case .unsupportedMethod(let method):
                refuse(status: 405, reason: "Method Not Allowed",
                       body: "only CONNECT is supported, not \(method)",
                       extraHeaders: "Allow: CONNECT\r\n",
                       note: "refused: method \(method)")
            case .incomplete:
                refuse(status: 400, reason: "Bad Request",
                       body: parseError.description,
                       note: "refused: incomplete request")
            default:
                refuse(status: 400, reason: "Bad Request",
                       body: parseError.description,
                       note: "refused: \(parseError.description)")
            }
        }

        // MARK: Dial

        private func dial(_ request: ConnectRequest, remainder: [UInt8]) {
            if config.restrictTargets, let why = request.policyRefusal {
                refuse(status: 403, reason: "Forbidden",
                       body: "CONNECT to \(request.authority) is not allowed: \(why)",
                       note: "refused: \(request.authority) (\(why))")
                return
            }

            phase = .dialing
            // The deadline covers the lookup too.
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.queue.async {
                    guard self.phase == .dialing else { return }
                    self.refuse(status: 504, reason: "Gateway Timeout",
                                body: "no connection to \(request.authority) within "
                                    + "\(Int(self.config.connectTimeout)) s",
                                note: "dial timed out: \(request.authority)")
                }
            }
            dialTimer = item
            engine.timerQueue.asyncAfter(deadline: .now() + config.connectTimeout,
                                         execute: item)

            guard let resolver = config.resolver, !request.isAddressLiteral else {
                connect(request, to: request.host, remainder: remainder)
                return
            }
            resolver.resolve(request.host) { [weak self] addresses in
                guard let self else { return }
                self.queue.async {
                    guard self.phase == .dialing else { return }
                    guard let addresses, let first = addresses.first else {
                        // DoH failed: let system DNS try within the same deadline.
                        self.connect(request, to: request.host, remainder: remainder)
                        return
                    }
                    // A public name must not become a way into the LAN or loopback.
                    if self.config.restrictTargets,
                       let why = addresses.lazy.compactMap({
                           ConnectRequest(host: $0, port: request.port).policyRefusal }).first {
                        self.refuse(status: 403, reason: "Forbidden",
                                    body: "CONNECT to \(request.authority) is not allowed: \(why)",
                                    note: "refused: \(request.authority) resolves to \(why)")
                        return
                    }
                    self.connect(request, to: first, remainder: remainder)
                }
            }
        }

        /// Dial `host` (the request's name, or an address resolved for it).
        /// Only the TCP destination changes; the client's TLS bytes, SNI
        /// included, are forwarded as they are.
        private func connect(_ request: ConnectRequest, to host: String, remainder: [UInt8]) {
            // The parser already limits the port to 1-65535.
            let port = NWEndpoint.Port(integerLiteral: UInt16(clamping: request.port))
            let parameters = NWParameters(
                tls: nil, tcp: DPIEngine.tcpOptions(connectTimeout: config.connectTimeout))
            let upstream = NWConnection(host: NWEndpoint.Host(host),
                                        port: port,
                                        using: parameters)
            self.upstream = upstream

            upstream.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.dialTimer?.cancel()
                    self.dialTimer = nil
                    self.establish(remainder: remainder)
                case .failed(let error):
                    self.dialTimer?.cancel()
                    self.dialTimer = nil
                    // After the 200 the client is speaking TLS: an HTTP 502
                    // there would corrupt its stream, and the dial did succeed.
                    guard self.phase == .dialing else { self.close(); return }
                    self.refuse(status: 502, reason: "Bad Gateway",
                                body: "cannot reach \(request.authority): "
                                    + error.localizedDescription,
                                note: "dial failed: \(request.authority)")
                default:
                    // `.waiting` is DNS in progress or a slow path; the
                    // deadline decides, not this state.
                    break
                }
            }

            upstream.start(queue: queue)
        }

        private func establish(remainder: [UInt8]) {
            guard phase == .dialing else { return }
            phase = .established

            let ok = Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)
            client.send(content: ok, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil { self.close(); return }
                self.touch()
                self.startIdleTimer()
                // Bytes that arrived in the same segment as the CONNECT head
                // are the start of the tunnel. Chromium often sends the
                // ClientHello that way, so dropping them would break every
                // connection.
                if !remainder.isEmpty {
                    self.forwardClient(remainder)
                } else {
                    self.readClient()
                }
                self.readUpstream()
            })
        }

        // MARK: Client → upstream

        private func readClient() {
            guard phase == .established else { return }
            client.receive(minimumIncompleteLength: 1,
                           maximumLength: config.chunkBytes) { [weak self] data, _, isComplete, error in
                guard let self, self.phase == .established else { return }
                if error != nil { self.close(); return }
                if let data, !data.isEmpty {
                    self.forwardClient([UInt8](data))
                } else if isComplete {
                    // Half-close: the client is done sending. Keep the
                    // upstream → client direction alive, which is how a TLS
                    // close_notify is meant to work.
                    self.clientFinished = true
                    // A short stream that ended before the split decision
                    // still has its bytes in the splitter; send them first.
                    let tail = self.splitter.flush()
                    self.reportOutcome()
                    if !tail.isEmpty {
                        self.upstream?.send(content: Data(tail),
                                            completion: .contentProcessed { _ in })
                    }
                    self.upstream?.send(content: nil, contentContext: .finalMessage,
                                        isComplete: true,
                                        completion: .contentProcessed { _ in })
                    self.closeIfBothFinished()
                }
            }
        }

        private func forwardClient(_ chunk: [UInt8]) {
            let out = splitter.feed(chunk)
            reportOutcome()
            guard !out.isEmpty, let upstream else {
                readClient()
                return
            }
            upstream.send(content: Data(out),
                          completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil { self.close(); return }
                self.touch()
                self.readClient()
            })
        }

        private func reportOutcome() {
            guard !reported else { return }
            switch splitter.outcome {
            case .split:
                reported = true
                // Counted now, not at close: a Discord tunnel can live for
                // hours, and a counter that only moves when the connection
                // ends would read "0 split" during the exact case it exists
                // to report.
                engine.record(outcome: .split)
            case .passthrough:
                reported = true
                engine.record(outcome: .passthrough)
            case .undecided:
                break
            }
        }

        // MARK: Upstream → client

        private func readUpstream() {
            guard phase == .established, let upstream else { return }
            upstream.receive(minimumIncompleteLength: 1,
                             maximumLength: config.chunkBytes) { [weak self] data, _, isComplete, error in
                guard let self, self.phase == .established else { return }
                if error != nil { self.close(); return }
                if let data, !data.isEmpty {
                    self.client.send(content: data,
                                     completion: .contentProcessed { [weak self] error in
                        guard let self else { return }
                        if error != nil { self.close(); return }
                        self.touch()
                        self.readUpstream()
                    })
                } else if isComplete {
                    // Origin finished: pass the FIN on and stop reading it.
                    self.upstreamFinished = true
                    self.client.send(content: nil, contentContext: .finalMessage,
                                     isComplete: true, completion: .contentProcessed { _ in })
                    self.closeIfBothFinished()
                }
            }
        }

        private func closeIfBothFinished() {
            guard clientFinished && upstreamFinished else { return }
            // Both sides sent FIN, so nothing more can arrive. Closing now
            // releases the slot immediately; leaving it to the idle timer would
            // hold a slot for two minutes per finished Discord connection and
            // the 128-connection cap would be consumed by dead tunnels.
            close()
        }

        // MARK: Idle deadline

        /// Record activity. Cheap enough for every chunk: a lock and a Date.
        private func touch() {
            lastActivity.set(Date())
            startIdleTimer()
        }

        /// One repeating timer per established tunnel.
        ///
        /// A repeating 10 s tick is cheaper than arming a fresh work item per
        /// chunk (a busy Discord connection delivers tens of thousands), and it
        /// means a connection that receives nothing at all still expires. The
        /// tick interval is capped at 10 s so a 120 s timeout is honoured to
        /// within a few seconds rather than within an idle period.
        private func startIdleTimer() {
            guard phase == .established, idleTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: engine.timerQueue)
            let tick = max(1, min(10, config.idleTimeout / 4))
            timer.schedule(deadline: .now() + tick, repeating: tick, leeway: .milliseconds(250))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                guard let last = self.lastActivity.value else { return }
                if Date().timeIntervalSince(last) >= self.config.idleTimeout {
                    self.queue.async { self.close() }
                }
            }
            idleTimer = timer
            timer.resume()
        }

        // MARK: Lifecycle

        /// Answer with an HTTP failure, then close.
        private func refuse(status: Int, reason: String, body: String,
                            extraHeaders: String = "", note: String) {
            guard !refused, phase != .closed else { return }
            // Never write HTTP into an established tunnel.
            guard phase != .established else { close(); return }
            refused = true
            engine.noteRefusal(note)
            let text = "HTTP/1.1 \(status) \(reason)\r\n"
                + "Content-Type: text/plain; charset=utf-8\r\n"
                + "Content-Length: \(body.utf8.count)\r\n"
                + "Connection: close\r\n"
                + extraHeaders
                + "\r\n" + body
            client.send(content: Data(text.utf8),
                        completion: .contentProcessed { [weak self] _ in
                self?.close()
            })
        }

        /// Answer a PAC request and close; not counted as a refusal.
        private func serve(_ text: String) {
            guard !refused, phase == .readingHead else { return }
            refused = true
            client.send(content: Data(text.utf8),
                        completion: .contentProcessed { [weak self] _ in
                self?.close()
            })
        }

        func cancel() {
            queue.async { self.close() }
        }

        private func close() {
            guard phase != .closed else { return }
            phase = .closed
            headerTimer?.cancel(); headerTimer = nil
            dialTimer?.cancel(); dialTimer = nil
            idleTimer?.cancel(); idleTimer = nil
            client.cancel()
            upstream?.cancel()
            upstream = nil
            engine.finish(self)
        }
    }
}

// MARK: - Small shared boxes

/// The listener's failure message, written on the network queue and read on the
/// thread that called `start`.
private final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    func set(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        stored = message
    }

    var value: String? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}

/// Last activity timestamp shared between the network queue and the idle timer.
private final class Activity: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Date?

    func set(_ date: Date) {
        lock.lock(); defer { lock.unlock() }
        stored = date
    }

    var value: Date? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}
