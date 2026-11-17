import XCTest
import Network
@testable import MenfezCore

// DPIProxyTests — the proxy's contract, exercised with loopback fakes only.
//
// NO TEST HERE TOUCHES THE INTERNET. The CONNECT tests run against an
// in-process NWListener that stands in for the origin server; the reframing
// tests are pure array arithmetic. That is deliberate: the one thing this engine
// exists for is a network that blocks, so a test that depended on that network
// would pass or fail for reasons the suite cannot control — and would be
// measuring the ISP rather than the code.
//
// The split is verified here on synthetic handshakes: byte-for-byte payload
// identity, exact record lengths, and the refusal cases. It is NOT verified
// against the real block. See docs/DPI-ENGINE.md, "what must be re-measured".

final class DPIProxyTests: XCTestCase {

    // MARK: - Fixtures

    /// A synthetic ClientHello-shaped record: content type 0x16, version 0x0301
    /// and a chosen payload length. The payload is not a real ClientHello — the
    /// reframer must not care, which is the property under test.
    static func record(payloadLength: Int, version: (UInt8, UInt8) = (0x03, 0x01))
        -> [UInt8] {
        var bytes: [UInt8] = [0x16, version.0, version.1,
                              UInt8((payloadLength >> 8) & 0xff),
                              UInt8(payloadLength & 0xff)]
        // A repeating pattern makes an off-by-one in the split visible: a
        // shifted payload still has the right length but the wrong bytes.
        for index in 0..<payloadLength {
            bytes.append(UInt8(index & 0xff))
        }
        return bytes
    }

    static func payload(of record: [UInt8]) -> [UInt8] {
        guard record.count >= 5 else { return [] }
        let declared = (Int(record[3]) << 8) | Int(record[4])
        let end = min(record.count, 5 + declared)
        return Array(record[5..<end])
    }

    /// Split a byte buffer into TLS records by reading each header.
    static func records(in bytes: [UInt8]) -> [(type: UInt8, major: UInt8,
                                                minor: UInt8, payload: [UInt8])] {
        var out: [(UInt8, UInt8, UInt8, [UInt8])] = []
        var index = 0
        while index + 5 <= bytes.count {
            let length = (Int(bytes[index + 3]) << 8) | Int(bytes[index + 4])
            guard index + 5 + length <= bytes.count else { break }
            out.append((bytes[index], bytes[index + 1], bytes[index + 2],
                        Array(bytes[(index + 5)..<(index + 5 + length)])))
            index += 5 + length
        }
        return out.map { (type: $0.0, major: $0.1, minor: $0.2, payload: $0.3) }
    }

    // MARK: - The reframe itself

    /// The core contract: `5 + N + 5 + (len - N)` bytes out, correct headers,
    /// identical payload.
    func testReframeProducesTwoRecordsWithIdenticalPayload() throws {
        let limit = TLSRecordReframer.firstRecordPayloadLimit
        let input = Self.record(payloadLength: 300)
        let originalPayload = Self.payload(of: input)
        XCTAssertEqual(originalPayload.count, 300)

        let split = try XCTUnwrap(TLSRecordReframer.reframe(record: input))

        XCTAssertEqual(split.bytes.count, 5 + limit + 5 + (300 - limit),
                       "output must be exactly 5 + N + 5 + (len - N) bytes")
        XCTAssertEqual(split.firstPayloadLength, limit)
        XCTAssertEqual(split.secondPayloadLength, 300 - limit)

        let parts = Self.records(in: split.bytes)
        XCTAssertEqual(parts.count, 2, "exactly two records, no more")
        XCTAssertEqual(parts.map(\.type), [0x16, 0x16])
        XCTAssertEqual(parts[0].major, 0x03)
        XCTAssertEqual(parts[0].minor, 0x01)
        XCTAssertEqual(parts[1].major, 0x03, "the second header keeps the version")
        XCTAssertEqual(parts[1].minor, 0x01)
        XCTAssertEqual(parts[0].payload.count, limit)
        XCTAssertEqual(parts[1].payload.count, 300 - limit)

        // The whole point: concatenation must equal the original payload byte
        // for byte. A shifted or duplicated byte here would break the handshake
        // on the server and the bypass would "work" while Discord failed.
        XCTAssertEqual(parts[0].payload + parts[1].payload, originalPayload)
    }

    /// A payload exactly at the limit produces nothing: there is no second
    /// record to write, and emitting an empty one would be a gratuitous change.
    func testPayloadAtLimitIsNotSplit() {
        let limit = TLSRecordReframer.firstRecordPayloadLimit
        let input = Self.record(payloadLength: limit)
        XCTAssertNil(TLSRecordReframer.reframe(record: input))
    }

    func testPayloadShorterThanLimitIsNotSplit() {
        let input = Self.record(payloadLength: 10)
        XCTAssertNil(TLSRecordReframer.reframe(record: input))
    }

    func testEmptyPayloadIsNotSplit() {
        XCTAssertNil(TLSRecordReframer.reframe(record: Self.record(payloadLength: 0)))
    }

    /// A 1-byte record is not a handshake the proxy should touch, and it is
    /// also the smallest input that could trip a naive `[0..<40]` slice.
    func testOneBytePayloadIsNotSplit() {
        XCTAssertNil(TLSRecordReframer.reframe(record: Self.record(payloadLength: 1)))
    }

    /// A record header that claims more bytes than are present must never be
    /// force-sliced: the reframer refuses and the caller passes bytes through.
    func testTruncatedRecordIsNotSplit() {
        var input = Self.record(payloadLength: 300)
        input.removeLast(100)
        XCTAssertNil(TLSRecordReframer.reframe(record: input),
                     "an incomplete record must not be split")
    }

    /// Not a handshake record: application data (0x17), an alert (0x15), and a
    /// non-TLS first byte.
    func testNonHandshakeContentIsNotSplit() {
        for first: UInt8 in [0x17, 0x15, 0x14, 0x00, 0xff] {
            var input = Self.record(payloadLength: 300)
            input[0] = first
            XCTAssertNil(TLSRecordReframer.reframe(record: input),
                         "content type \(first) must pass through")
        }
    }

    /// The ClientHello's record version is 0x0301 in practice, but 0x0303 is
    /// also valid and 0x0300 (SSL 3.0) appears in older stacks. The reframer is
    /// a length rule, so it must not care which of them it sees — only that the
    /// major version is 3.
    func testAnyTLSRecordVersionIsSplit() {
        let limit = TLSRecordReframer.firstRecordPayloadLimit
        for minor: UInt8 in [0x00, 0x01, 0x02, 0x03] {
            let input = Self.record(payloadLength: 200, version: (0x03, minor))
            let split = TLSRecordReframer.reframe(record: input)
            XCTAssertNotNil(split, "minor 0x03\(minor == 0 ? "0" : "") must split")
            guard let split else { continue }
            XCTAssertEqual(split.firstPayloadLength, limit)
            let parts = Self.records(in: split.bytes)
            XCTAssertEqual(parts.map(\.minor), [minor, minor])
            XCTAssertEqual(parts[0].payload + parts[1].payload,
                           Self.payload(of: input))
        }
    }

    /// A payload one byte over the limit is the smallest split, which is the
    /// case that produces a 1-byte second record. It must still be exact.
    func testPayloadOneByteOverLimitSplits() throws {
        let limit = TLSRecordReframer.firstRecordPayloadLimit
        let input = Self.record(payloadLength: limit + 1)
        let split = try XCTUnwrap(TLSRecordReframer.reframe(record: input))
        XCTAssertEqual(split.secondPayloadLength, 1)
        XCTAssertEqual(split.bytes.count, 5 + limit + 5 + 1)
        let parts = Self.records(in: split.bytes)
        XCTAssertEqual(parts[0].payload + parts[1].payload, Self.payload(of: input))
    }

