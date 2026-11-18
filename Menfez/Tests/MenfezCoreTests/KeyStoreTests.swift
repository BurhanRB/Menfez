import XCTest
@testable import MenfezCore

/// Keys in the Keychain (1.0.7): the move, the way back, the helper's stdin
/// check and the switch call. A `MemoryKeyStore` stands in for the Keychain;
/// one live test, opt-in, uses its own service name and deletes what it made.
final class KeyStoreTests: XCTestCase {

    let key = Data(repeating: 7, count: 32).base64EncodedString()
    let otherKey = Data(repeating: 9, count: 32).base64EncodedString()
    var dir: String!

    override func setUpWithError() throws {
        dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("menfez-keys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dir)
    }

    func config(_ key: String) -> String {
        """
        [Interface]
        PrivateKey = \(key)
        Address = 10.0.0.2/32
        DNS = 10.0.0.1

        [Peer]
        PublicKey = \(otherKey)
        Endpoint = 198.51.100.7:51820
        AllowedIPs = 0.0.0.0/0

        """
    }

    @discardableResult
    func write(_ text: String, name: String = "de-fra") -> String {
        let path = (dir as NSString).appendingPathComponent(name + ".conf")
        FileManager.default.createFile(atPath: path, contents: Data(text.utf8),
                                       attributes: [.posixPermissions: 0o600])
        return path
    }

    func read(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    // MARK: - Formats

    func testKeyFormat() {
        XCTAssertTrue(Validate.isWireGuardKey(key))
        XCTAssertFalse(Validate.isWireGuardKey(""))
        XCTAssertFalse(Validate.isWireGuardKey(String(key.dropLast())))
        XCTAssertFalse(Validate.isWireGuardKey(" " + key.dropFirst()))
        XCTAssertFalse(Validate.isWireGuardKey(Data(repeating: 7, count: 33).base64EncodedString()))
        XCTAssertFalse(Validate.isWireGuardKey(ProfileKeys.prefix + UUID().uuidString))
    }

    func testStdinTakesOneKeyLineOnly() {
        XCTAssertEqual(KeyInput.parse(Data(key.utf8)), key)
        XCTAssertEqual(KeyInput.parse(Data((key + "\n").utf8)), key)
        XCTAssertNil(KeyInput.parse(Data()), "empty")
        XCTAssertNil(KeyInput.parse(Data("\n".utf8)))
        XCTAssertNil(KeyInput.parse(Data((key + "\n\n").utf8)), "a second line")
        XCTAssertNil(KeyInput.parse(Data((key + "\n" + otherKey).utf8)), "two keys")
        XCTAssertNil(KeyInput.parse(Data((key + "\r\n").utf8)))
        XCTAssertNil(KeyInput.parse(Data(repeating: 65, count: KeyInput.limit + 1)), "too long")
        XCTAssertNil(KeyInput.parse(Data([0xff, 0xfe])), "not UTF-8")
    }

    func testPlaceholderParsing() {
        let id = UUID().uuidString
        XCTAssertNil(ProfileKeys.keychainID(in: config(key)))
        XCTAssertEqual(ProfileKeys.keychainID(in: config(ProfileKeys.prefix + id)), id)
        XCTAssertNil(ProfileKeys.keychainID(in: config(ProfileKeys.prefix + "../x")), "not a UUID")
        // Two key lines, or one in [Peer], is not a profile we rewrite.
        let twice = config(key).replacingOccurrences(of: "Address", with: "PrivateKey = \(key)\nAddress")
        XCTAssertNil(ProfileKeys.replacingKey(in: twice, with: "x"))
        let peerOnly = "[Interface]\nAddress = 10.0.0.2/32\n[Peer]\nPrivateKey = \(key)\n"
        XCTAssertNil(ProfileKeys.replacingKey(in: peerOnly, with: "x"))
    }

    // MARK: - Moving

    func testMoveRemovesKeyFromDiskAndRestoreBringsItBack() {
        let original = config(key)
        let file = write(original)
        let store = MemoryKeyStore()

        XCTAssertTrue(ProfileKeys.moveToStore(file: file, store: store))
        let moved = read(file)
        XCTAssertFalse(moved.contains(key), "the key is not on disk after the move")
        let id = ProfileKeys.keychainID(in: moved)
        XCTAssertNotNil(id)
        XCTAssertEqual(store.read(id!), key)
        XCTAssertTrue(moved.contains("Endpoint = 198.51.100.7:51820"), "everything else stays")
        let mode = (try? FileManager.default.attributesOfItem(atPath: file)[.posixPermissions]) as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertTrue(ProfileKeys.moveToStore(file: file, store: store), "moving twice is a no-op")
        XCTAssertEqual(store.count, 1)

        XCTAssertEqual(ProfileKeys.census(directory: dir).moved, [file])
        XCTAssertTrue(ProfileKeys.moveToFile(file: file, store: store))
        XCTAssertEqual(read(file), original)
        XCTAssertEqual(store.count, 0, "the item goes once the file has its key again")
    }

    func testFailedWriteLeavesFileAlone() {
        let original = config(key)
        let file = write(original)
        let store = MemoryKeyStore()
        store.failWrites = true
        XCTAssertFalse(ProfileKeys.moveToStore(file: file, store: store))
        XCTAssertEqual(read(file), original)
        XCTAssertEqual(store.count, 0)
    }

    func testRestoreWithoutItemLeavesPlaceholder() {
        let file = write(config(ProfileKeys.prefix + UUID().uuidString))
        let before = read(file)
        XCTAssertFalse(ProfileKeys.moveToFile(file: file, store: MemoryKeyStore()))
        XCTAssertEqual(read(file), before)
    }

    func testBrokenKeyIsNotMoved() {
        let file = write(config("not-a-key"))
        XCTAssertFalse(ProfileKeys.moveToStore(file: file, store: MemoryKeyStore()))
        XCTAssertEqual(ProfileKeys.census(directory: dir).plain, [])
    }

    func testLookupAndListing() {
        let store = MemoryKeyStore()
        let plain = write(config(otherKey), name: "bg-sof")
        let file = write(config(key))
        XCTAssertEqual(ProfileKeys.lookup(file: file, store: store), .inFile)
        ProfileKeys.moveToStore(file: file, store: store)
        XCTAssertEqual(ProfileKeys.lookup(file: file, store: store), .key(key))
        XCTAssertEqual(ProfileKeys.lookup(file: plain, store: store), .inFile)
        XCTAssertEqual(ProfileKeys.lookup(file: file, store: MemoryKeyStore()), .unreadable)

        let listed = WireGuardProfiles.list(directory: dir, liveHost: nil)
        XCTAssertEqual(listed.first(where: { $0.name == "de-fra" })?.keychain, true)
        XCTAssertNil(listed.first(where: { $0.name == "bg-sof" })?.keychain)
        // A rename moves the file; the id inside it, and so the key, follows.
        guard case .success = WireGuardProfiles.rename("de-fra", to: "Frankfurt", directory: dir)
        else { return XCTFail("rename") }
        let renamed = (dir as NSString).appendingPathComponent("Frankfurt.conf")
        XCTAssertEqual(ProfileKeys.lookup(file: renamed, store: store), .key(key))
    }

    // MARK: - The managed config (helper side)

    func testManagedConfigTakesKeyFromStdinOnly() {
        let source = write(config(ProfileKeys.prefix + UUID().uuidString))
        let managed = (dir as NSString).appendingPathComponent("managed/wgmanaged.conf")
        XCTAssertFalse(WireGuardProfiles.writeManagedConfig(from: source, to: managed),
                       "no key, no config: wg-quick would only echo the placeholder")
        XCTAssertFalse(WireGuardProfiles.writeManagedConfig(from: source, to: managed, key: "bad"))
        XCTAssertTrue(WireGuardProfiles.writeManagedConfig(from: source, to: managed, key: key))
        let text = read(managed)
        XCTAssertTrue(text.contains("PrivateKey = \(key)"))
        XCTAssertFalse(text.contains(ProfileKeys.prefix))
        XCTAssertTrue(text.contains("Table = off"))
        XCTAssertFalse(text.contains("DNS"))
        // A file that holds its own key keeps it; a stray stdin key is ignored.
        let plain = write(config(otherKey), name: "plain")
        XCTAssertTrue(WireGuardProfiles.writeManagedConfig(from: plain, to: managed, key: key))
        XCTAssertTrue(read(managed).contains("PrivateKey = \(otherKey)"))
    }

    // MARK: - The switch call (app side)

    func testSwitchSendsKeyOnStdinNeverInArguments() {
        var seenArgs: [String] = []
        var seenInput: Data?
        let client = HelperClient(helper: "/h", launcher: { _, args, _ in
            seenArgs = args
            return CommandResult(status: 0, output: #"{"ok":true}"#)
        }, inputLauncher: { _, args, _, input in
            seenArgs = args
            seenInput = input
            return CommandResult(status: 0, output: #"{"ok":true,"mode":"discord"}"#)
        }, profileKey: { $0 == "de-fra" ? .key(self.key) : .inFile })

        XCTAssertTrue(client.act(["switch", "de-fra", "--dns-routes", "1.1.1.1"]).ok)
        XCTAssertEqual(seenArgs, ["-n", "/h", "switch", "de-fra", "--dns-routes", "1.1.1.1", "--key-stdin"])
        XCTAssertFalse(seenArgs.joined().contains(key))
        XCTAssertEqual(seenInput, Data((key + "\n").utf8))
        XCTAssertEqual(KeyInput.parse(seenInput!), key)

        seenInput = nil
        XCTAssertTrue(client.act(["switch", "bg-sof"]).ok)
        XCTAssertEqual(seenArgs, ["-n", "/h", "switch", "bg-sof"])
        XCTAssertNil(seenInput)
    }

    func testUnreadableKeyStartsNothing() {
        var spawned = false
        let client = HelperClient(helper: "/h", launcher: { _, _, _ in
            spawned = true
            return CommandResult(status: 0, output: "")
        }, profileKey: { _ in .unreadable })
        let result = client.act(["switch", "de-fra"])
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.error, ProfileKeys.readFailure)
        XCTAssertFalse(spawned, "the old tunnel is left alone")
        XCTAssertTrue(client.spawns.isEmpty)
    }

    func testHelperVersionKnowsKeyStdin() {
        XCTAssertGreaterThanOrEqual(HelperVersion.current, 5)
        XCTAssertTrue(HelperVersion.needsUpdate(installed: 4))
    }

    // MARK: - Live, opt-in

    /// The real login keychain, under a throwaway service name. Run with
    /// MENFEZ_LIVE_KEYCHAIN=1; everything it writes is deleted at the end.
    func testLiveKeychainRoundTrip() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MENFEZ_LIVE_KEYCHAIN"] == "1")
        let store = KeychainStore(service: "com.menfez.test.\(UUID().uuidString)")
        let id = UUID().uuidString
        defer { store.delete(id) }
        XCTAssertNil(store.read(id))
        XCTAssertTrue(store.write(key, for: id))
        XCTAssertEqual(store.read(id), key)
        XCTAssertTrue(store.write(otherKey, for: id), "a second write replaces")
        XCTAssertEqual(store.read(id), otherKey)

        let file = write(config(key))
        XCTAssertTrue(ProfileKeys.moveToStore(file: file, store: store))
        XCTAssertFalse(read(file).contains(key))
        XCTAssertTrue(ProfileKeys.moveToFile(file: file, store: store))
        XCTAssertTrue(read(file).contains(key))

        XCTAssertTrue(store.delete(id))
        XCTAssertNil(store.read(id))
        print("live keychain service: \(store.service)")
    }
}
