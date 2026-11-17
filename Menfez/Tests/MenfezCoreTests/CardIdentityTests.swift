import XCTest
@testable import MenfezCore

/// Which address feeds the card's IP / location / ISP rows in each mode.
final class CardIdentityTests: XCTestCase {

    let local = Geo(country: "TR", city: "İstanbul", org: "AS9121 Turk Telekom", ispShort: "Türk Telekom")
    let server = Geo(country: "BG", city: "Sofia", org: "AS1 Example Hosting", ispShort: "Example")

    func testTunnelModeShowsTheServer() {
        let id = CardIdentity.choose(runMode: .tunnel, egressIP: "88.1.1.1", egressGeo: local,
                                     serverIP: "185.1.1.1", serverGeo: server)
        XCTAssertEqual(id, CardIdentity(ip: "185.1.1.1", geo: server, fromServer: true))
    }

    /// Geo still loading: the server's address shows, never the local ISP.
    func testTunnelModeWithPendingGeoDoesNotFallBackToLocalISP() {
        let id = CardIdentity.choose(runMode: .tunnel, egressIP: "88.1.1.1", egressGeo: local,
                                     serverIP: "185.1.1.1", serverGeo: nil)
        XCTAssertEqual(id.ip, "185.1.1.1")
        XCTAssertNil(id.geo)
    }

    func testTunnelModeWithoutAServerAddressUsesEgress() {
        let id = CardIdentity.choose(runMode: .tunnel, egressIP: "88.1.1.1", egressGeo: local,
                                     serverIP: nil, serverGeo: nil)
        XCTAssertEqual(id, CardIdentity(ip: "88.1.1.1", geo: local, fromServer: false))
    }

    func testDirectAndDPIShowEgressEvenWhenAServerIsKnown() {
        for mode in [RunMode.direct, .dpi] {
            let id = CardIdentity.choose(runMode: mode, egressIP: "88.1.1.1", egressGeo: local,
                                         serverIP: "185.1.1.1", serverGeo: server)
            XCTAssertEqual(id, CardIdentity(ip: "88.1.1.1", geo: local, fromServer: false), "\(mode)")
        }
    }

    func testServerHostPrefersTheLiveAddress() {
        XCTAssertEqual(CardIdentity.serverHost(liveEndpointHost: "185.1.1.1", profileHost: "vpn.example.com"),
                       "185.1.1.1")
        XCTAssertEqual(CardIdentity.serverHost(liveEndpointHost: nil, profileHost: "vpn.example.com"),
                       "vpn.example.com")
        XCTAssertNil(CardIdentity.serverHost(liveEndpointHost: nil, profileHost: nil))
    }
}