    /// No payload byte can be 0x00-safe by accident: a handshake payload of all
    /// zeros would hide a length bug, so the fixture uses a pattern. This test
    /// checks the pattern survives a large record, where the second record is
    /// bigger than any buffer the proxy holds.
    func testLargePayloadSurvivesInOrder() throws {
        let input = Self.record(payloadLength: 16_384)
        let split = try XCTUnwrap(TLSRecordReframer.reframe(record: input))
        let parts = Self.records(in: split.bytes)
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0].payload + parts[1].payload, Self.payload(of: input))
        XCTAssertEqual(split.bytes.count, 5 + 40 + 5 + (16_384 - 40))
    }

    // MARK: - Streaming splitter

    /// The streaming path is what the proxy actually uses, so it must produce
    /// exactly what the one-shot reframer produces, byte for byte.
    func testSplitterMatchesOneShotReframer() throws {
        let input = Self.record(payloadLength: 300)
        let expected = try XCTUnwrap(TLSRecordReframer.reframe(record: input))

        var splitter = FirstRecordSplitter()
        var out: [UInt8] = []
        for byte in input {
            out.append(contentsOf: splitter.feed([byte]))
        }
        XCTAssertEqual(splitter.outcome, .split)
        XCTAssertEqual(out, expected.bytes,
                       "the streaming split must equal the one-shot reframe")
        XCTAssertEqual(splitter.bufferedBytes, 0)
    }

    /// A single chunk containing the whole record must produce the split
    /// immediately, with the tail passed through untouched.
    func testSplitterHandlesWholeRecordInOneChunk() throws {
        let input = Self.record(payloadLength: 300)
        var splitter = FirstRecordSplitter()
        let out = splitter.feed(input)

        XCTAssertEqual(splitter.outcome, .split)
        // out = [rec1 hdr][40 B][rec2 hdr] + payload[40...]
        XCTAssertEqual(out.count, 5 + 40 + 5 + 260)
        let parts = Self.records(in: Array(out.prefix(5 + 40 + 5 + 260)))
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0].payload + parts[1].payload,
                       Self.payload(of: input))
    }

    /// A non-TLS stream is forwarded byte for byte. The first byte alone is
    /// enough to decide, which is why a plain HTTP tunnel never waits for 45
    /// bytes before its first byte reaches the origin.
    func testSplitterPassesThroughNonTLSImmediately() {
        var splitter = FirstRecordSplitter()
        let out = splitter.feed([0x47, 0x45, 0x54])   // "GET"
        XCTAssertEqual(splitter.outcome, .passthrough)
        XCTAssertEqual(out, [0x47, 0x45, 0x54])

        // Everything after the decision is returned unchanged.
        let later: [UInt8] = [0x20, 0x2f, 0x20, 0x48]
        XCTAssertEqual(splitter.feed(later), later)
        XCTAssertEqual(splitter.bufferedBytes, 0)
    }

    /// 0x16 followed by something other than 0x03 is not a TLS handshake (TLS
    /// 1.x always has a 0x03 major version). It must pass through, not wait.
    func testSplitterPassesThroughNonTLSVersion() {
        var splitter = FirstRecordSplitter()
        let out = splitter.feed([0x16, 0x02, 0x00])
        XCTAssertEqual(splitter.outcome, .passthrough)
        XCTAssertEqual(out, [0x16, 0x02, 0x00])
    }

    /// A short record declaration is a passthrough, and must be forwarded as
    /// soon as the decision is knowable — not held until the record completes.
    func testSplitterPassesThroughShortRecordAsSoonAsDecided() {
        let input = Self.record(payloadLength: 20)
        var splitter = FirstRecordSplitter()
        let out = splitter.feed(input)
        XCTAssertEqual(splitter.outcome, .passthrough)
        XCTAssertEqual(out, input)
    }

    /// Undecided bytes never exceed the decision window, whatever the chunk
    /// sizes. This is the bounded-memory claim, asserted rather than described.
    func testSplitterBufferNeverExceedsDecisionWindow() {
        let window = TLSRecordReframer.decisionWindow
        var splitter = FirstRecordSplitter()
        var sent = 0
        var maxBuffered = 0
        // Dribble the first 44 bytes of a large record: it can never decide
        // before byte 45, so buffering must be bounded by 44 here.
        let input = Self.record(payloadLength: 1000)
        for byte in input.prefix(window - 1) {
            let out = splitter.feed([byte])
            sent += out.count
            maxBuffered = max(maxBuffered, splitter.bufferedBytes)
        }
        XCTAssertEqual(splitter.outcome, .undecided)
        XCTAssertEqual(sent, 0, "nothing is forwarded before the decision")
        XCTAssertLessThanOrEqual(maxBuffered, window - 1)

        // The 45th byte completes the window and the split happens.
        let out = splitter.feed([input[window - 1]])
        XCTAssertEqual(splitter.outcome, .split)
        XCTAssertEqual(out.count, 5 + 40 + 5)
        XCTAssertEqual(splitter.bufferedBytes, 0)
    }

    /// The declared length is what decides, not the bytes present. A record
    /// whose header says 10 but that is followed by more data must not be
    /// split — the extra bytes are a second record, not this one's payload.
    func testSplitterTrustsDeclaredLength() {
        var input: [UInt8] = [0x16, 0x03, 0x01, 0x00, 0x0a]
        input.append(contentsOf: Array(repeating: 0xaa, count: 10))
        input.append(contentsOf: Array(repeating: 0xbb, count: 100))
        var splitter = FirstRecordSplitter()
        let out = splitter.feed(input)
        XCTAssertEqual(splitter.outcome, .passthrough)
        XCTAssertEqual(out, input)
    }

    // MARK: - CONNECT parsing

    func testParsesConnectRequest() throws {
        let head = Array("CONNECT discord.com:443 HTTP/1.1\r\nHost: discord.com:443\r\n\r\n".utf8)
        let request = try ConnectRequestParser.parse(head: head)
        XCTAssertEqual(request.host, "discord.com")
        XCTAssertEqual(request.port, 443)
        XCTAssertEqual(request.authority, "discord.com:443")
    }

    func testParsesIPv6Authority() throws {
        let head = Array("CONNECT [2606:4700::1]:8443 HTTP/1.1\r\n\r\n".utf8)
        let request = try ConnectRequestParser.parse(head: head)
        XCTAssertEqual(request.host, "2606:4700::1")
        XCTAssertEqual(request.port, 8443)
        XCTAssertEqual(request.authority, "[2606:4700::1]:8443")
    }

    func testRejectsNonConnectMethod() {
        let head = Array("GET http://discord.com/ HTTP/1.1\r\n\r\n".utf8)
        XCTAssertThrowsError(try ConnectRequestParser.parse(head: head)) { error in
            XCTAssertEqual(error as? ConnectParseError, .unsupportedMethod("GET"))
        }
    }

    func testRejectsMissingPort() {
        let head = Array("CONNECT discord.com HTTP/1.1\r\n\r\n".utf8)
        XCTAssertThrowsError(try ConnectRequestParser.parse(head: head)) { error in
            XCTAssertEqual(error as? ConnectParseError, .missingPort)
        }
    }

    func testRejectsOutOfRangePort() {
        for target in ["discord.com:0", "discord.com:65536", "discord.com:99999"] {
            let head = Array("CONNECT \(target) HTTP/1.1\r\n\r\n".utf8)
            XCTAssertThrowsError(try ConnectRequestParser.parse(head: head),
                                 "\(target) must be refused")
        }
    }

    func testRejectsHostWithPathOrSpace() {
        for target in ["discord.com/x:443", "discord com:443", "discord.com%2f:443"] {
            let head = Array("CONNECT \(target) HTTP/1.1\r\n\r\n".utf8)
            XCTAssertThrowsError(try ConnectRequestParser.parse(head: head),
                                 "\(target) must be refused")
        }
    }

    func testRejectsMalformedRequestLine() {
        for line in ["CONNECT", "CONNECT discord.com:443", "CONNECT  discord.com:443 HTTP/1.1"] {
            let head = Array("\(line)\r\n\r\n".utf8)
            XCTAssertThrowsError(try ConnectRequestParser.parse(head: head),
                                 "'\(line)' must be refused")
        }
    }

    /// A client that never sends the terminator must not be able to grow the
    /// buffer past the limit. This is the "10 MB header line" case.
    func testOversizedHeaderIsRejectedWithoutBufferingIt() {
        var reader = ConnectHeadReader(maxBytes: 1024)
        let chunk = [UInt8](repeating: 0x41, count: 4096)

        XCTAssertThrowsError(try reader.append(chunk)) { error in
            guard case .headerTooLarge(let limit)? = error as? ConnectParseError else {
                return XCTFail("expected headerTooLarge, got \(error)")
            }
            XCTAssertEqual(limit, 1024)
        }
        // The claim is about memory, so assert it: the buffer never grew.
        XCTAssertLessThanOrEqual(reader.count, 1024)
    }

    func testHeaderAtExactlyTheLimitIsAccepted() throws {
        var reader = ConnectHeadReader(maxBytes: 128)
        let body = String(repeating: "a", count: 128 - 4)
        let head = Array("\(body)\r\n\r\n".utf8)
        XCTAssertEqual(head.count, 128)
        let parsed = try reader.append(head)
        XCTAssertNotNil(parsed)
    }

    func testHeaderReaderSplitsHeadFromRemainder() throws {
        var reader = ConnectHeadReader(maxBytes: 1024)
        let head = Array("CONNECT discord.com:443 HTTP/1.1\r\n\r\n".utf8)
        let clientHello = Self.record(payloadLength: 300)
        let combined = head + clientHello

        let parsed = try XCTUnwrap(reader.append(combined))
        XCTAssertEqual(parsed.head, head)
        XCTAssertEqual(parsed.remainder, clientHello,
                       "bytes after the terminator belong to the tunnel")
    }

    func testHeaderReaderAcceptsByteAtATime() throws {
        var reader = ConnectHeadReader(maxBytes: 1024)
        let head = Array("CONNECT discord.com:443 HTTP/1.1\r\n\r\n".utf8)
        var parsed: (head: [UInt8], remainder: [UInt8])?
        for byte in head {
            parsed = try reader.append([byte])
            if parsed != nil { break }
        }
        XCTAssertEqual(parsed?.head, head)
        XCTAssertEqual(parsed?.remainder, [])
    }

    // MARK: - Live loopback tests

    /// Start a real engine on loopback, send it a CONNECT, and expect 200.
    ///
    /// The upstream is an in-process NWListener that accepts and echoes; there
    /// is no internet anywhere in this test.
    func testProxyAcceptsConnectAndReturns200() throws {
        let upstream = try FakeUpstream()
        defer { upstream.stop() }

        let engine = DPIEngine(configuration: .loopback)
        let status = try engine.start()
        defer { engine.shutdown() }
        let port = try XCTUnwrap(status.port)
        XCTAssertTrue(status.running)

        let client = try RawClient(port: port)
        defer { client.close() }

        try client.send("CONNECT 127.0.0.1:\(upstream.port) HTTP/1.1\r\n"
                        + "Host: 127.0.0.1\r\n\r\n")
        let response = try client.readUntil([0x0d, 0x0a, 0x0d, 0x0a],
                                            timeout: 5)
        let text = String(decoding: response, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 Connection Established"),
                      "got: \(text.prefix(120))")

        // A tunnel whose client half-closed stays open for the origin's reply,
        // which is the correct half-close behaviour: the slot is released when
        // both directions finish or the idle timer fires, not when the client
        // stops sending.
        XCTAssertEqual(engine.status().connections, 1)

        client.close()
        engine.shutdown()
        XCTAssertEqual(engine.status().connections, 0,
                       "shutdown must release every tunnel")
    }

    /// The whole bypass, end to end on loopback: a CONNECT carrying a synthetic
    /// ClientHello must reach the fake origin as two records whose payload
    /// concatenation equals the original.
    func testProxyReframesFirstRecordOnTheWire() throws {
        let upstream = try FakeUpstream()
        defer { upstream.stop() }

        let engine = DPIEngine(configuration: .loopback)
        let status = try engine.start()
        defer { engine.shutdown() }
        let port = try XCTUnwrap(status.port)

        let client = try RawClient(port: port)
        defer { client.close() }
        let hello = Self.record(payloadLength: 300)
        try client.send("CONNECT 127.0.0.1:\(upstream.port) HTTP/1.1\r\n\r\n")
        _ = try client.readUntil([0x0d, 0x0a, 0x0d, 0x0a], timeout: 5)
        try client.sendBytes(hello)

        let received = try XCTUnwrap(upstream.waitForBytes(5 + 40 + 5 + 260,
                                                          timeout: 5),
                                     "the origin saw nothing")
        // The split is emitted as soon as 45 bytes exist; the tail follows as
        // the client's remaining bytes are pumped. So the origin eventually sees
        // 5+40+5 bytes of the cut plus the 260-byte remainder.
        XCTAssertEqual(received.count, 5 + 40 + 5 + 260,
                       "origin must receive exactly the same number of bytes")
        let parts = Self.records(in: received)
        XCTAssertEqual(parts.count, 2, "two record headers on the wire")
        XCTAssertEqual(parts[0].payload.count, 40)
        XCTAssertEqual(parts[0].payload + parts[1].payload, Self.payload(of: hello))

        waitUntil(timeout: 5) { engine.status().reframed == 1 }
        XCTAssertEqual(engine.status().passthrough, 0)
    }

    /// A CONNECT whose tunnel carries no TLS must be passed through untouched
    /// and counted as passthrough, not as a split.
    func testProxyPassesThroughNonTLSBytes() throws {
        let upstream = try FakeUpstream()
        defer { upstream.stop() }

        let engine = DPIEngine(configuration: .loopback)
        let status = try engine.start()
        defer { engine.shutdown() }
        let port = try XCTUnwrap(status.port)

        let client = try RawClient(port: port)
        defer { client.close() }
        let plain: [UInt8] = Array("GET / HTTP/1.1\r\nHost: x\r\n\r\n".utf8)
        try client.send("CONNECT 127.0.0.1:\(upstream.port) HTTP/1.1\r\n\r\n")
        _ = try client.readUntil([0x0d, 0x0a, 0x0d, 0x0a], timeout: 5)
        try client.sendBytes(plain)

        let received = try XCTUnwrap(upstream.waitForBytes(plain.count, timeout: 5))
        XCTAssertEqual(received, plain, "plain bytes must be identical")

        waitUntil(timeout: 5) { engine.status().passthrough == 1 }
    }

    /// An oversized CONNECT head is refused with 431, and the refusal is
    /// counted. This is the limit the header reader enforces, seen through the
    /// socket.
    func testProxyRejectsOversizedHeader() throws {
        let engine = DPIEngine()
        let status = try engine.start()
        defer { engine.shutdown() }
        let port = try XCTUnwrap(status.port)

        let client = try RawClient(port: port)
        defer { client.close() }

        // 9 KiB of header, no terminator: larger than the 8 KiB limit.
        var junk = Array("CONNECT discord.com:443 HTTP/1.1\r\n".utf8)
        junk.append(contentsOf: [UInt8](repeating: 0x41, count: 9 * 1024))
        try client.sendBytes(junk)

        let response = try client.readUntil([0x0d, 0x0a], timeout: 5)
        let text = String(decoding: response, as: UTF8.self)
        XCTAssertTrue(text.contains("431"), "expected 431, got: \(text)")

        waitUntil(timeout: 5) { engine.status().rejected == 1 }
        XCTAssertEqual(engine.status().reframed, 0)
        XCTAssertEqual(engine.status().passthrough, 0)
    }

    /// A method that is not CONNECT is refused with 405, before any dial.
    func testProxyRejectsNonConnectMethod() throws {
        let engine = DPIEngine()
        let status = try engine.start()
        defer { engine.shutdown() }
        let port = try XCTUnwrap(status.port)

        let client = try RawClient(port: port)
        defer { client.close() }
        try client.send("GET http://discord.com/ HTTP/1.1\r\n\r\n")

        let response = try client.readUntil([0x0d, 0x0a], timeout: 5)
        XCTAssertTrue(String(decoding: response, as: UTF8.self).contains("405"))
        waitUntil(timeout: 5) { engine.status().rejected == 1 }
    }

    /// An unparseable CONNECT must produce a 400 and must not crash. This is the
    /// "a malformed client byte must never crash the app" rule, exercised with
    /// bytes rather than argued.
    func testProxySurvivesMalformedRequestLine() throws {
        let engine = DPIEngine()
        let status = try engine.start()
        defer { engine.shutdown() }
        let port = try XCTUnwrap(status.port)

        for index in 0..<8 {
            let client = try RawClient(port: port)
            let junk: [UInt8] = [0x00, 0xff, 0x7f, 0x16,
                                 UInt8(index), 0x0d, 0x0a, 0x0d, 0x0a]
            try client.sendBytes(junk)
            let response = try client.readUntil([0x0d, 0x0a], timeout: 5)
            let text = String(decoding: response, as: UTF8.self)
            XCTAssertTrue(text.hasPrefix("HTTP/1.1 4"),
                          "iteration \(index) got: \(text.prefix(60))")
            client.close()
        }
        // The engine is still serving.
        XCTAssertTrue(engine.status().running)
    }

    /// The idle timeout closes an established tunnel. Configured to 1 s so the
    /// test is fast; the production value and its reasoning are in
    /// `DPIEngine.Configuration`.
    func testIdleTimeoutClosesConnection() throws {
        let upstream = try FakeUpstream()
        defer { upstream.stop() }

        var config = DPIEngine.Configuration.loopback
        config.idleTimeout = 1
        let engine = DPIEngine(configuration: config)
        let status = try engine.start()
        defer { engine.shutdown() }
        let port = try XCTUnwrap(status.port)

        let client = try RawClient(port: port)
        defer { client.close() }
        try client.send("CONNECT 127.0.0.1:\(upstream.port) HTTP/1.1\r\n\r\n")
        _ = try client.readUntil([0x0d, 0x0a, 0x0d, 0x0a], timeout: 5)

        // Send nothing, then wait past the idle timeout. The client must see
        // the connection close rather than hang.
        XCTAssertTrue(client.waitForClose(timeout: 6),
                      "the idle timeout did not close the tunnel")
        waitUntil(timeout: 5) { engine.status().connections == 0 }
    }

    /// The CONNECT head timeout closes a client that opens and says nothing.
    func testHeaderTimeoutClosesSilentConnection() throws {
        var config = DPIEngine.Configuration()
        config.headerTimeout = 1
        let engine = DPIEngine(configuration: config)
        let status = try engine.start()
        defer { engine.shutdown() }
        let port = try XCTUnwrap(status.port)

        let client = try RawClient(port: port)
        defer { client.close() }
        // Connect, send nothing at all.
        XCTAssertTrue(client.waitForClose(timeout: 6),
                      "the header timeout did not close the silent connection")
    }

    /// Starting twice is refused, and the refusal names the port already in
    /// use. It must not open a second listener.
    func testSecondStartIsRefused() throws {
        let engine = DPIEngine()
        let first = try engine.start()
        defer { engine.shutdown() }

        XCTAssertThrowsError(try engine.start()) { error in
            guard case .alreadyRunning(let port)? = error as? DPIEngineError else {
                return XCTFail("expected alreadyRunning, got \(error)")
            }
            XCTAssertEqual(port, first.port)
        }
        // Still exactly one status, on the original port.
        XCTAssertEqual(engine.status().port, first.port)
    }

    /// After stop the port accepts nothing, and status says so.
    func testPortIsClosedAfterStop() throws {
        let engine = DPIEngine()
        let status = try engine.start()
        let port = try XCTUnwrap(status.port)

        // Prove it accepts while running.
        do {
            let client = try RawClient(port: port)
            client.close()
        }

        engine.stop()
        XCTAssertFalse(engine.status().running)

        // A fresh connect must fail. Retried briefly because the kernel can
        // take a moment to stop accepting after `cancel()`.
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
        XCTAssertTrue(refused, "port \(port) still accepted a connection after stop")
    }

    /// The status type reports the port and the split point, and is honest
    /// before the first start.
    func testStatusBeforeStartIsStopped() {
        let engine = DPIEngine()
        let status = engine.status()
        XCTAssertFalse(status.running)
        XCTAssertNil(status.port)
        XCTAssertNil(status.uptimeS)
        XCTAssertEqual(status.splitAt, TLSRecordReframer.firstRecordPayloadLimit)
        XCTAssertEqual(status.reframed, 0)
        XCTAssertEqual(status.passthrough, 0)
    }

    /// The status is Codable, because the UI and a future helper exchange it as
    /// JSON. A field that silently fails to encode would be a dash in the UI.
    func testStatusRoundTripsThroughJSON() throws {
        let status = DPIStatus(running: true, port: 51234, connections: 2,
                               reframed: 7, passthrough: 3, rejected: 1,
                               overCapacity: 0, uptimeS: 90, splitAt: 40,
                               lastError: nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(status)
        let decoded = try JSONDecoder().decode(DPIStatus.self, from: data)
        XCTAssertEqual(decoded, status)

        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"reframed\":7"))
        XCTAssertTrue(text.contains("\"passthrough\":3"))
        XCTAssertTrue(text.contains("\"port\":51234"))
    }

    // MARK: - Binding

    /// The listener must bind loopback only. Asserted on the parameters rather
    /// than by probing the LAN, because a test must not depend on this machine
    /// having a routable address.
    func testListenerBindsLoopbackOnly() throws {
        let parameters = DPIEngine.makeParameters()
        guard let endpoint = parameters.requiredLocalEndpoint,
              case .hostPort(let host, let port) = endpoint else {
            return XCTFail("the listener has no required local endpoint, "
                           + "so it would bind the wildcard address")
        }
        XCTAssertEqual("\(host)", "127.0.0.1")
        XCTAssertEqual(port.rawValue, 0, "port 0 means an ephemeral port")
    }

    // MARK: - Probe verdicts

    /// Every combination of direct/proxied success maps to one sentence, and
    /// none of them claims more than it observed.
    func testProbeVerdicts() {
        func outcome(direct: Bool, proxied: Bool) -> DPIProbeOutcome {
            DPIProbeOutcome(host: "discord.com",
                            direct: .init(exit: direct ? 0 : 56),
                            proxied: .init(exit: proxied ? 0 : 56))
        }

        XCTAssertEqual(outcome(direct: false, proxied: true).verdict, .working)
        XCTAssertEqual(outcome(direct: true, proxied: true).verdict, .notNeeded)
        XCTAssertEqual(outcome(direct: false, proxied: false).verdict, .notHelping)
        XCTAssertEqual(outcome(direct: true, proxied: false).verdict, .proxyBroken)

        // The working sentence must not promise that Discord will work.
        let sentence = DPIProbeOutcome.Verdict.working.sentence
        XCTAssertFalse(sentence.lowercased().contains("discord will"),
                       "a probe cannot promise the app works")
    }

    /// The probe uses the proxy for one attempt and not the other, and clears
    /// NO_PROXY on the direct attempt so the comparison is real.
    func testProbeArguments() {
        let recorder = RecordingRunner()
        _ = DPIProbe.run(port: 4444, host: "discord.com", using: recorder)
        XCTAssertEqual(recorder.calls.count, 2)

        let direct = recorder.calls[0].args
        let proxied = recorder.calls[1].args
        XCTAssertFalse(direct.contains("--proxy"),
                       "the first attempt must be direct: \(direct)")
        XCTAssertTrue(direct.contains("--noproxy"),
                      "the direct attempt must ignore NO_PROXY: \(direct)")
        XCTAssertTrue(proxied.contains("--proxy"),
                      "the second attempt must go through the proxy: \(proxied)")
        XCTAssertTrue(proxied.contains("http://127.0.0.1:4444"))
        XCTAssertFalse(proxied.contains("--noproxy"))
        // An empty --noproxy list would leave https_proxy in force.
        let flag = try? XCTUnwrap(direct.firstIndex(of: "--noproxy"))
        XCTAssertEqual(flag.map { direct[$0 + 1] }, "*")
    }

    /// No port means no comparison: the probe says the proxy is off instead of
    /// inventing a verdict, and it does not make a second request.
    func testProbeWithoutPortMakesOneAttempt() {
        let recorder = RecordingRunner()
        let outcome = DPIProbe.run(port: nil, using: recorder)
        XCTAssertEqual(recorder.calls.count, 1)
        XCTAssertEqual(outcome.verdict, .proxyOff)
    }

    /// curl's exit codes become fixed sentences, never raw output.
    func testProbeErrorDescriptions() {
        XCTAssertEqual(DPIProbe.describe(exit: 28, output: ""), "timed out")
        XCTAssertEqual(DPIProbe.describe(exit: 56, output: ""),
                       "connection reset during transfer")
        XCTAssertEqual(DPIProbe.describe(exit: 7, output: ""), "could not connect")
        // Anything unknown still produces a sentence, and it is bounded.
        let long = String(repeating: "x", count: 500)
        XCTAssertEqual(DPIProbe.describe(exit: 99, output: long), "curl exit 99")
    }

    // MARK: - Discord launch

    func testDiscordArguments() {
        XCTAssertEqual(DiscordLauncher.arguments(port: 51234),
                       ["-a", "Discord",
                        "--args", "--proxy-server=http://127.0.0.1:51234"])
    }

    func testDiscordRefusesWhenProxyIsStopped() {
        XCTAssertEqual(DiscordLauncher.preflight(port: nil),
                       .failure(.proxyNotRunning))
        XCTAssertEqual(DiscordLauncher.preflight(port: 0),
                       .failure(.invalidPort(0)))
        XCTAssertEqual(DiscordLauncher.preflight(port: 70000),
                       .failure(.invalidPort(70000)))
    }

    /// The already-running refusal is the one that prevents a click from doing
    /// nothing, so it is asserted separately from the port checks.
    func testDiscordRefusesWhenAlreadyRunning() {
        XCTAssertEqual(DiscordLauncher.preflight(port: 5000, discordRunning: true),
                       .failure(.alreadyRunning))
    }

    func testDiscordLaunchRunsOpenWithTheFlag() {
        let recorder = RecordingRunner()
        let result = DiscordLauncher.launch(port: 5000, using: recorder)
        XCTAssertEqual(try? result.get(),
                       ["-a", "Discord",
                        "--args", "--proxy-server=http://127.0.0.1:5000"])
        XCTAssertEqual(recorder.calls.count, 1)
        XCTAssertEqual(recorder.calls[0].tool, "open")
    }

    func testDiscordUpdateDeadlineIsAddedOnceAndKeepsOtherKeys() throws {
        let original = Data(##"{"BACKGROUND_COLOR":"#202225","IS_MAXIMIZED":true}"##.utf8)
        let updated = try XCTUnwrap(DiscordLauncher.settingsAddingUpdateDeadline(original))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: updated) as? [String: Any])
        XCTAssertEqual(json[DiscordLauncher.updateDeadlineKey] as? Int, 10_000)
        XCTAssertEqual(json["BACKGROUND_COLOR"] as? String, "#202225")
        XCTAssertEqual(json["IS_MAXIMIZED"] as? Bool, true)
        // Already present (ours or the user's): never rewritten.
        XCTAssertNil(DiscordLauncher.settingsAddingUpdateDeadline(updated))
        XCTAssertNil(DiscordLauncher.settingsAddingUpdateDeadline(
            Data(#"{"DESKTOP_TTI_UPDATE_CHECK_DEADLINE_MS":0}"#.utf8)))
        XCTAssertNil(DiscordLauncher.settingsAddingUpdateDeadline(Data("not json".utf8)))
    }

    func testDiscordUpdateFailOpenWritesFileOnlyWhenItExists() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("settings.json")

        XCTAssertEqual(DiscordLauncher.allowUpdateFailOpen(settings: file), .noSettings)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        try Data("{}".utf8).write(to: file)
        XCTAssertEqual(DiscordLauncher.allowUpdateFailOpen(settings: file), .written)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(json[DiscordLauncher.updateDeadlineKey] as? Int, 10_000)
        XCTAssertEqual(DiscordLauncher.allowUpdateFailOpen(settings: file), .unchanged)
    }

    /// A file we may not read (stand-in for a TCC denial) is reported, not
    /// swallowed, so the app can tell the user why the splash may hang.
    func testDiscordUpdateFailOpenReportsDenial() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("settings.json")
        try Data("{}".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            try? FileManager.default.removeItem(at: dir)
        }
        guard case .denied = DiscordLauncher.allowUpdateFailOpen(settings: file) else {
            return XCTFail("unreadable settings must be reported as denied")
        }
    }

    /// The file is touched at most once per path: done or denied means skip,
    /// until the path changes or the user asks to try again.
    func testDiscordFailOpenMemory() throws {
        let suite = "menfez.test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let memory = DiscordLauncher.FailOpenMemory(defaults)
        let a = URL(fileURLWithPath: "/nonexistent/a/settings.json")
        let b = URL(fileURLWithPath: "/nonexistent/b/settings.json")

        XCTAssertTrue(memory.shouldTry(a))
        memory.record(.noSettings, for: a)
        XCTAssertTrue(memory.shouldTry(a), "Discord never ran: try next time")
        memory.record(.failed("disk"), for: a)
        XCTAssertTrue(memory.shouldTry(a))

        memory.record(.written, for: a)
        XCTAssertFalse(memory.shouldTry(a))
        XCTAssertTrue(memory.shouldTry(b), "a new settings path is tried again")
        memory.record(.unchanged, for: b)
        XCTAssertFalse(memory.shouldTry(b))
        XCTAssertFalse(memory.showsHint)

        let c = URL(fileURLWithPath: "/nonexistent/c/settings.json")
        memory.record(.denied("Operation not permitted"), for: c)
        XCTAssertFalse(memory.shouldTry(c), "denied: no automatic retry")
        XCTAssertTrue(memory.showsHint)
        memory.dismissHint()
        XCTAssertFalse(memory.showsHint)
        XCTAssertFalse(memory.shouldTry(c))

        memory.reset()
        XCTAssertTrue(memory.shouldTry(c), "reset allows one more try")
        memory.record(.denied("again"), for: c)
        XCTAssertFalse(memory.shouldTry(c), "denied again: stop again")
        XCTAssertTrue(memory.showsHint, "a fresh denial shows the hint again")
    }

    func testPermissionDeniedClassification() {
        XCTAssertTrue(DiscordLauncher.isPermissionDenied(CocoaError(.fileReadNoPermission)))
        XCTAssertTrue(DiscordLauncher.isPermissionDenied(
            NSError(domain: NSCocoaErrorDomain, code: 256,
                    userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])))
        XCTAssertFalse(DiscordLauncher.isPermissionDenied(CocoaError(.fileReadCorruptFile)))
    }

    func testDiscordLaunchReportsMissingApp() {
        let recorder = RecordingRunner()
        recorder.answer = CommandResult(status: 1,
                                       output: "Unable to find application named Discord")
        let result = DiscordLauncher.launch(port: 5000, using: recorder)
        XCTAssertEqual(try? result.get(), nil)
        XCTAssertEqual(result.failure, .notInstalled)
    }

    // MARK: - Mode conflict

    func testDPIRefusesWhileTunnelIsUp() {
        XCTAssertNil(DPIConflict.refusal(interfaces: []))
        XCTAssertEqual(DPIConflict.refusal(interfaces: ["utun5"]),
                       DPIConflict.tunnelIsUpMessage)
    }

    // MARK: - Port reuse (Y7)

    /// In-memory defaults, so the test never reads or writes the runner's
    /// real preferences and leaves no plist behind (a `suiteName` store does,
    /// even after `removePersistentDomain`).
    private func freshPortStore() -> UserDefaults { MemoryDefaults() }

    /// A Discord launched against the first run's port must still find the
    /// proxy there after a stop/start — and after a new engine (app restart).
    func testRestartReusesTheSamePort() throws {
        let store = freshPortStore()
        let first = DPIEngine(portStore: store)
        let port = try XCTUnwrap(first.start().port)
        XCTAssertFalse(first.portChanged)
        first.stop()

        XCTAssertEqual(try first.start().port, port, "off/on must keep the port")
        XCTAssertFalse(first.portChanged)
        first.shutdown()

        let relaunched = DPIEngine(portStore: store)
        defer { relaunched.shutdown() }
        XCTAssertEqual(try relaunched.start().port, port, "a restart must keep the port")
        XCTAssertFalse(relaunched.portChanged)
    }

    /// When the remembered port is taken, the engine still starts — on another
    /// port — and says the port changed so the UI can ask for a Discord restart.
    func testBusyPortFallsBackAndReportsChange() throws {
        let store = freshPortStore()
        let squatter = DPIEngine()
        defer { squatter.shutdown() }
        let taken = try XCTUnwrap(squatter.start().port)
        store.set(taken, forKey: DPIEngine.portDefaultsKey)

        let engine = DPIEngine(portStore: store)
        defer { engine.shutdown() }
        let port = try XCTUnwrap(engine.start().port)
        XCTAssertNotEqual(port, taken)
        XCTAssertTrue(engine.portChanged)
        XCTAssertNil(engine.status().lastError, "the fallback is not an error")
        XCTAssertEqual(store.integer(forKey: DPIEngine.portDefaultsKey), port,
                       "the new port is the one remembered next time")
    }

    // MARK: - Drain on stop (Y9)

    /// Leaving DPI mode must actually end proxied traffic: a tunnel kept alive
    /// by heartbeats gets the drain window, then is closed and uncounted.
    func testStopClosesEstablishedTunnelsAfterDrain() throws {
        let upstream = try FakeUpstream()
        defer { upstream.stop() }

        var config = DPIEngine.Configuration.loopback
        config.drainTimeout = 1
        let engine = DPIEngine(configuration: config)
        defer { engine.shutdown() }
        let port = try XCTUnwrap(engine.start().port)

        let client = try RawClient(port: port)
        defer { client.close() }
        try client.send("CONNECT 127.0.0.1:\(upstream.port) HTTP/1.1\r\n\r\n")
        _ = try client.readUntil([0x0d, 0x0a, 0x0d, 0x0a], timeout: 5)
        XCTAssertEqual(engine.status().connections, 1)

        engine.stop()
        XCTAssertFalse(engine.status().running)
        XCTAssertEqual(engine.status().connections, 1,
                       "an in-flight tunnel gets the drain window, not an instant kill")

        XCTAssertTrue(client.waitForClose(timeout: 5),
                      "the tunnel must be closed once the drain window ends")
        waitUntil(timeout: 5) { engine.status().connections == 0 }
    }

    // MARK: - Target policy

    func testPolicyAllowsOnlyPublic443() {
        func refusal(_ host: String, _ port: Int = 443) -> String? {
            ConnectRequest(host: host, port: port).policyRefusal
        }
        for ok in ["discord.com", "gateway.discord.gg", "162.159.128.233",
                   "2606:4700::6810:1", "my_host.example.com", "8.8.8.8"] {
            XCTAssertNil(refusal(ok), ok)
        }
        XCTAssertNotNil(refusal("discord.com", 80))
        XCTAssertNotNil(refusal("discord.com", 22))
        for bad in ["127.0.0.1", "127.9.9.9", "10.0.0.1", "172.16.0.1", "172.31.255.255",
                    "192.168.1.1", "100.64.0.1", "169.254.169.254", "0.0.0.0",
                    "224.0.0.1", "::1", "::", "fc00::1", "fd12::1", "fe80::1",
                    "::ffff:127.0.0.1", "localhost", "LOCALHOST.", "printer.local",
                    "a.localhost", "127.1", "2130706433", "0x7f.0.0.1", "010.0.0.1"] {
            XCTAssertNotNil(refusal(bad), bad)
        }
        // Edges of the ranges stay public.
        for edge in ["172.32.0.1", "100.128.0.1", "11.0.0.1", "192.169.0.1"] {
            XCTAssertNil(refusal(edge), edge)
        }
    }

    func testIPv6LiteralsParseAndLoopbackIsRefused() throws {
        let loop = try ConnectRequestParser.parse(
            head: Array("CONNECT [::1]:443 HTTP/1.1\r\n\r\n".utf8))
        XCTAssertEqual(loop.host, "::1")
        XCTAssertNotNil(loop.policyRefusal)

        let pub = try ConnectRequestParser.parse(
            head: Array("CONNECT [2606:4700::1]:443 HTTP/1.1\r\n\r\n".utf8))
        XCTAssertEqual(pub.host, "2606:4700::1")
        XCTAssertNil(pub.policyRefusal)
    }

    /// Through the socket: local and non-443 targets get 403 and no dial.
    func testProxyRefusesLocalTargetsWith403() throws {
        let engine = DPIEngine()
        defer { engine.shutdown() }
        let port = try XCTUnwrap(engine.start().port)

        for target in ["127.0.0.1:22", "[::1]:443", "localhost:443",
                       "192.168.1.1:443", "discord.com:25"] {
            let client = try RawClient(port: port)
            defer { client.close() }
            try client.send("CONNECT \(target) HTTP/1.1\r\n\r\n")
            let text = String(decoding: try client.readUntil([0x0d, 0x0a, 0x0d, 0x0a],
                                                             timeout: 5), as: UTF8.self)
            XCTAssertTrue(text.hasPrefix("HTTP/1.1 403"), "\(target): \(text.prefix(80))")
        }
        waitUntil(timeout: 5) { engine.status().rejected == 5 }
    }

    // MARK: - Configurable split point

    func testSplitterAndReframerHonourLimit() throws {
        let hello = Self.record(payloadLength: 100)
        let one = try XCTUnwrap(TLSRecordReframer.reframe(record: hello, limit: 10))
        XCTAssertEqual(one.firstPayloadLength, 10)
        XCTAssertEqual(one.secondPayloadLength, 90)

        var splitter = FirstRecordSplitter(limit: 10)
        let out = splitter.feed(hello)
        XCTAssertEqual(splitter.outcome, .split)
        XCTAssertEqual(out, one.bytes)

        XCTAssertEqual(FirstRecordSplitter(limit: 0).limit,
                       TLSRecordReframer.firstRecordPayloadLimit)
    }

    func testSplitLimitComesFromDefaultsWhenInRange() {
        let store = freshPortStore()
        XCTAssertEqual(DPIEngine(portStore: store).status().splitAt, 40, "absent: default")
        store.set(12, forKey: DPIEngine.splitDefaultsKey)
        XCTAssertEqual(DPIEngine(portStore: store).status().splitAt, 12)
        for bad in [0, -5, 201, 5000] {
            store.set(bad, forKey: DPIEngine.splitDefaultsKey)
            XCTAssertEqual(DPIEngine(portStore: store).status().splitAt, 40, "\(bad)")
        }
        var config = DPIEngine.Configuration()
        config.firstRecordPayloadLimit = 7
        XCTAssertEqual(DPIEngine(configuration: config).splitAt, 7)
    }

    func testEngineSplitsAtConfiguredLimitOnTheWire() throws {
        let upstream = try FakeUpstream()
        defer { upstream.stop() }
        var config = DPIEngine.Configuration.loopback
        config.firstRecordPayloadLimit = 10
        let engine = DPIEngine(configuration: config)
        defer { engine.shutdown() }
        let port = try XCTUnwrap(engine.start().port)

        let client = try RawClient(port: port)
        defer { client.close() }
        let hello = Self.record(payloadLength: 300)
        try client.send("CONNECT 127.0.0.1:\(upstream.port) HTTP/1.1\r\n\r\n")
        _ = try client.readUntil([0x0d, 0x0a, 0x0d, 0x0a], timeout: 5)
        try client.sendBytes(hello)

        let received = try XCTUnwrap(upstream.waitForBytes(5 + 10 + 5 + 290, timeout: 5))
        let parts = Self.records(in: received)
        XCTAssertEqual(parts.map(\.payload.count), [10, 290])
    }

    // MARK: - Refusal paths and half-close

    func testHostWithUnderscoreParses() throws {
        let request = try ConnectRequestParser.parse(
            head: Array("CONNECT my_host.example.com:443 HTTP/1.1\r\n\r\n".utf8))
        XCTAssertEqual(request.host, "my_host.example.com")
    }

    func testUpstreamDialUsesConfiguredTimeout() {
        XCTAssertEqual(DPIEngine.tcpOptions(connectTimeout: 3).connectionTimeout, 3)
        XCTAssertEqual(DPIEngine.tcpOptions(connectTimeout: 0.2).connectionTimeout, 1)
    }

    /// A dial that cannot complete is answered 502 (refused) or 504 (timed
    /// out), counted as a refusal, and releases its slot.
    func testDialFailureIsAnsweredAndCounted() throws {
        let closedPort: Int = try {
            let probe = try FakeUpstream()
            let port = probe.port
            probe.stop()
            usleep(100_000)
            return port
        }()
        var config = DPIEngine.Configuration.loopback
        config.connectTimeout = 2
        let engine = DPIEngine(configuration: config)
        defer { engine.shutdown() }
        let port = try XCTUnwrap(engine.start().port)

        let client = try RawClient(port: port)
        defer { client.close() }
        try client.send("CONNECT 127.0.0.1:\(closedPort) HTTP/1.1\r\n\r\n")
        let text = String(decoding: try client.readUntil([0x0d, 0x0a, 0x0d, 0x0a],
                                                         timeout: 6), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 502") || text.hasPrefix("HTTP/1.1 504"),
                      "got: \(text.prefix(80))")
        XCTAssertTrue(client.waitForClose(timeout: 5))
        waitUntil(timeout: 5) { engine.status().connections == 0 }
        XCTAssertEqual(engine.status().rejected, 1)
    }

    /// Over the cap, a new client gets 503 before any tunnel is allocated.
    func testOverCapacityIsAnswered503() throws {
        var config = DPIEngine.Configuration()
        config.maxConnections = 1
        let engine = DPIEngine(configuration: config)
        defer { engine.shutdown() }
        let port = try XCTUnwrap(engine.start().port)

        let first = try RawClient(port: port)   // holds the only slot, says nothing
        defer { first.close() }
        waitUntil(timeout: 5) { engine.status().connections == 1 }

        let second = try RawClient(port: port)
        defer { second.close() }
        let text = String(decoding: try second.readUntil([0x0d, 0x0a, 0x0d, 0x0a],
                                                         timeout: 5), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 503"), "got: \(text.prefix(80))")
        XCTAssertEqual(engine.status().overCapacity, 1)
        XCTAssertEqual(engine.status().connections, 1)
    }

    /// The client's FIN reaches the origin — after any bytes still held by an
    /// undecided splitter — and the origin's FIN reaches the client; with both
    /// done the slot is released.
    func testHalfCloseFlushesPendingAndPropagatesBothWays() throws {
        let upstream = try FakeUpstream()
        defer { upstream.stop() }
        let engine = DPIEngine(configuration: .loopback)
        defer { engine.shutdown() }
        let port = try XCTUnwrap(engine.start().port)

        let client = try RawClient(port: port)
        defer { client.close() }
        try client.send("CONNECT 127.0.0.1:\(upstream.port) HTTP/1.1\r\n\r\n")
        _ = try client.readUntil([0x0d, 0x0a, 0x0d, 0x0a], timeout: 5)

        // Three bytes of a TLS header: too few for the split decision.
        try client.sendBytes([0x16, 0x03, 0x01])
        usleep(100_000)
        client.shutdownWrite()

        XCTAssertEqual(upstream.waitForBytes(3, timeout: 5), [0x16, 0x03, 0x01],
                       "bytes buffered before the FIN were dropped")
        waitUntil(timeout: 5) { upstream.sawEOF }
        XCTAssertTrue(client.waitForClose(timeout: 5), "origin FIN did not reach the client")
        waitUntil(timeout: 5) { engine.status().connections == 0 }
        XCTAssertEqual(engine.status().passthrough, 1)
    }

    // MARK: - Listener death after start

    /// A listener that dies on its own must not leave status saying running.
    func testListenerDeathAfterStartIsReported() throws {
        let engine = DPIEngine()
        defer { engine.shutdown() }
        try engine.start()
        let listener = try XCTUnwrap(engine.currentListener)

        listener.cancel()   // not via stop(): the engine did not ask for this
        waitUntil(timeout: 5) { !engine.status().running }
        XCTAssertNil(engine.status().port)
        XCTAssertNotNil(engine.status().lastError)
        XCTAssertNoThrow(try engine.start(), "a dead listener must not block a restart")
    }

    /// Our own stop is not a death: no error is recorded.
    func testStopRecordsNoListenerError() throws {
        let engine = DPIEngine()
        try engine.start()
        engine.stop()
        usleep(200_000)
        XCTAssertNil(engine.status().lastError)
    }

    // MARK: - Upstream failure after the 200

    /// An origin that resets an established tunnel must close it, not write an
    /// HTTP 502 into the client's TLS stream or count it as a dial failure.
    func testUpstreamResetAfterEstablishedClosesWithoutHTTP() throws {
        let origin = try ResettingUpstream(resetAfter: 0.3)
        defer { origin.stop() }

        let engine = DPIEngine(configuration: .loopback)
        defer { engine.shutdown() }
        let port = try XCTUnwrap(engine.start().port)

        let client = try RawClient(port: port)
        defer { client.close() }
        try client.send("CONNECT 127.0.0.1:\(origin.port) HTTP/1.1\r\n\r\n")
        let head = try client.readUntil([0x0d, 0x0a, 0x0d, 0x0a], timeout: 5)
        XCTAssertTrue(String(decoding: head, as: UTF8.self)
                        .hasPrefix("HTTP/1.1 200"))

        // Everything after the 200 until close: must contain no HTTP response.
        let rest = try client.readUntil(Array("never".utf8), timeout: 5)
        XCTAssertFalse(String(decoding: rest, as: UTF8.self).contains("HTTP/1.1"),
                       "HTTP written into an established tunnel: \(rest)")
        waitUntil(timeout: 5) { engine.status().connections == 0 }
        XCTAssertEqual(engine.status().rejected, 0,
                       "an established tunnel that ends is not a refusal")
    }

    // MARK: - Helpers

    /// Block until `condition` is true or the deadline passes.
    ///
    /// Used instead of a fixed sleep so a fast machine is not padded and a slow
    /// one is not flaky.
    private func waitUntil(timeout: TimeInterval,
                           _ condition: () -> Bool,
                           file: StaticString = #filePath,
                           line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            usleep(20_000)
        }
        XCTFail("condition not met within \(timeout) s", file: file, line: line)
    }
}

