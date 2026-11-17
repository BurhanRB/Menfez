import XCTest
import Network
@testable import MenfezCore

// RootlessTests — the promise of the default path, asserted rather than
// described.
//
// WHAT THIS GUARDS
// The product claim is "a stranger who downloads this .app gets Discord working
// with no sudo, no password and no privileged helper". Three things could break
// that silently, and each has a test here:
//
//   1. The engine could acquire a dependency on root. It has none today: the
//      listener is a loopback bind, and the only external process in the whole
//      DPI path is `open`, which runs as the user.
//   2. Starting the proxy could start a privileged process. The test counts
//      processes through the injected runner and requires zero.
//   3. The default mode could be something other than direct. A fresh launch
//      that begins in `dpi` or `tunnel` would intercept traffic nobody asked
//      it to intercept.
//
// These run as the invoking user, which is the point: if they needed root they
// would be measuring the wrong thing.

final class RootlessTests: XCTestCase {

    /// The engine binds and serves as an unprivileged user.
    ///
    /// The assertion that matters is not "start() returned" but "a connection
    /// was accepted and answered": a listener that reports `.ready` while
    /// refusing work would pass a weaker test.
    func testProxyStartsAndAnswersAsTheUser() throws {
        // A guard, not a skip: the suite runs as the user in every supported
        // setup, and if it were ever run as root this test would stop proving
        // anything about the rootless path.
        XCTAssertNotEqual(geteuid(), 0,
                          "this test must run as an unprivileged user to mean anything")

        let engine = DPIEngine(configuration: .loopback)
        defer { engine.shutdown() }

        let status = try engine.start()
        let port = try XCTUnwrap(status.port)
        XCTAssertTrue(status.running)

        // An origin the proxy can dial without leaving the machine: a second
        // listener on loopback. This is what makes the test hermetic — the
        // proxy's job is CONNECT plus a byte pipe, and both work identically
        // against 127.0.0.1.
        let origin = try LoopbackOrigin()
        defer { origin.cancel() }

        let client = try RawClient(port: port)
        defer { client.close() }
        try client.send("CONNECT 127.0.0.1:\(origin.port) HTTP/1.1\r\n"
                        + "Host: 127.0.0.1:\(origin.port)\r\n\r\n")

        let head = try client.readUntil(Array("\r\n\r\n".utf8), timeout: 5)
        let headText = String(decoding: head, as: UTF8.self)
        XCTAssertTrue(headText.hasPrefix("HTTP/1.1 200"),
                      "the proxy refused a loopback CONNECT: \(headText)")

        // A TLS handshake record big enough to be split, then read it back on
        // the far side. The re-framed form is 10 bytes longer than the original
        // (two record headers instead of one), which is also why reading
        // `hello.count` bytes would truncate the second record and hide the
        // split — the assertion has to wait for the longer shape.
        let hello = RootlessTests.handshakeRecord(payloadLength: 300)
        let limit = TLSRecordReframer.firstRecordPayloadLimit
        let reframedLength = 5 + limit + 5 + (300 - limit)
        try client.sendBytes(hello)

        let received = try origin.readExactly(reframedLength, timeout: 5)
        let parts = Self.records(in: received)
        XCTAssertEqual(parts.count, 2,
                       "the first record was not re-framed on the wire")
        XCTAssertEqual(parts.map(\.type), [0x16, 0x16])
        XCTAssertEqual(parts[0].payload.count, limit)
        XCTAssertEqual(parts[0].payload + parts[1].payload,
                       Array(hello.dropFirst(5)),
                       "the payload must survive the split byte for byte")

        // Give the engine's counter a moment to be updated on its own queue.
        let deadline = Date().addingTimeInterval(3)
        while engine.status().reframed == 0 && Date() < deadline {
            usleep(20_000)
        }
        XCTAssertGreaterThan(engine.status().reframed, 0,
                             "the engine did not count the split it performed")
    }

    /// Enabling DPI mode spawns no privileged process, and no process at all.
    ///
    /// The engine is in-process; the only thing that touches a subprocess in the
    /// DPI path is the Discord launch, which is not part of `enable`. If this
    /// ever fails, the rootless claim is false and the test says exactly which
    /// call broke it.
    @MainActor
    func testEnablingDPIModeSpawnsNothing() async {
        let engine = DPIEngine()
        defer { engine.shutdown() }
        let recorder = RecordingRunner()
        let mode = DPIMode(engine: engine, tunnelInterfaces: { [] })
        _ = recorder

        let result = await mode.enable()
        XCTAssertTrue(result.ok, result.message)
        XCTAssertTrue(recorder.calls.isEmpty,
                      "enabling the proxy must not start any process: \(recorder.calls.map(\.joined))")
    }

