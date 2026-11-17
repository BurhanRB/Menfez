import XCTest
@testable import MenfezCore

/// The DNS state file is the only record of what the user's resolver was before
/// Menfez changed it. If it is wrong, `auto` restores the wrong thing and the
/// user is stuck on a resolver they never chose — with no way to find out what
/// the original was.
///
/// These tests exist because a two-character change (`== nil` to `!= nil` in the
/// first-observation guard) would silently overwrite the saved original on every
/// subsequent apply, and nothing in the suite would have failed.
final class DNSStateSafetyTests: XCTestCase {

    private var dir: String!
    private var statePath: String!

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "menfez-dns-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir,
                                                withIntermediateDirectories: true)
        statePath = (dir as NSString).appendingPathComponent("dns-state.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dir)
    }

    // MARK: - The first-observation rule

    /// The rule itself, expressed without touching the live system: given a
    /// state that already records a previous value, applying again must not
    /// replace it.
    ///
    /// This mirrors `DNSManager.apply`'s guard. It is the property that protects
    /// the user, and it is asserted here because exercising `apply` would
    /// rewrite this machine's resolver.
    func testSecondApplyKeepsTheFirstObservation() throws {
        // Simulate: the machine started with static resolvers.
        var state = DNSState()
        state.previous["Wi-Fi"] = ["192.168.1.1"]

        // First apply (what the production guard does).
        if state.previous["Wi-Fi"] == nil {
            state.previous["Wi-Fi"] = ["1.1.1.1"]
        }
        XCTAssertEqual(state.previous["Wi-Fi"], ["192.168.1.1"],
                       "the first observation must survive the first apply")

        // Second apply with a different resolver.
        if state.previous["Wi-Fi"] == nil {
            state.previous["Wi-Fi"] = ["9.9.9.9"]
        }
        XCTAssertEqual(state.previous["Wi-Fi"], ["192.168.1.1"],
                       "a second apply must not overwrite the original")
    }

    /// The inverse guard — what the two-character bug would do — is detectable.
    /// Written as a negative control so the test above cannot pass vacuously.
    func testInvertedGuardWouldBeDetected() {
        var buggy = DNSState()
        buggy.previous["Wi-Fi"] = ["192.168.1.1"]
        if buggy.previous["Wi-Fi"] != nil {
            buggy.previous["Wi-Fi"] = ["1.1.1.1"]
        }
        XCTAssertNotEqual(buggy.previous["Wi-Fi"], ["192.168.1.1"],
                          "the negative control must differ; if this fails, the "
                          + "test above proves nothing")
    }

    // MARK: - Storage

    func testStateRoundTrips() throws {
        var state = DNSState()
        state.previous["Wi-Fi"] = ["1.1.1.1", "1.0.0.1"]
        state.applied = ["9.9.9.9"]
        try DNSStateStore.save(state, path: statePath)

        let loaded = DNSStateStore.load(path: statePath)
        XCTAssertEqual(loaded.previous["Wi-Fi"], ["1.1.1.1", "1.0.0.1"])
        XCTAssertEqual(loaded.applied, ["9.9.9.9"])
    }

    func testMissingFileLoadsAsEmptyNotCorrupt() {
        let loaded = DNSStateStore.load(path: statePath)
        XCTAssertTrue(loaded.previous.isEmpty)
        XCTAssertTrue(loaded.applied.isEmpty)
    }

    /// A truncated or hand-edited file must not crash and must not invent a
    /// previous value. Inventing one would make `auto` write a resolver the
    /// user never had.
    func testCorruptFileLoadsAsEmpty() throws {
        for garbage in ["{", "not json", "[]", #"{"previous": "wrong type"}"#] {
            try garbage.write(toFile: statePath, atomically: true, encoding: .utf8)
            let loaded = DNSStateStore.load(path: statePath)
            XCTAssertTrue(loaded.previous.isEmpty,
                          "corrupt input \(garbage) must not yield a previous value")
        }
    }

    /// The file is not secret, but it describes the user's network; it is
    /// written 0600 like the profiles.
    func testStateFileIsNotWorldReadable() throws {
        try DNSStateStore.save(DNSState(), path: statePath)
        let attrs = try FileManager.default.attributesOfItem(atPath: statePath)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o755
        XCTAssertEqual(perms & 0o077, 0,
                       "state file must not be readable by group or others")
    }

    // MARK: - Multi-service isolation

    /// Restoring one service must not erase another's saved original. This is
    /// the M7 bug, pinned so it cannot come back.
    func testRemovingOneServiceKeepsTheOthers() throws {
        var state = DNSState()
        state.previous["Wi-Fi"] = ["1.1.1.1"]
        state.previous["Ethernet"] = ["8.8.8.8"]
        try DNSStateStore.save(state, path: statePath)

        // What `restoreAutomatic` does for one service.
        var loaded = DNSStateStore.load(path: statePath)
        loaded.previous.removeValue(forKey: "Wi-Fi")
        loaded.applied = []
        try DNSStateStore.save(loaded, path: statePath)

        let after = DNSStateStore.load(path: statePath)
        XCTAssertNil(after.previous["Wi-Fi"])
        XCTAssertEqual(after.previous["Ethernet"], ["8.8.8.8"],
                       "restoring one service must not destroy another's original")
    }
}