// MARK: - Test doubles

/// A `CommandRunner` that records argv and answers from a table.
final class RecordingRunner: CommandRunner, @unchecked Sendable {
    struct Call: Equatable {
        let tool: String
        let args: [String]
        var joined: String { ([tool] + args).joined(separator: " ") }
    }

    private let lock = NSLock()
    private var storage: [Call] = []

    /// Answer for every call. Set before the code under test runs.
    var answer = CommandResult(status: 0, output: "")

    var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func run(_ tool: String, _ args: [String], timeout: TimeInterval) -> CommandResult {
        lock.lock()
        storage.append(Call(tool: tool, args: args))
        let response = answer
        lock.unlock()
        return response
    }
}

/// An in-process TCP server that stands in for the origin.
///
/// It accepts any number of connections and accumulates what they send, so a
/// test can assert on exact bytes without a real network.
final class FakeUpstream {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "test.upstream")
    private let lock = NSLock()
    private var accumulated = Data()
    private var eof = false

    /// True once a client half-closed its side.
    var sawEOF: Bool {
        lock.lock(); defer { lock.unlock() }
        return eof
    }

    /// The bound port. Computed from the listener so there is no initialisation
    /// order to get wrong between the listener and the closures that reference
    /// `self`.
    var port: Int { Int(listener.port?.rawValue ?? 0) }

    init() throws {
        let parameters = NWParameters(tls: nil, tcp: DPIEngine.tcpOptions())
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host("127.0.0.1"), port: .any)
        guard let listener = try? NWListener(using: parameters) else {
            throw XCTSkip("could not bind a loopback test server")
        }
        self.listener = listener

        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.receiveLoop(connection)
        }
        listener.start(queue: queue)
        if ready.wait(timeout: .now() + 3) == .timedOut {
            listener.cancel()
            throw XCTSkip("the loopback test server did not become ready")
        }
        guard listener.port != nil else {
            listener.cancel()
            throw XCTSkip("the loopback test server got no port")
        }
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.lock.lock()
                self.accumulated.append(data)
                self.lock.unlock()
            }
            if isComplete {
                // Answer a half-close with our own FIN, like a server that
                // has nothing more to say.
                self.lock.lock(); self.eof = true; self.lock.unlock()
                connection.send(content: nil, contentContext: .finalMessage,
                                isComplete: true, completion: .contentProcessed { _ in })
                return
            }
            if error != nil { return }
            self.receiveLoop(connection)
        }
    }

    /// Wait until at least `count` bytes have arrived, then return everything.
    ///
    /// Returns nil on timeout rather than asserting, so the caller can choose
    /// the failure message.
    func waitForBytes(_ count: Int, timeout: TimeInterval) -> [UInt8]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let snapshot = accumulated
            lock.unlock()
            if snapshot.count >= count { return [UInt8](snapshot) }
            usleep(20_000)
        }
        lock.lock()
        let snapshot = accumulated
        lock.unlock()
        return snapshot.isEmpty ? nil : [UInt8](snapshot)
    }

    func stop() {
        listener.cancel()
    }
}

