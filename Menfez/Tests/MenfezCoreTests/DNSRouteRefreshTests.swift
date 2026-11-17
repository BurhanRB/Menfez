import XCTest
@testable import MenfezCore

final class DNSRouteRefreshTests: XCTestCase {

    func testFirstCheckIsBaselineAndSameSetIsQuiet() {
        var r = DNSRouteRefresh()
        XCTAssertNil(r.observe(["195.175.39.39"]))
        XCTAssertEqual(r.applied, ["195.175.39.39"])
        XCTAssertNil(r.observe(["195.175.39.39"]))
        XCTAssertNil(r.observe(["195.175.39.39"]), "order or repeats never trigger")
    }

    func testChangeMustBeSeenTwice() {
        var r = DNSRouteRefresh()
        _ = r.observe(["195.175.39.39"])
        XCTAssertNil(r.observe(["8.8.8.8"]), "first sight is held")
        XCTAssertEqual(r.observe(["8.8.8.8"]), ["8.8.8.8"])
        XCTAssertEqual(r.applied, ["8.8.8.8"])
        XCTAssertNil(r.observe(["8.8.8.8"]))
    }

    func testFlappingSetDoesNotTrigger() {
        var r = DNSRouteRefresh()
        _ = r.observe(["1.1.1.1"])
        XCTAssertNil(r.observe(["8.8.8.8"]))
        XCTAssertNil(r.observe(["9.9.9.9"]), "a different set restarts the wait")
        XCTAssertNil(r.observe(["1.1.1.1"]), "back to the applied set clears it")
        XCTAssertNil(r.observe(["9.9.9.9"]))
        XCTAssertEqual(r.observe(["9.9.9.9"]), ["9.9.9.9"])
    }

    func testSameSetInOtherOrderIsNoChange() {
        var r = DNSRouteRefresh()
        _ = r.observe(["1.1.1.1", "8.8.8.8"])
        XCTAssertNil(r.observe(["8.8.8.8", "1.1.1.1"]))
        XCTAssertNil(r.observe(["8.8.8.8", "1.1.1.1"]))
    }

    func testEmptySetNeverReplacesRoutes() {
        var r = DNSRouteRefresh()
        _ = r.observe(["1.1.1.1"])
        XCTAssertNil(r.observe([]))
        XCTAssertNil(r.observe([]))
        XCTAssertEqual(r.applied, ["1.1.1.1"])
    }

    func testResetStartsANewBaseline() {
        var r = DNSRouteRefresh()
        _ = r.observe(["1.1.1.1"])
        _ = r.observe(["8.8.8.8"])
        r.reset()
        XCTAssertNil(r.applied)
        XCTAssertNil(r.observe(["8.8.8.8"]))
        XCTAssertEqual(r.applied, ["8.8.8.8"])
    }

    func testWarningOnlyWhenEveryResolverIsPrivate() {
        XCTAssertTrue(DNSRouteRefresh.resolversStayOutside(enabled: true, resolvers: ["192.168.1.1"]))
        XCTAssertTrue(DNSRouteRefresh.resolversStayOutside(enabled: true,
                                                           resolvers: ["10.0.0.1", "fe80::1", "127.0.0.1"]))
        XCTAssertFalse(DNSRouteRefresh.resolversStayOutside(enabled: true,
                                                            resolvers: ["192.168.1.1", "1.1.1.1"]))
        XCTAssertFalse(DNSRouteRefresh.resolversStayOutside(enabled: false, resolvers: ["192.168.1.1"]))
        XCTAssertFalse(DNSRouteRefresh.resolversStayOutside(enabled: true, resolvers: []),
                       "nothing read is not a reason to warn")
    }
}
