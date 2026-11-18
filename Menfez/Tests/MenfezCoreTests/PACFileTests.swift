import XCTest
@testable import MenfezCore

/// The browser PAC (1.0.8): what goes in, what is kept out, and which
/// requests the engine answers with it.
final class PACFileTests: XCTestCase {

    func testListedSitesAndSubdomainsGoThroughTheProxyOverHTTPSOnly() {
        let script = PACFile.script(entries: ["example.com", "Twitter.COM", "1.1.1.1"], port: 52100)
        XCTAssertTrue(script.contains("var sites = [\"example.com\", \"twitter.com\", \"1.1.1.1\"];"), script)
        XCTAssertTrue(script.contains("host == sites[i] || dnsDomainIs(host, \".\" + sites[i])"))
        XCTAssertTrue(script.contains("return \"PROXY 127.0.0.1:52100; DIRECT\";"))
        XCTAssertTrue(script.contains("\"https:\""))
        XCTAssertTrue(script.hasSuffix("return \"DIRECT\";\n}\n"))
    }

    func testEmptyListIsAllDirect() {
        XCTAssertTrue(PACFile.script(entries: [], port: 5000).contains("var sites = [];"))
    }

    func testOnlySafeCharactersReachTheScript() {
        let attacks = [
            "a.com\"); alert(1); (\"",
            "a.com\\\"",
            "a.com\nfunction FindProxyForURL(){return \"PROXY evil:1\"}",
            "a.com'",
            "a.com</script>",
            "a.com;b.com",
            "*.example.com",
            "2606:4700::1111",
            "192.168.1.1",
            "localhost",
            "bücher.de",
        ]
        for attack in attacks { XCTAssertNil(PACFile.entry(attack), attack) }
        let script = PACFile.script(entries: attacks + ["ok.com"], port: 5000)
        XCTAssertTrue(script.contains("var sites = [\"ok.com\"];"), script)
        XCTAssertFalse(script.contains("alert"))
        XCTAssertFalse(script.contains("evil"))
        XCTAssertEqual(PACFile.entry("https://www.Example.com/path?q=1"), "www.example.com")
        XCTAssertEqual(PACFile.entry("xn--bcher-kva.de"), "xn--bcher-kva.de")
    }

    func testListIsCappedAndDeduplicated() {
        let many = (0..<50).map { "site\($0).com" } + ["site0.com"]
        let script = PACFile.script(entries: many, port: 5000)
        XCTAssertTrue(script.contains("site31.com"))
        XCTAssertFalse(script.contains("site32.com"))
        XCTAssertEqual(script.components(separatedBy: "\"site0.com\"").count, 2)
    }

    private func head(_ text: String) -> [UInt8] { Array(text.utf8) }

    func testRequestMatching() {
        XCTAssertTrue(PACFile.isRequest(head: head("GET /menfez.pac HTTP/1.1\r\nHost: 127.0.0.1:5000\r\n\r\n")))
        XCTAssertTrue(PACFile.isRequest(head: head("GET /menfez.pac HTTP/1.0\r\nhost: localhost\r\nAccept: */*\r\n\r\n")))
        // Another path, another method, a web page's Host (DNS rebinding), no
        // Host, two Hosts, or an absolute-form target: not ours.
        for bad in [
            "GET /other.pac HTTP/1.1\r\nHost: 127.0.0.1:5000\r\n\r\n",
            "POST /menfez.pac HTTP/1.1\r\nHost: 127.0.0.1:5000\r\n\r\n",
            "GET /menfez.pac HTTP/1.1\r\nHost: evil.example:5000\r\n\r\n",
            "GET /menfez.pac HTTP/1.1\r\nHost: 127.0.0.1.evil.example\r\n\r\n",
            "GET /menfez.pac HTTP/1.1\r\n\r\n",
            "GET /menfez.pac HTTP/1.1\r\nHost: 127.0.0.1\r\nHost: evil.example\r\n\r\n",
            "GET http://127.0.0.1:5000/menfez.pac HTTP/1.1\r\nHost: 127.0.0.1:5000\r\n\r\n",
            "GET /menfez.pac?x HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
        ] {
            XCTAssertFalse(PACFile.isRequest(head: head(bad)), bad)
        }
    }

    func testResponseHeaders() {
        let reply = PACFile.response(entries: ["a.com"], port: 5000)
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 200 OK\r\nContent-Type: application/x-ns-proxy-autoconfig\r\n"))
        let body = PACFile.script(entries: ["a.com"], port: 5000)
        XCTAssertTrue(reply.contains("Content-Length: \(body.utf8.count)\r\n"))
        XCTAssertTrue(reply.hasSuffix("\r\n\r\n" + body))
    }

    // MARK: - Served by the engine (DPIProxyTests' RawClient)

    private func fetch(_ engine: DPIEngine, _ request: String) throws -> String {
        let port = try XCTUnwrap(engine.status().port)
        let client = try RawClient(port: port)
        defer { client.close() }
        try client.send(request.replacingOccurrences(of: "{port}", with: String(port)))
        return String(decoding: try client.readUntil(Array("DIRECT\";\n}\n".utf8), timeout: 5), as: UTF8.self)
    }

    func testEngineServesThePACWhileTheBrowserListIsOn() throws {
        let engine = DPIEngine()
        _ = try engine.start()
        defer { engine.shutdown() }
        engine.setBrowserSites(["example.com"])
        let port = try XCTUnwrap(engine.status().port)

        let reply = try fetch(engine, "GET /menfez.pac HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n\r\n")
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 200 OK\r\nContent-Type: application/x-ns-proxy-autoconfig"), reply)
        XCTAssertTrue(reply.contains("PROXY 127.0.0.1:\(port); DIRECT"))
        XCTAssertTrue(reply.contains("\"example.com\""))
        XCTAssertEqual(engine.status().rejected, 0)
    }

    func testEngineRefusesOtherGETsAndForeignHosts() throws {
        let engine = DPIEngine()
        _ = try engine.start()
        defer { engine.shutdown() }
        engine.setBrowserSites(["example.com"])
        for request in ["GET /other HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n\r\n",
                        "GET /menfez.pac HTTP/1.1\r\nHost: rebind.example:{port}\r\n\r\n"] {
            let reply = try fetch(engine, request)
            XCTAssertTrue(reply.hasPrefix("HTTP/1.1 405"), reply)
            XCTAssertFalse(reply.contains("example.com\""))
        }
    }

    func testEngineRefusesThePACWhenTheBrowserListIsOff() throws {
        let engine = DPIEngine()
        _ = try engine.start()
        defer { engine.shutdown() }
        let reply = try fetch(engine, "GET /menfez.pac HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n\r\n")
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 405"), reply)
        engine.setBrowserSites(["a.com"])
        engine.setBrowserSites(nil)
        XCTAssertTrue(try fetch(engine, "GET /menfez.pac HTTP/1.1\r\nHost: localhost\r\n\r\n").hasPrefix("HTTP/1.1 405"))
    }
}