/// A minimal POSIX TCP client for the tests.
///
/// POSIX rather than NWConnection because the assertions are about raw bytes
/// and a blocking `read` is the clearest way to write them.
final class RawClient {
    private var fd: Int32 = -1

    init(port: Int) throws {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw ClientError.socket }
        fd = socketFD

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(socketFD, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            fd = -1
            throw ClientError.connect
        }

        // A receive timeout keeps `readUntil` from hanging a test forever.
        var tv = timeval(tv_sec: 6, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv,
                   socklen_t(MemoryLayout<timeval>.size))
    }

    enum ClientError: Error { case socket, connect }

    func send(_ text: String) throws {
        try sendBytes(Array(text.utf8))
    }

    func sendBytes(_ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return write(fd, base.advanced(by: offset), bytes.count - offset)
            }
            if written <= 0 { throw ClientError.connect }
            offset += written
        }
    }

    /// Read until the terminator appears, and return everything read so far.
    func readUntil(_ terminator: [UInt8], timeout: TimeInterval) throws -> [UInt8] {
        let deadline = Date().addingTimeInterval(timeout)
        var collected: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)

        while Date() < deadline {
            if collected.count >= terminator.count,
               contains(collected, terminator) {
                return collected
            }
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                collected.append(contentsOf: buffer[0..<count])
            } else if count == 0 {
                return collected
            } else {
                break
            }
        }
        return collected
    }

    /// Wait for the peer to close the connection.
    func waitForClose(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            let count = read(fd, &buffer, buffer.count)
            if count == 0 { return true }
            if count < 0 {
                // SO_RCVTIMEO expired; try again until the deadline.
                continue
            }
        }
        return false
    }

    /// Send FIN but keep reading.
    func shutdownWrite() {
        guard fd >= 0 else { return }
        Darwin.shutdown(fd, SHUT_WR)
    }

    func close() {
        guard fd >= 0 else { return }
        Darwin.close(fd)
        fd = -1
    }

    deinit { close() }

    private func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count) where
            haystack[start..<(start + needle.count)].elementsEqual(needle) {
            return true
        }
        return false
    }
}

