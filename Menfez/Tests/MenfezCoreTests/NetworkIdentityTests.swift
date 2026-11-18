import XCTest
@testable import MenfezCore

/// Network fingerprint (1.0.8, feature 5): router MAC from arp/ndp, hashed
/// with the interface kind and DHCP domain. No permission, no guessing.
final class NetworkIdentityTests: XCTestCase {

    final class Canned: CommandRunner, @unchecked Sendable {
        let output: String
        var calls: [[String]] = []
        init(_ output: String) { self.output = output }
        func run(_ tool: String, _ args: [String], timeout: TimeInterval) -> CommandResult {
            calls.append([tool] + args)
            return CommandResult(status: 0, output: output)
        }
    }

    let mac = "0:1a:2b:3c:4d:5e"

    func testMACIsNormalisedAndRandomOnesRefused() {
        XCTAssertEqual(NetworkIdentity.normalizeMAC("0:1A:2b:3:4d:5e"), "00:1a:2b:03:4d:5e")
        XCTAssertNil(NetworkIdentity.normalizeMAC("da:1a:2b:3c:4d:5e"), "locally administered")
        XCTAssertNil(NetworkIdentity.normalizeMAC("1:0:5e:0:0:1"), "multicast")
        XCTAssertNil(NetworkIdentity.normalizeMAC("0:0:0:0:0:0"))
        XCTAssertNil(NetworkIdentity.normalizeMAC("(incomplete)"))
        XCTAssertNil(NetworkIdentity.normalizeMAC("0:1a:2b:3c:4d"))
        XCTAssertNil(NetworkIdentity.normalizeMAC("0:1a:2b:3c:4d:5e:6f"))
        XCTAssertNil(NetworkIdentity.normalizeMAC("0:1a:2b:3c:4d:zz"))
    }

    func testARPOutput() {
        XCTAssertEqual(NetworkIdentity.macFromARP("? (192.168.1.1) at \(mac) on en0 ifscope [ethernet]\n"),
                       "00:1a:2b:3c:4d:5e")
        XCTAssertNil(NetworkIdentity.macFromARP("? (192.168.1.1) at (incomplete) on en0 ifscope [ethernet]"))
        XCTAssertNil(NetworkIdentity.macFromARP("192.168.1.1 (192.168.1.1) -- no entry"))
        XCTAssertNil(NetworkIdentity.macFromARP(""))
        XCTAssertNil(NetworkIdentity.macFromARP("? (172.20.10.1) at 9a:1a:2b:3c:4d:5e on en0 [ethernet]"),
                     "phone hotspot with a random MAC: unknown, not guessed")
    }

    func testNDPOutputPicksTheRouterOnItsInterface() {
        let out = """
        Neighbor                                Linklayer Address  Netif Expire    St Flgs Prbs
        2001:db8::2:2                           (incomplete)       utun5 permanent R
        fe80::1%lo0                             (incomplete)         lo0 permanent R
        fe80::abcd%en1                          0:aa:bb:cc:dd:ee     en1 28s       R
        fe80::abcd%en0                          \(mac)     en0 28s       R
        """
        XCTAssertEqual(NetworkIdentity.macFromNDP(out, router: "fe80::abcd", interface: "en0"), "00:1a:2b:3c:4d:5e")
        XCTAssertEqual(NetworkIdentity.macFromNDP(out, router: "FE80::ABCD%en1", interface: nil), "00:aa:bb:cc:dd:ee")
        XCTAssertNil(NetworkIdentity.macFromNDP(out, router: "fe80::1", interface: "lo0"), "incomplete")
        XCTAssertNil(NetworkIdentity.macFromNDP(out, router: "fe80::9", interface: "en0"), "no row")
    }

    func testFingerprintIsStableAndSeparatesKindAndDomain() {
        let a = NetworkIdentity.fingerprint(kind: .wifi, mac: "00:1a:2b:3c:4d:5e", domain: "Station")
        XCTAssertEqual(a, NetworkIdentity.fingerprint(kind: .wifi, mac: "00:1a:2b:3c:4d:5e", domain: "station"))
        XCTAssertEqual(a.count, 64)
        XCTAssertFalse(a.contains("001a2b3c4d5e"), "the id is a hash, not the MAC")
        XCTAssertNotEqual(a, NetworkIdentity.fingerprint(kind: .wired, mac: "00:1a:2b:3c:4d:5e", domain: "station"))
        XCTAssertNotEqual(a, NetworkIdentity.fingerprint(kind: .wifi, mac: "00:1a:2b:3c:4d:5e", domain: nil))
        XCTAssertNotEqual(a, NetworkIdentity.fingerprint(kind: .wifi, mac: "00:1a:2b:3c:4d:5f", domain: "station"))
    }

    func testIdUsesArpForIPv4AndNdpOnlyWithoutIPv4() {
        let v4 = Canned("? (192.168.1.1) at \(mac) on en0 ifscope [ethernet]")
        let primary = NetworkIdentity.Primary(interface: "en0", kind: .wifi, routerV4: "192.168.1.1",
                                              routerV6: "fe80::1", domain: "home")
        XCTAssertEqual(NetworkIdentity.id(of: primary, runner: v4),
                       NetworkIdentity.fingerprint(kind: .wifi, mac: "00:1a:2b:3c:4d:5e", domain: "home"))
        XCTAssertEqual(v4.calls, [["/usr/sbin/arp", "-n", "192.168.1.1"]], "one spawn, no sudo")

        let v6 = Canned("fe80::1%en0  \(mac)  en0 10s R")
        let only6 = NetworkIdentity.Primary(interface: "en0", kind: .wired, routerV4: nil,
                                            routerV6: "fe80::1", domain: nil)
        XCTAssertNotNil(NetworkIdentity.id(of: only6, runner: v6))
        XCTAssertEqual(v6.calls, [["/usr/sbin/ndp", "-an"]])
    }

    func testNoRouterOrNoEntryMeansNoIdAndNoSpawnWithoutRouter() {
        let none = Canned("x (10.0.0.1) -- no entry")
        XCTAssertNil(NetworkIdentity.id(of: nil, runner: none))
        let bare = NetworkIdentity.Primary(interface: "en0", kind: .wifi, routerV4: nil, routerV6: nil, domain: nil)
        XCTAssertNil(NetworkIdentity.id(of: bare, runner: none))
        XCTAssertTrue(none.calls.isEmpty)
        let gw = NetworkIdentity.Primary(interface: "en0", kind: .wifi, routerV4: "10.0.0.1", routerV6: nil, domain: nil)
        XCTAssertNil(NetworkIdentity.id(of: gw, runner: none))
        let odd = NetworkIdentity.Primary(interface: "en0", kind: .wifi, routerV4: "-n; x", routerV6: nil, domain: nil)
        XCTAssertNil(NetworkIdentity.id(of: odd, runner: none))
        XCTAssertEqual(none.calls.count, 1, "a non-address router is never passed to arp")
    }

    func testSharedLogsHideMACsAndIds() {
        let id = NetworkIdentity.fingerprint(kind: .wifi, mac: "00:1a:2b:3c:4d:5e", domain: nil)
        let out = Redact.forSharing("router 0:1a:2b:3c:4d:5e on en0, AA:BB:CC:DD:EE:0F; net \(id)")
        XCTAssertFalse(out.contains("1a:2b"))
        XCTAssertFalse(out.lowercased().contains("aa:bb:cc"))
        XCTAssertFalse(out.contains(id))
        XCTAssertTrue(out.contains("en0"))
    }
}
