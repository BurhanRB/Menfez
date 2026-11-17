import XCTest
@testable import MenfezCore

final class LogExportTests: XCTestCase {

    func testDomainsKeepFirstLetterAndTLD() {
        XCTAssertEqual(Redact.forSharing("host discord.com ok"), "host d*****.com ok")
        XCTAssertEqual(Redact.forSharing("gateway.discord.gg"), "g*****.gg")
    }

    func testPublicResolversStayVisible() {
        let text = "dns 1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 9.9.9.9 149.112.112.112 94.140.14.14 94.140.15.15"
        XCTAssertEqual(Redact.forSharing(text), text)
        XCTAssertEqual(Redact.forSharing("dns 8.8.8.9"), "dns 8.8.x.x")
    }

    func testFileNamesAreNotDomains() {
        let text = "wrote menfez.log, state.json, nl-ams-01.conf, Menfez.app, make-icon.sh, a.txt b.plist c.swift"
        XCTAssertEqual(Redact.forSharing(text), text)
        XCTAssertEqual(Redact.forSharing("menfez.com"), "m*****.com")
    }

    func testPublicIPv4HidesLastTwoOctets() {
        XCTAssertEqual(Redact.forSharing("egress 198.51.100.67/32"), "egress 198.51.x.x/32")
    }

    func testPublicIPv6KeepsFirstTwoGroups() {
        XCTAssertEqual(Redact.forSharing("v6 2a01:4f8:c0c:1234::1 end"), "v6 2a01:4f8:… end")
    }

    func testPrivateAddressesStayVisible() {
        let text = "10.0.0.2 172.20.1.1 192.168.1.1 127.0.0.1 169.254.3.4 100.64.0.1 ::1 fe80::1 fd00::5"
        XCTAssertEqual(Redact.forSharing(text), text)
    }

    func testKeyMaterialIsDropped() {
        let key = "yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk="
        let text = """
            [Interface]
            PrivateKey = \(key)
            1731 private_key: abc
            PresharedKey = \(key)
            peer \(key) handshake
            """
        let out = Redact.forSharing(text)
        XCTAssertFalse(out.contains(key))
        XCTAssertFalse(out.lowercased().contains("privatekey"))
        XCTAssertFalse(out.lowercased().contains("private_key"))
        XCTAssertFalse(out.lowercased().contains("presharedkey"))
        XCTAssertTrue(out.contains("peer [redacted: key] handshake"))
    }

    func testCapKeepsNewestLines() {
        let lines = (0..<50_000).map { "line \($0) " + String(repeating: "x", count: 40) }
        let out = LogExport.cap(header: "HEADER", lines: lines)
        XCTAssertLessThanOrEqual(out.utf8.count, LogExport.maxBytes)
        XCTAssertTrue(out.hasPrefix("HEADER\n[truncated: "))
        XCTAssertTrue(out.contains("line 49999 "))
        XCTAssertFalse(out.contains("line 0 "))
    }

    func testBuildReadsLogsMasksAndNamesFile() throws {
        let dir = NSTemporaryDirectory() + "logexport-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "2 second discord.com\n".write(toFile: dir + "/probe.log", atomically: true, encoding: .utf8)
        try "1 first 198.51.100.67\n".write(toFile: dir + "/trace.log", atomically: true, encoding: .utf8)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "logexport-\(UUID().uuidString)"))
        let out = LogExport.build(appVersion: "9.9", runMode: "dpi", dpi: DPIStatus(),
                                  report: Report(dns: ["1.1.1.1"]), defaults: defaults, logDir: dir)
        XCTAssertTrue(out.contains("[trace] 1 first 198.51.x.x\n[probe] 2 second d*****.com"))
        XCTAssertTrue(out.contains("servers: 1.1.1.1"))
        XCTAssertTrue(out.contains("app version: 9.9"))
        XCTAssertEqual(LogExport.fileName(at: Date(timeIntervalSince1970: 0)).count,
                       "menfez-debug-yyyyMMdd-HHmm.txt".count)
    }
}