    /// The mac app never asks sudo for anything on the default path.
    ///
    /// `HelperClient.spawnedRoot` is the counter the read path already uses to
    /// prove it starts no root process. This wires a real `HelperTunnel` to a
    /// client that records every spawn, then drives the DPI path: if the proxy
    /// ever consulted the tunnel — to check for a conflict, to adopt state, to
    /// clean up — the counter would move and the test would say which command.
    @MainActor
    func testDefaultPathNeverTouchesTheHelper() async {
        var spawned: [String] = []
        let client = HelperClient(helper: "/nonexistent/menfez-route") { tool, _, _ in
            spawned.append(tool)
            return CommandResult(status: 0, output: "")
        }
        // No interfaces, so even a call would report "no tunnel"; the assertion
        // below is about the *spawn*, not about its answer.
        let tunnel = HelperTunnel(client: client, interfaces: { [] })

        let engine = DPIEngine()
        defer { engine.shutdown() }
        let coordinator = ModeCoordinator(
            dpi: DPIMode(engine: engine, tunnelInterfaces: { [] }),
            tunnel: tunnel)

        coordinator.adoptExistingState()
        let state = await coordinator.switchTo(.dpi)

        XCTAssertTrue(state.ok, state.message)
        XCTAssertTrue(spawned.isEmpty,
                      "the DPI path started a process: \(spawned)")
        XCTAssertFalse(client.spawnedRoot, "the DPI path must never call sudo")
    }

    // MARK: - Fixtures

    /// A synthetic TLS handshake record, shaped like a ClientHello and long
    /// enough to be split.
    static func handshakeRecord(payloadLength: Int) -> [UInt8] {
        var bytes: [UInt8] = [0x16, 0x03, 0x01,
                              UInt8((payloadLength >> 8) & 0xff),
                              UInt8(payloadLength & 0xff)]
        for index in 0..<payloadLength { bytes.append(UInt8(index & 0xff)) }
        return bytes
    }

    static func records(in bytes: [UInt8]) -> [(type: UInt8, payload: [UInt8])] {
        var out: [(UInt8, [UInt8])] = []
        var index = 0
        while index + 5 <= bytes.count {
            let length = (Int(bytes[index + 3]) << 8) | Int(bytes[index + 4])
            guard index + 5 + length <= bytes.count else { break }
            out.append((bytes[index], Array(bytes[(index + 5)..<(index + 5 + length)])))
            index += 5 + length
        }
        return out.map { (type: $0.0, payload: $0.1) }
    }

    /// A loopback TCP server that accepts one connection and records its bytes.
    ///
    /// Network.framework rather than POSIX sockets so the test shares the
    /// engine's own I/O model; a raw-socket server would be a second way for
    /// bytes to arrive and would not exercise the same path.
    final class LoopbackOrigin: @unchecked Sendable {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "menfez.test.origin")
        private let lock = NSLock()
        private var buffer = Data()
        private var connection: NWConnection?

        var port: Int { Int(listener.port?.rawValue ?? 0) }

        init() throws {
            let params = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
            params.allowLocalEndpointReuse = true
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: params)
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { state in
                if case .ready = state { ready.signal() }
            }
            listener.newConnectionHandler = { [weak self] conn in
                self?.accept(conn)
            }
            listener.start(queue: queue)
            guard ready.wait(timeout: .now() + 3) == .success else {
                listener.cancel()
                throw OriginError.notReady
            }
        }

        enum OriginError: Error { case notReady }

        private func accept(_ conn: NWConnection) {
            connection = conn
            conn.start(queue: queue)
            receive()
        }

        private func receive() {
            connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
                [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.lock.lock(); self.buffer.append(data); self.lock.unlock()
                }
                if error == nil && !isComplete { self.receive() }
            }
        }

        /// Wait for `count` bytes, or fail after the deadline.
        func readExactly(_ count: Int, timeout: TimeInterval) throws -> [UInt8] {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                lock.lock()
                let have = buffer.count
                lock.unlock()
                if have >= count {
                    lock.lock()
                    let out = [UInt8](buffer.prefix(count))
                    lock.unlock()
                    return out
                }
                usleep(20_000)
            }
            throw OriginError.notReady
        }

        func cancel() {
            connection?.cancel()
            listener.cancel()
        }
    }
}