extension DPIEngine.Configuration {
    /// Production settings, except that loopback fake origins may be dialled.
    static var loopback: Self {
        var config = Self()
        config.restrictTargets = false
        return config
    }
}

/// UserDefaults that keeps everything in a dictionary and never touches disk.
final class MemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]

    init() { super.init(suiteName: nil)! }

    override func object(forKey key: String) -> Any? { values[key] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func set(_ value: Int, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values[key] = nil }
    override func integer(forKey key: String) -> Int {
        (values[key] as? Int) ?? 0
    }
}

/// A POSIX loopback origin that accepts one connection and, after a delay,
/// closes it with SO_LINGER 0 — a TCP RST rather than a FIN.
final class ResettingUpstream {
    private var fd: Int32 = -1
    let port: Int

    init(resetAfter delay: TimeInterval) throws {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw XCTSkip("no socket") }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(socketFD, sa, length) == 0 && listen(socketFD, 4) == 0
                    && getsockname(socketFD, sa, &length) == 0
            }
        }
        guard bound else { Darwin.close(socketFD); throw XCTSkip("could not bind") }
        fd = socketFD
        port = Int(UInt16(bigEndian: address.sin_port))

        Thread.detachNewThread {
            let accepted = accept(socketFD, nil, nil)
            guard accepted >= 0 else { return }
            Thread.sleep(forTimeInterval: delay)
            var linger = Darwin.linger(l_onoff: 1, l_linger: 0)
            setsockopt(accepted, SOL_SOCKET, SO_LINGER, &linger,
                       socklen_t(MemoryLayout<Darwin.linger>.size))
            Darwin.close(accepted)
        }
    }

    func stop() {
        guard fd >= 0 else { return }
        Darwin.close(fd)
        fd = -1
    }
}

private extension Result {
    /// The failure value, or nil when the result succeeded.
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
