import Foundation
import XCTest
@testable import MenfezCore

/// Answers from a table; a missing name is a failed lookup.
private struct FakeResolver: HostResolver {
    let table: [String: [String]]
    func resolve(_ host: String, completion: @escaping @Sendable ([String]?) -> Void) {
        completion(table[host])
    }
}

final class DoHResolverTests: XCTestCase {

    /// A wire-format answer: the question for x.com, then `records` as
    /// (type, ttl, rdata), each named by a pointer to the question.
    private func answer(rcode: UInt8 = 0, _ records: [(UInt16, UInt32, [UInt8])]) -> Data {
        var b: [UInt8] = [0, 0, 0x81, 0x80 | rcode, 0, 1, 0, UInt8(records.count), 0, 0, 0, 0]
        b += [1] + Array("x".utf8) + [3] + Array("com".utf8) + [0, 0, 1, 0, 1]
        for (type, ttl, rdata) in records {
            b += [0xc0, 12, UInt8(type >> 8), UInt8(type & 0xff), 0, 1,
                  UInt8(ttl >> 24), UInt8(ttl >> 16 & 0xff), UInt8(ttl >> 8 & 0xff), UInt8(ttl & 0xff),
                  0, UInt8(rdata.count)] + rdata
        }
        return Data(b)
    }

    func testParseKeepsARecordsAndLowestTTL() throws {
        let data = answer([(5, 30, [1, 0x79, 0xc0, 14]),
                           (1, 113, [162, 159, 135, 232]),
                           (1, 90, [162, 159, 136, 232])])
        let parsed = try XCTUnwrap(DoHResolver.parse(data))
        XCTAssertEqual(parsed.addresses, ["162.159.135.232", "162.159.136.232"])
        XCTAssertEqual(parsed.ttl, 90)
    }

    func testParseRejectsFailuresAndJunk() {
        let good = answer([(1, 5, [1, 2, 3, 4])])
        for data in [answer(rcode: 3, []), answer([]),
                     answer([(5, 5, [1, 0x79, 0])]),
                     good.prefix(good.count - 2), Data("garbage".utf8), Data()] {
            XCTAssertNil(DoHResolver.parse(data), "\([UInt8](data))")
        }
    }

    func testAddressLiteralsAreNotResolved() {
        XCTAssertTrue(ConnectRequest(host: "162.159.135.232", port: 443).isAddressLiteral)
        XCTAssertTrue(ConnectRequest(host: "2606:4700::1", port: 443).isAddressLiteral)
        XCTAssertFalse(ConnectRequest(host: "discord.com", port: 443).isAddressLiteral)
    }

    /// The proxy dials the address the resolver gave, not the name.
    func testEngineDialsTheResolvedAddress() throws {
        let upstream = try FakeUpstream()
        defer { upstream.stop() }
        var config = DPIEngine.Configuration.loopback
        config.resolver = FakeResolver(table: ["blocked-dns.example": ["127.0.0.1"]])
        let engine = DPIEngine(configuration: config)
        defer { engine.shutdown() }
        let port = try XCTUnwrap(engine.start().port)

        let client = try RawClient(port: port)
        defer { client.close() }
        try client.send("CONNECT blocked-dns.example:\(upstream.port) HTTP/1.1\r\n\r\n")
        let head = String(decoding: try client.readUntil([0x0d, 0x0a, 0x0d, 0x0a], timeout: 5),
                          as: UTF8.self)
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 200"), head)
        try client.send("ping")
        XCTAssertNotNil(upstream.waitForBytes(4, timeout: 5), "the origin saw nothing")
    }

    /// A public-looking name that resolves to a private address is refused.
    func testNameResolvingToPrivateAddressIsRefused() throws {
        var config = DPIEngine.Configuration()
        config.resolver = FakeResolver(table: ["evil.example": ["162.159.1.1", "10.0.0.5"]])
        let engine = DPIEngine(configuration: config)
        defer { engine.shutdown() }
        let port = try XCTUnwrap(engine.start().port)

        let client = try RawClient(port: port)
        defer { client.close() }
        try client.send("CONNECT evil.example:443 HTTP/1.1\r\n\r\n")
        let head = String(decoding: try client.readUntil([0x0d, 0x0a, 0x0d, 0x0a], timeout: 5),
                          as: UTF8.self)
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 403"), head)
        let deadline = Date().addingTimeInterval(5)
        while engine.status().rejected < 1, Date() < deadline { usleep(20_000) }
        XCTAssertEqual(engine.status().rejected, 1)
    }

    // MARK: - Probe wording

    func testProbeSaysDNSBlockedWhenTheNameNeverResolved() {
        let dns = DPIProbeOutcome(host: "discord.com",
                                  direct: .init(exit: 28, error: DPIProbe.describe(
                                      exit: 28, output: "curl: (28) Resolving timed out after 5000 ms")),
                                  proxied: .init(exit: 56, error: "x"))
        XCTAssertEqual(dns.verdict, .dnsBlocked)
        let tls = DPIProbeOutcome(host: "discord.com",
                                  direct: .init(exit: 35, error: DPIProbe.describe(exit: 35, output: "")),
                                  proxied: .init(exit: 56, error: "x"))
        XCTAssertEqual(tls.verdict, .notHelping)
    }

    func testProbeDirectAttemptUsesDoHWhenAsked() {
        let recorder = RecordingRunner()
        _ = DPIProbe.run(port: 4444, doh: true, using: recorder)
        XCTAssertTrue(recorder.calls[0].args.contains("--doh-url"))
        XCTAssertFalse(recorder.calls[1].args.contains("--doh-url"), "the proxy resolves itself")
    }

    func testDiscordRowNamesAProxyRefusal() {
        XCTAssertEqual(Probes.classify(exit: 56, timedOut: false,
                                       output: "curl: (56) CONNECT tunnel failed, response 504"),
                       .proxy)
        XCTAssertEqual(Probes.classify(exit: 56, timedOut: false,
                                       output: "curl: (56) Recv failure: Connection reset by peer"),
                       .blocked)
    }

    // MARK: - Live

    /// The real thing: engine on an ephemeral port, real DoH, curl through it
    /// to https://discord.com. Needs the internet, so it runs only with
    /// MENFEZ_LIVE_DOH=1.
    func testLiveDiscordThroughProxy() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MENFEZ_LIVE_DOH"] == "1",
                          "set MENFEZ_LIVE_DOH=1 to run")
        let engine = DPIEngine()
        defer { engine.shutdown() }
        let port = try XCTUnwrap(engine.start().port)

        let curl = Process()
        curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        curl.arguments = ["-sS", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "15",
                          "-x", "http://127.0.0.1:\(port)", "https://discord.com"]
        let out = Pipe()
        curl.standardOutput = out
        try curl.run()
        curl.waitUntilExit()
        let code = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let status = engine.status()
        print("LIVE: http=\(code) port=\(port) split=\(status.reframed) rejected=\(status.rejected)")
        XCTAssertEqual(code, "200")
        XCTAssertEqual(status.reframed, 1)
    }
}
