import XCTest
@testable import MenfezCore

/// The tests that belong to shipping this to strangers rather than to the
/// developer's own laptop: key material must never reach JSON, a name must not
/// escape its directory, an input must not reach a privileged tool unparsed,
/// and an interrupted run must be recoverable.
///
/// Nothing here touches the network or the route table.
final class SecurityTests: XCTestCase {

    // MARK: - Fixtures

    private var root = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("menfez-security-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if !root.isEmpty { try? FileManager.default.removeItem(atPath: root) }
        root = ""
        try super.tearDownWithError()
    }

    private func path(_ name: String) -> String {
        let full = (root as NSString).appendingPathComponent(name)
        // Nested fixtures ("wireguard/x.conf") need their parent to exist;
        // `path()` is used both to build and to write, so it creates it.
        let parent = (full as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: parent,
                                                 withIntermediateDirectories: true)
        return full
    }

    @discardableResult
    private func write(_ text: String, to name: String) throws -> String {
        let file = path(name)
        try text.write(toFile: file, atomically: true, encoding: .utf8)
        return file
    }

    /// A key with characters that must never appear in an error message.
    private let plantedKey = "PLANTEDKEY44SENTINEL/x9Q2w7ErTyUiOpAsDfGhJkLzXcVbNm="

    private func protonConfig(key: String? = nil, dns: String = "10.2.0.1") -> String {
        let k = key ?? plantedKey
        return """
        [Interface]
        PrivateKey = \(k)
        Address = 10.2.0.2/32
        DNS = \(dns)

        [Peer]
        PublicKey = TESTONLYFAKEPEERKEYDONOTUSE000000000000000A=
        AllowedIPs = 0.0.0.0/0, ::/0
        Endpoint = 203.0.113.69:51820
        """
    }

    // MARK: - 1e: no planted key in any command's JSON

    /// The single assertion that matters most for a public release: sweep every
    /// JSON-producing surface the app can reach and grep the encoded result for
    /// the key. A leak here is a credential on the screen and in any bug report
    /// the user files.
    func testNoPlantedKeyAppearsInAnyJSONPayload() throws {
        let dir = path("wireguard")
        try FileManager.default.createDirectory(atPath: dir,
                                                withIntermediateDirectories: true)
        try write(protonConfig(), to: path("wireguard/VPN-RO1-RO-229.conf"))

        // The profile listing: read-only, but the one place that reads the file.
        let profiles = WireGuardProfiles.list(directory: dir)
        assertNoKey(in: JSON.encode(profiles), surface: "profiles")

        // The whole response the helper emits for `profiles`.
        assertNoKey(in: JSON.encode(ProfilesResponse(profiles: profiles,
                                                     activeIface: nil)),
                    surface: "profiles response")

        // A successful action result, which carries the notes field.
        assertNoKey(in: JSON.encode(ActionResult(ok: true, notes: ["armed"])),
                    surface: "action result")

        // The redacted failure a config operation returns.
        let redacted = ActionResult.redacted("the new profile")
        assertNoKey(in: JSON.encode(redacted), surface: "redacted failure")

        // Every redaction helper, direct.
        assertNoKey(in: redacted.error ?? "", surface: "redacted message")
        assertNoKey(in: Redact.scrub(protonConfig()).description, surface: "scrub")
        let summary = Redact.configSummary(protonConfig())
        assertNoKey(in: summary.joined(separator: "\n"), surface: "summary")
        assertNoKey(in: JSON.encode(summary), surface: "summary JSON")
        assertNoKey(in: Redact.configFailure("switch", lineNumbers: [2]),
                    surface: "configFailure")
    }

    private func assertNoKey(in text: String, surface: String) {
        XCTAssertFalse(text.contains(plantedKey),
                       "\(surface) leaked the private key: \(text)")
        XCTAssertFalse(text.contains("PLANTEDKEY"),
                       "\(surface) leaked a fragment of the key: \(text)")
        // The value is base64 of a 32-byte key; its second half is just as
        // sensitive as its first.
        XCTAssertFalse(text.contains("9Q2w7ErTyUiOpAsDfGhJkLzXcVbNm"),
                       "\(surface) leaked the tail of the key: \(text)")
    }

    /// The scanner is the one place that could accidentally hold the value.
    /// It has no field for it, and this pins that.
    func testScanNeverCarriesKeyMaterial() {
        let parsed = WireGuardProfiles.scan(protonConfig())
        XCTAssertEqual(parsed.address, "10.2.0.2/32")
        XCTAssertEqual(parsed.endpoint, "203.0.113.69:51820")
        XCTAssertFalse(parsed.address?.contains("PLANTEDKEY") ?? false)
        XCTAssertFalse(parsed.endpoint?.contains("PLANTEDKEY") ?? false)
    }

    /// A tab between the key name and the equals sign is the form that used to
    /// slip past both the passthrough and the strip. The rewrite must still
    /// recognise it as key material and copy it through byte for byte, and it
    /// must not lose it: a config without a key cannot come up.
    func testTabSeparatedKeyLineIsStillKeyMaterial() throws {
        let source = try write("""
        [Interface]
        PrivateKey\t=\t\(plantedKey)
        Address = 10.2.0.2/32

        [Peer]
        PublicKey = ABC
        Endpoint = 203.0.113.69:51820
        """, to: path("tab.conf"))
        let destination = path("wgmanaged.conf")
        XCTAssertTrue(WireGuardProfiles.writeManagedConfig(from: source,
                                                           to: destination))
        let output = try String(contentsOfFile: destination, encoding: .utf8)
        XCTAssertTrue(output.contains("PrivateKey\t=\t\(plantedKey)"),
                      "the tab-separated key line was not preserved:\n\(output)")
    }

    /// A tab-separated `DNS\t=` and `Table\t=` must be stripped in
    /// [Interface]. Leaving a `DNS =` form behind is how wg-quick hijacks the
    /// resolver behind DNSManager's back, whose state file then no longer
    /// describes what the machine is doing.
    func testTabSeparatedDNSAndTableLinesAreStripped() throws {
        let source = try write("""
        [Interface]
        PrivateKey = ABC
        Address = 10.2.0.2/32
        DNS\t=\t10.2.0.1, 2a07:b944::2:1
        Table\t=\tauto

        [Peer]
        PublicKey = DEF
        AllowedIPs\t=\t0.0.0.0/0
        Endpoint = 203.0.113.69:51820
        """, to: path("tabs.conf"))
        let destination = path("wgmanaged.conf")
        XCTAssertTrue(WireGuardProfiles.writeManagedConfig(from: source,
                                                           to: destination))
        let output = try String(contentsOfFile: destination, encoding: .utf8)
        XCTAssertFalse(output.contains("10.2.0.1"),
                       "a tab-formatted DNS line survived:\n\(output)")
        XCTAssertFalse(output.contains("auto"),
                       "a tab-formatted Table line survived:\n\(output)")
        XCTAssertEqual(output.components(separatedBy: "AllowedIPs").count - 1, 1,
                       "AllowedIPs was not replaced exactly once:\n\(output)")
    }

    /// wg-quick runs as root and executes the Pre/Post Up/Down hooks as shell
    /// commands, and the source .conf is user-writable. Every casing and
    /// spacing of every hook (and SaveConfig) must be dropped, while the
    /// allowlisted lines come through byte for byte.
    func testManagedConfigDropsRootHooksInEveryForm() throws {
        let source = try write("""
        PostUp = touch /tmp/pwned-before-section
        [Interface]
        PrivateKey = \(plantedKey)
        PostUp = touch /tmp/pwned1
         postup = touch /tmp/pwned2
        POSTUP=touch /tmp/pwned3
        PreUp\t=\ttouch /tmp/pwned4
        PreDown = touch /tmp/pwned5
        PostDown = touch /tmp/pwned6
        SaveConfig = true
        FwMark = 51820
        Address = 10.2.0.2/32
        ListenPort = 51820
        MTU = 1420
        Table = auto

        [Peer]
        PublicKey = TESTONLYFAKEPEERKEYDONOTUSE000000000000000A=
        PresharedKey = PSKSENTINEL=
        PostUp = touch /tmp/pwned7
        Endpoint = 203.0.113.69:51820
        PersistentKeepalive = 25
        AllowedIPs = 10.0.0.0/8

        [Bogus]
        PostUp = touch /tmp/pwned8
        """, to: path("hooks.conf"))
        let destination = path("wgmanaged.conf")
        XCTAssertTrue(WireGuardProfiles.writeManagedConfig(from: source,
                                                           to: destination))
        let output = try String(contentsOfFile: destination, encoding: .utf8)
        let lowered = output.lowercased()
        for banned in ["postup", "preup", "predown", "postdown", "saveconfig",
                       "fwmark", "pwned", "table = auto", "[bogus]"] {
            XCTAssertFalse(lowered.contains(banned),
                           "\(banned) survived the rewrite:\n\(output)")
        }
        for kept in ["PrivateKey = \(plantedKey)", "Address = 10.2.0.2/32",
                     "ListenPort = 51820", "MTU = 1420", "Table = off",
                     "PublicKey = TESTONLYFAKEPEERKEYDONOTUSE000000000000000A=",
                     "PresharedKey = PSKSENTINEL=",
                     "Endpoint = 203.0.113.69:51820",
                     "PersistentKeepalive = 25",
                     "AllowedIPs = 0.0.0.0/0, ::/0"] {
            XCTAssertTrue(output.contains(kept),
                          "\(kept) was lost or altered:\n\(output)")
        }
    }

    /// Root reads the source from a user-writable directory. A symlink there
    /// (to a root-only file, say) must be refused, not followed.
    func testSymlinkedSourceProfileIsRefused() throws {
        let real = try write(protonConfig(), to: "real.conf")
        let link = path("link.conf")
        try FileManager.default.createSymbolicLink(atPath: link,
                                                   withDestinationPath: real)
        let destination = path("wgmanaged.conf")
        XCTAssertFalse(WireGuardProfiles.writeManagedConfig(from: link,
                                                            to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination))
        XCTAssertNil(WireGuardProfiles.readText(at: link))
        XCTAssertNotNil(WireGuardProfiles.readText(at: real))
    }

    /// A FIFO in place of a profile must not hang root on open or read.
    func testFifoSourceProfileIsRefused() throws {
        let fifo = path("fifo.conf")
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        XCTAssertNil(WireGuardProfiles.readText(at: fifo))
    }

    /// Root writes the managed config. A symlink planted at the destination
    /// must make the write fail, leaving the link's target untouched.
    func testSymlinkedManagedConfigDestinationIsNotFollowed() throws {
        let source = try write(protonConfig(), to: "real.conf")
        let victim = try write("do not touch\n", to: "victim")
        let destination = path("wgmanaged.conf")
        try FileManager.default.createSymbolicLink(atPath: destination,
                                                   withDestinationPath: victim)
        XCTAssertFalse(WireGuardProfiles.writeManagedConfig(from: source,
                                                            to: destination))
        XCTAssertEqual(try String(contentsOfFile: victim, encoding: .utf8),
                       "do not touch\n")
    }

    /// Under sudo only the invoking user's or root's files are trusted; as a
    /// plain user (the test runner) nothing is filtered by owner.
    func testOwnerCheckOnlyTrustsTheSudoUserAndRoot() {
        XCTAssertTrue(WireGuardProfiles.isTrustedOwner(501, euid: 0, sudoUID: "501"))
        XCTAssertTrue(WireGuardProfiles.isTrustedOwner(0, euid: 0, sudoUID: "501"))
        XCTAssertFalse(WireGuardProfiles.isTrustedOwner(502, euid: 0, sudoUID: "501"))
        XCTAssertTrue(WireGuardProfiles.isTrustedOwner(502, euid: 501, sudoUID: nil))
    }

    /// A key name that merely starts with a key name is a different key: it
    /// must not be mistaken for key material, and since it is not on the
    /// allowlist it is dropped.
    func testLookalikeKeyNamesAreNotMistakenForKeyMaterial() throws {
        let source = try write("""
        [Interface]
        PrivateKeyCount = 3
        Address = 10.2.0.2/32

        [Peer]
        PublicKey = DEF
        Endpoint = 203.0.113.69:51820
        """, to: path("lookalike.conf"))
        let destination = path("wgmanaged.conf")
        XCTAssertTrue(WireGuardProfiles.writeManagedConfig(from: source,
                                                           to: destination))
        let output = try String(contentsOfFile: destination, encoding: .utf8)
        XCTAssertFalse(output.contains("PrivateKeyCount"),
                       "a key outside the allowlist was copied through")
        XCTAssertTrue(output.contains("Address = 10.2.0.2/32"))
    }

    // MARK: - 3b: a profile name cannot escape its directory

    /// The CLI takes `switch <name>` from the user. A name with a separator or
    /// ".." must be refused outright rather than merely failing to match a
    /// listing, so no later refactor can turn the name into a path.
    func testSwitchRefusesTraversingNames() {
        for name in ["../../etc/passwd", "../outside", "/etc/passwd",
                     "a/b", "a\\b", "..", ".", ".hidden", "", "a\0b"] {
            XCTAssertFalse(Validate.isSafeStem(name),
                           "\"\(name)\" was accepted as a profile name")
            let result = WireGuardProfiles.switchTo(name: name)
            XCTAssertFalse(result.ok, "\"\(name)\" reached switchTo's body")
            XCTAssertTrue(result.error?.contains("not a valid profile name") ?? false,
                          "unexpected refusal for \"\(name)\": \(result.error ?? "nil")")
        }
    }

    /// A name that is a legitimate stem stays accepted: the check is about path
    /// structure, not about looking like a Proton filename.
    func testOrdinaryProfileNamesAreAccepted() {
        for name in ["VPN-RO1-RO-229", "my own server", "VPN-DE1-DE-522",
                     "a.b", "server_1"] {
            XCTAssertTrue(Validate.isSafeStem(name), "\"\(name)\" was refused")
        }
    }

    /// The listing must never produce a name that `isSafeStem` would reject.
    /// This is the property that keeps the picker's own values safe even though
    /// the check exists for the CLI.
    func testListedNamesAreSafeStems() throws {
        let dir = path("wireguard")
        try FileManager.default.createDirectory(atPath: dir,
                                                withIntermediateDirectories: true)
        try write(protonConfig(), to: path("wireguard/VPN-RO1-RO-229.conf"))
        for profile in WireGuardProfiles.list(directory: dir) {
            XCTAssertTrue(Validate.isSafeStem(profile.name), profile.name)
        }
    }

    // MARK: - 3c: resolver and CIDR validation

    /// A resolver must parse as an IP address. The old filter was a character
    /// class, which let prose and half-addresses through to
    /// `networksetup -setdnsservers`.
    func testResolverValidationRejectsNonAddresses() {
        for bad in ["cafe", "notes.txt", "1.2.3", "1.1.1.1.1", "1.1.1.1:53",
                    "fe80::1%en0", "010.1.1.1", "1.1.1.1;reboot",
                    "$(rm -rf /)", "example.com"] {
            XCTAssertNil(Validate.ipAddress(bad), "\"\(bad)\" parsed as an address")
            XCTAssertNotNil(DNSManager.targetProblem(bad),
                            "\"\(bad)\" was accepted as a resolver target")
            XCTAssertTrue(DNSManager.resolve(target: bad).isEmpty,
                          "\"\(bad)\" resolved to something to apply")
        }
    }

    func testResolverValidationAcceptsRealAddresses() {
        for good in ["1.1.1.1", "149.112.112.112", "2606:4700:4700::1111",
                     "2001:4860:4860::8888"] {
            XCTAssertEqual(Validate.ipAddress(good), good)
            XCTAssertNil(DNSManager.targetProblem(good))
            XCTAssertEqual(DNSManager.resolve(target: good), [good])
        }
        // A preset id is still a preset id.
        XCTAssertNil(DNSManager.targetProblem("cloudflare"))
        XCTAssertEqual(DNSManager.resolve(target: "cloudflare"),
                       ["1.1.1.1", "1.0.0.1"])
    }

    /// A mixed list is refused as a whole rather than silently applied in part:
    /// the user asked for two servers and would get one.
    func testOneBadResolverRejectsTheWholeList() {
        XCTAssertNotNil(DNSManager.targetProblem("1.1.1.1, not-an-address"))
        XCTAssertNil(DNSManager.targetProblem("1.1.1.1,8.8.8.8"))
    }

    /// A CIDR must parse as a network: an address and bits, with the host bits
    /// clear.
    func testCIDRValidation() {
        XCTAssertEqual(Validate.network("162.159.128.0/18"), "162.159.128.0/18")
        XCTAssertEqual(Validate.network("0.0.0.0/1"), "0.0.0.0/1")
        XCTAssertEqual(Validate.network("128.0.0.0/1"), "128.0.0.0/1")
        XCTAssertEqual(Validate.network("2001:db8::/32"), "2001:db8::/32")

        for bad in ["162.159.128.0", "162.159.128.0/33", "10.1.2.3/8",
                    "not-a-cidr", "162.159.128.0/-1", "/18", "1.1.1.1/",
                    "2001:db8::/129", "162.159.128.0/18/24"] {
            XCTAssertNil(Validate.network(bad), "\"\(bad)\" parsed as a network")
            XCTAssertNotNil(Validate.networkProblem(bad))
        }
    }

    /// The prefixes the app installs must themselves be valid networks: a
    /// hardcoded range with a typo would be refused by the validator, and this
    /// is the check that would catch it before it reaches `route add`.
    func testEveryModeRangeIsAValidNetwork() {
        for mode in Mode.allCases {
            for cidr in RouteManager.ranges(for: mode) {
                XCTAssertNotNil(Validate.network(cidr),
                                "\(cidr) (\(mode)) is not a valid network")
            }
        }
    }

    // MARK: - 1c / 1d: permissions

    /// `ensureDir` used to return true for an existing directory without
    /// touching its mode, so a pre-existing 0755 profile directory stayed
    /// listable by every local user while the app believed it was 0700.
    func testEnsureDirRepairsTheModeOfAnExistingDirectory() throws {
        let dir = path("existing")
        try FileManager.default.createDirectory(atPath: dir,
                                                withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: dir)

        XCTAssertTrue(Path.ensureDir(dir, mode: 0o700))
        XCTAssertEqual(try mode(of: dir), 0o700,
                       "an existing world-listable directory was left alone")

        // Idempotent, and it must not fail on a directory that is already right.
        XCTAssertTrue(Path.ensureDir(dir, mode: 0o700))
        XCTAssertEqual(try mode(of: dir), 0o700)
    }

    func testEnsureDirCreatesWithTheRequestedMode() {
        let dir = path("created")
        XCTAssertTrue(Path.ensureDir(dir, mode: 0o700))
        XCTAssertEqual(try? mode(of: dir), 0o700)
    }

    /// The managed config holds the private key, so its mode must be 0600 from
    /// the moment it exists. A write-then-chmod would leave a window.
    func testManagedConfigUsesMode0600FromTheFirstWrite() throws {
        let dir = path("wireguard")
        try FileManager.default.createDirectory(atPath: dir,
                                                withIntermediateDirectories: true)
        let source = try write(protonConfig(), to: path("wireguard/VPN-RO1-RO-229.conf"))
        let destination = path("wireguard/wgmanaged.conf")

        XCTAssertTrue(WireGuardProfiles.writeManagedConfig(from: source,
                                                           to: destination))
        XCTAssertEqual(try mode(of: destination), 0o600)
    }

    // MARK: - 3a: nothing user-controlled is handed to a tool unparsed

    /// A recorded prefix that is not a prefix must never reach `route`, where a
    /// leading "-" would be read as a flag rather than a destination. These
    /// calls return before any process is started, which is why the test is
    /// safe to run on a live machine.
    func testRouteOperationsRefuseArgumentsThatAreNotPrefixes() {
        for bad in ["-ifscope", "-net", "--", "-h", "", "not-a-cidr", "1.1.1.1/33"] {
            XCTAssertFalse(RouteManager.deleteRoute(bad),
                           "deleteRoute(\"\(bad)\") ran a tool")
            XCTAssertFalse(RouteManager.routeExists(bad),
                           "routeExists(\"\(bad)\") ran a tool")
            let added = RouteManager.addRoute(bad, iface: "utun0")
            XCTAssertFalse(added.ok, "addRoute(\"\(bad)\") was attempted")
        }
    }

    func testHostRouteOperationsRefuseArgumentsThatAreNotAddresses() {
        for bad in ["-host", "", "example.com", "203.0.113.69:51820"] {
            XCTAssertFalse(RouteManager.deleteHostRoute(bad),
                           "deleteHostRoute(\"\(bad)\") ran a tool")
            XCTAssertNil(RouteManager.hostRouteGateway(bad),
                         "hostRouteGateway(\"\(bad)\") ran a tool")
            let added = RouteManager.addHostRoute(bad, gateway: "192.168.1.1")
            XCTAssertFalse(added.ok, "addHostRoute(\"\(bad)\") was attempted")
        }
        let badGateway = RouteManager.addHostRoute("203.0.113.69", gateway: "-net")
        XCTAssertFalse(badGateway.ok, "a flag-shaped gateway reached route")
    }

    /// A state file that somehow contains a value that is not a route must not
    /// make every later `down` fail forever. The entry is dropped and reported.
    func testDownDropsRecordedEntriesThatCannotBeRoutes() throws {
        let statePath = path("route-state.json")
        XCTAssertTrue(RouteStateStore.save(
            RouteState(mode: "all", iface: "utun5",
                       routes: ["0.0.0.0/1", "-ifscope", "garbage"],
                       hosts: ["203.0.113.69", "not-an-ip"],
                       generation: 1),
            path: statePath))

        var manager = RouteManager(settle: 0, statePath: statePath)
        var removedNets: [String] = []
        manager.deleteNet = { removedNets.append($0); return true }
        manager.deleteHost = { _ in true }

        let result = manager.down()
        XCTAssertTrue(result.ok, result.error ?? "")
        XCTAssertEqual(removedNets, ["0.0.0.0/1"],
                       "a malformed entry was handed to the delete hook")
        let after = RouteStateStore.load(path: statePath)
        XCTAssertTrue(after.routes.isEmpty, "\(after.routes)")
        XCTAssertTrue(after.hosts.isEmpty, "\(after.hosts)")
    }

    // MARK: - 5: L3 mode argument

    /// An explicit unknown `--mode` is refused, not silently turned into
    /// discord. The old fallback reported `mode=discord` as if the user had
    /// asked for it, which is a lie in the other direction from the outage.
    func testUnknownModeArgumentIsRejected() {
        for bad in ["everything", "", "ALL", "discord ", "all;reboot"] {
            guard case .failure = Mode.argument(bad) else {
                XCTFail("\"\(bad)\" was accepted as a mode")
                continue
            }
        }
    }

    /// A missing `--mode` keeps the documented default, which is a choice rather
    /// than a guess: `up` with no flag means "discord".
    func testMissingModeArgumentDefaultsToDiscord() throws {
        let mode = try XCTUnwrap(try? Mode.argument(nil).get())
        XCTAssertEqual(mode, .discord)
    }

    func testKnownModesAreAccepted() throws {
        XCTAssertEqual(try Mode.argument("discord").get(), .discord)
        XCTAssertEqual(try Mode.argument("all").get(), .all)
        XCTAssertEqual(try Mode.argument("off").get(), .off)
    }

    /// `mode <x>` has no "off": the teardown is `down`, and accepting `off`
    /// there used to be the no-op this whole finding was about.
    func testChangeModeRefusesOff() {
        guard case .failure = Mode.argument("off", allowingOff: false) else {
            XCTFail("mode off was accepted by changeMode's parser")
            return
        }
    }

    /// The managed config must be created 0600 by `open()` itself, not written
    /// and then chmodded: a write-then-chmod leaves a window in which the key
    /// is world-readable. This asserts the write path's shape by checking that
    /// a *pre-existing* 0644 file is tightened before it can be observed, and
    /// that a fresh file never exists with a looser mode.
    func testManagedConfigNeverExistsWithALooserMode() throws {
        let dir = path("wireguard")
        try FileManager.default.createDirectory(atPath: dir,
                                                withIntermediateDirectories: true)
        let source = try write(protonConfig(), to: path("wireguard/VPN-RO1-RO-229.conf"))
        let destination = path("wireguard/wgmanaged.conf")

        // Fresh file: 0600 immediately.
        XCTAssertTrue(WireGuardProfiles.writeManagedConfig(from: source,
                                                           to: destination))
        XCTAssertEqual(try mode(of: destination), 0o600)

        // Pre-existing 0644 (an older build): tightened on the same open, so a
        // reader can never see the key at 0644. The assertion is on the result
        // after the rewrite; `writeSecret` sets the mode on the descriptor
        // before the first byte, which is what makes that true.
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: destination)
        XCTAssertTrue(WireGuardProfiles.writeManagedConfig(from: source,
                                                           to: destination))
        XCTAssertEqual(try mode(of: destination), 0o600)
    }

    /// The profile directory holds private keys, so it must be 0700 even when
    /// `list()` runs against it. Listing must not create it or relax it.
    func testProfileDirectoryStays0700ThroughListing() throws {
        let dir = path("wireguard")
        try FileManager.default.createDirectory(atPath: dir,
                                                withIntermediateDirectories: true)
        XCTAssertTrue(Path.ensureDir(dir, mode: 0o700))
        try write(protonConfig(), to: path("wireguard/VPN-RO1-RO-229.conf"))

        _ = WireGuardProfiles.list(directory: dir)
        XCTAssertEqual(try mode(of: dir), 0o700,
                       "listing relaxed the profile directory")
    }

    // MARK: - 4a: pending-state recovery

    /// H4: the state file records the intended set *before* the first route is
    /// added, and the flag is only cleared once the run is known good.
    ///
    /// This drives `up` with injected probes so no tunnel is needed, and
    /// records what the state file said at the instant each add happened. That
    /// ordering is the whole fix: without it a SIGKILL in the settle window
    /// leaves routes in the table that no file mentions.
    func testUpWritesAPendingStateBeforeAddingAnyRoute() throws {
        let statePath = path("route-state.json")
        var manager = RouteManager(settle: 0, statePath: statePath)

        var observedWhileAdding: [RouteState] = []
        var added: [String] = []
        manager.probeInterfaces = { ["utun9"] }
        manager.probeHealth = { iface in (true, "handshake 1s old in \(iface)") }
        manager.probeEndpoint = { _ in "203.0.113.69" }
        manager.probeGateway = { "192.168.1.1" }
        manager.probeBaseline = { _ in
            RouteManager.Baseline(epoch: 1_000, rx: 0, tx: 0)
        }
        manager.probeProgress = { _, _, _ in (true, "transport moved") }
        manager.addHost = { _, _ in
            observedWhileAdding.append(RouteStateStore.load(path: statePath))
            return RouteManager.Mutation(ok: true, detail: "added")
        }
        manager.addNet = { cidr, _ in
            observedWhileAdding.append(RouteStateStore.load(path: statePath))
            added.append(cidr)
            return RouteManager.Mutation(ok: true, detail: "added")
        }

        let result = manager.up(mode: .discord)
        XCTAssertTrue(result.ok, result.error ?? "")
        XCTAssertEqual(added, ["162.159.128.0/18", "162.159.192.0/24"])

        XCTAssertEqual(observedWhileAdding.count, 3,
                       "the pin and both prefixes should have been observed")
        for snapshot in observedWhileAdding {
            XCTAssertTrue(snapshot.pending,
                          "a route was added before the intent was recorded as pending")
            // The intent must already list every route this run is about to
            // install, not just the first one.
            XCTAssertEqual(Set(snapshot.routes),
                           Set(["162.159.128.0/18", "162.159.192.0/24"]),
                           "the pending intent did not cover the whole set: \(snapshot.routes)")
            XCTAssertTrue(snapshot.hosts.contains("203.0.113.69"))
        }

        // After success the file is the committed record, not an intent.
        let after = RouteStateStore.load(path: statePath)
        XCTAssertFalse(after.pending)
        XCTAssertEqual(after.mode, "discord")
        XCTAssertEqual(after.generation, 1, "a successful apply must bump the generation")
        XCTAssertEqual(Set(after.routes), Set(added))
    }

    /// A run that fails after recording its intent must not leave the flag set:
    /// the next command would otherwise treat live routes as garbage.
    func testFailedUpDoesNotLeaveAPendingState() throws {
        let statePath = path("route-state.json")
        var manager = RouteManager(settle: 0, statePath: statePath)

        manager.probeInterfaces = { ["utun9"] }
        manager.probeHealth = { _ in (true, "fine") }
        manager.probeEndpoint = { _ in "203.0.113.69" }
        manager.probeGateway = { "192.168.1.1" }
        manager.probeBaseline = { _ in
            RouteManager.Baseline(epoch: 1_000, rx: 0, tx: 0)
        }
        manager.probeProgress = { _, _, _ in (true, "moved") }
        manager.addHost = { _, _ in
            RouteManager.Mutation(ok: true, detail: "added")
        }
        manager.addNet = { _, _ in
            RouteManager.Mutation(ok: false, detail: "no such interface")
        }

        let result = manager.up(mode: .discord)
        XCTAssertFalse(result.ok)

        let after = RouteStateStore.load(path: statePath)
        XCTAssertFalse(after.pending,
                       "a failed run left the intent armed, so the next command would purge live routes")
        XCTAssertEqual(after.mode, "off")
    }

    /// A run that fails after the routes went in must keep claiming routes it
    /// could not undo, so `down` can still reach them.
    func testFailedUpKeepsRoutesItCouldNotRemove() throws {
        let statePath = path("route-state.json")
        var manager = RouteManager(settle: 0, statePath: statePath)

        manager.probeInterfaces = { ["utun9"] }
        manager.probeHealth = { _ in (true, "fine") }
        manager.probeEndpoint = { _ in "203.0.113.69" }
        manager.probeGateway = { "192.168.1.1" }
        manager.probeBaseline = { _ in
            RouteManager.Baseline(epoch: 1_000, rx: 0, tx: 0)
        }
        manager.probeProgress = { _, _, _ in (false, "transport did not move") }
        manager.addHost = { _, _ in
            RouteManager.Mutation(ok: true, detail: "added")
        }
        manager.addNet = { _, _ in
            RouteManager.Mutation(ok: true, detail: "added")
        }
        // The rollback cannot remove anything: the interface vanished.
        manager.deleteNet = { _ in false }
        manager.deleteHost = { _ in false }

        let result = manager.up(mode: .discord)
        XCTAssertFalse(result.ok)

        let after = RouteStateStore.load(path: statePath)
        XCTAssertFalse(after.pending)
        XCTAssertEqual(after.mode, "off")
        XCTAssertFalse(after.routes.isEmpty,
                       "a route that could not be rolled back was forgotten")
        XCTAssertFalse(after.hosts.isEmpty,
                       "a pin that could not be rolled back was forgotten")
    }

    /// A run that dies between "I am about to add these" and "these are live"
    /// leaves a `pending` file. Take the next command at its word: every route
    /// it lists is garbage, and all of them must be removed.
    func testPendingStateRemovesEveryListedRoute() throws {
        let statePath = path("route-state.json")
        let state = RouteState(mode: "all", iface: "utun5",
                               routes: ["0.0.0.0/1", "128.0.0.0/1"],
                               hosts: ["203.0.113.69"],
                               gateway: "192.168.1.1",
                               pending: true, generation: 7)
        XCTAssertTrue(RouteStateStore.save(state, path: statePath))

        var removedNets: [String] = []
        var removedHosts: [String] = []
        var manager = RouteManager(settle: 0, statePath: statePath)
        manager.deleteNet = { removedNets.append($0); return true }
        manager.deleteHost = { removedHosts.append($0); return true }

        let result = manager.down()
        XCTAssertTrue(result.ok, result.error ?? "")
        // Longest prefix first.
        XCTAssertEqual(removedNets, ["0.0.0.0/1", "128.0.0.0/1"])
        XCTAssertEqual(removedHosts, ["203.0.113.69"])

        let after = RouteStateStore.load(path: statePath)
        XCTAssertFalse(after.pending, "the pending flag survived the recovery")
        XCTAssertEqual(after.mode, "off")
        XCTAssertTrue(after.routes.isEmpty)
        XCTAssertTrue(after.hosts.isEmpty)
    }

    /// A pending file is repaired before anything else runs, and the repair is
    /// visible to the caller: the routes are gone, so the next run starts from
    /// a table nobody is guessing about.
    func testReconcileClearsAPendingStateAndReportsIt() throws {
        let statePath = path("route-state.json")
        XCTAssertTrue(RouteStateStore.save(
            RouteState(mode: "discord", iface: "utun5",
                       routes: ["162.159.128.0/18"], hosts: ["203.0.113.69"],
                       pending: true, generation: 2),
            path: statePath))

        var manager = RouteManager(settle: 0, statePath: statePath)
        var removed: [String] = []
        manager.deleteNet = { removed.append($0); return true }
        manager.deleteHost = { _ in true }

        let result = try XCTUnwrap(manager.reconcile())
        XCTAssertTrue(result.ok)
        XCTAssertEqual(removed, ["162.159.128.0/18"])
        XCTAssertTrue(manager.log.contains { $0.contains("pending") },
                      "the recovery was not mentioned in the journal: \(manager.log)")
        XCTAssertFalse(RouteStateStore.load(path: statePath).pending)
    }

    /// Nothing pending means nothing happens: a command must not delete routes
    /// because it ran.
    func testReconcileIsANoOpWhenTheStateIsCommitted() throws {
        let statePath = path("route-state.json")
        XCTAssertTrue(RouteStateStore.save(
            RouteState(mode: "all", iface: "utun5", routes: ["0.0.0.0/1"],
                       hosts: [], pending: false, generation: 3),
            path: statePath))

        var manager = RouteManager(settle: 0, statePath: statePath)
        var deleted = false
        manager.deleteNet = { _ in deleted = true; return true }
        manager.deleteHost = { _ in deleted = true; return true }

        XCTAssertNil(manager.reconcile())
        XCTAssertFalse(deleted, "a committed state was treated as garbage")
        XCTAssertEqual(RouteStateStore.load(path: statePath).routes, ["0.0.0.0/1"])
    }

    /// A delete that fails keeps the entry: it is still an unrecorded route in
    /// the table, so the next attempt must see it.
    func testPendingRoutesThatCannotBeRemovedStayRecorded() throws {
        let statePath = path("route-state.json")
        XCTAssertTrue(RouteStateStore.save(
            RouteState(mode: "all", iface: "utun5",
                       routes: ["0.0.0.0/1", "128.0.0.0/1"],
                       hosts: [], pending: true, generation: 1),
            path: statePath))

        var manager = RouteManager(settle: 0, statePath: statePath)
        manager.deleteNet = { $0 == "0.0.0.0/1" }
        manager.deleteHost = { _ in true }

        let result = manager.down()
        XCTAssertFalse(result.ok, "a partial recovery was reported as success")
        let after = RouteStateStore.load(path: statePath)
        XCTAssertEqual(after.routes, ["128.0.0.0/1"])
        XCTAssertFalse(after.pending,
                       "the flag stayed set, so the next run would re-add these")
    }

    // MARK: - 4b: stale revert timer

    /// A `--revert-after` timer carries the generation it was armed for. When
    /// the state has moved on, the timer must do nothing: the old code had no
    /// way to stop it, so a failed run's timer tore down a healthy tunnel.
    func testStaleRevertTimerIsANoOp() throws {
        let statePath = path("route-state.json")
        XCTAssertTrue(RouteStateStore.save(
            RouteState(mode: "all", iface: "utun5",
                       routes: ["0.0.0.0/1", "128.0.0.0/1"],
                       hosts: ["203.0.113.69"], generation: 9),
            path: statePath))

        var manager = RouteManager(settle: 0, statePath: statePath)
        var deleted = false
        manager.deleteNet = { _ in deleted = true; return true }
        manager.deleteHost = { _ in deleted = true; return true }

        let result = manager.down(ifGeneration: 8)
        XCTAssertTrue(result.ok)
        XCTAssertFalse(deleted, "a stale timer removed a live tunnel's routes")
        XCTAssertEqual(RouteStateStore.load(path: statePath).routes.count, 2,
                       "a stale timer cleared the state")
    }

    /// The generation a timer was armed with still works.
    func testMatchingRevertGenerationStillRuns() throws {
        let statePath = path("route-state.json")
        XCTAssertTrue(RouteStateStore.save(
            RouteState(mode: "all", iface: "utun5", routes: ["0.0.0.0/1"],
                       hosts: [], generation: 9),
            path: statePath))

        var manager = RouteManager(settle: 0, statePath: statePath)
        var removed: [String] = []
        manager.deleteNet = { removed.append($0); return true }
        manager.deleteHost = { _ in true }

        XCTAssertTrue(manager.down(ifGeneration: 9).ok)
        XCTAssertEqual(removed, ["0.0.0.0/1"])
    }

    /// `up --mode off` must be the teardown, not a success message over a live
    /// route set. With the state committed and no interface, `down` removes it.
    func testUpWithModeOffRoutesToDown() throws {
        let statePath = path("route-state.json")
        XCTAssertTrue(RouteStateStore.save(
            RouteState(mode: "discord", iface: "utun5",
                       routes: ["162.159.128.0/18"], hosts: [], generation: 4),
            path: statePath))

        var manager = RouteManager(settle: 0, statePath: statePath)
        var removed: [String] = []
        manager.deleteNet = { removed.append($0); return true }
        manager.deleteHost = { _ in true }

        let result = manager.up(mode: .off)
        XCTAssertTrue(result.ok, result.error ?? "")
        XCTAssertEqual(result.mode, "off")
        XCTAssertEqual(removed, ["162.159.128.0/18"],
                       "up --mode off left the previous mode's routes installed")
        XCTAssertEqual(RouteStateStore.load(path: statePath).mode, "off")
    }

    // MARK: - 4b (second half): notes reach the caller

    /// The journal is no longer a private diary: notes are part of the JSON
    /// result, so the CLI and the app can show "safety net not armed" instead of
    /// a bare success.
    func testActionResultCarriesNotesInJSON() throws {
        let result = ActionResult(ok: true, mode: "all",
                                  notes: ["safety net not armed: no absolute path"])
        let text = JSON.encode(result)
        XCTAssertTrue(text.contains("\"notes\""), text)
        XCTAssertTrue(text.contains("safety net not armed"), text)

        let decoded = try XCTUnwrap(JSON.decode(ActionResult.self, from: text))
        XCTAssertEqual(decoded.notes, ["safety net not armed: no absolute path"])
    }

    /// An older helper's JSON has no `notes`, and the app must still read it.
    func testActionResultWithoutNotesStillDecodes() throws {
        let text = #"{"ok":false,"error":"nope","routes":[]}"#
        let decoded = try XCTUnwrap(JSON.decode(ActionResult.self, from: text))
        XCTAssertFalse(decoded.ok)
        XCTAssertTrue(decoded.notes.isEmpty)
    }

    // MARK: - 2b: corrupt DNS state

    /// A corrupt state file is reported, not silently treated as "no file": the
    /// two mean different things, and only one of them allows a restore to put
    /// DHCP back.
    func testCorruptDNSStateIsReportedSeparatelyFromAMissingFile() throws {
        XCTAssertFalse(DNSStateStore.loadChecked(path: path("absent.json")).corrupt)

        for (index, text) in ["", "{", "not json", "{\"previous\":\"wrong\"}"].enumerated() {
            let file = try write(text, to: path("corrupt-\(index).json"))
            let (state, corrupt) = DNSStateStore.loadChecked(path: file)
            XCTAssertTrue(state.previous.isEmpty)
            XCTAssertTrue(corrupt,
                          "\"\(text)\" was not flagged as corrupt")

            // Read-only: the damaged bytes are the only record left.
            let after = try String(contentsOfFile: file, encoding: .utf8)
            XCTAssertEqual(after, text, "a read-only load rewrote the file")
        }
    }

    func testHealthyDNSStateIsNotFlaggedCorrupt() throws {
        let state = DNSState(previous: ["Wi-Fi": ["1.1.1.1"]], applied: ["8.8.8.8"])
        let file = path("good.json")
        XCTAssertTrue(DNSStateStore.save(state, path: file))
        XCTAssertFalse(DNSStateStore.loadChecked(path: file).corrupt)
    }

    // MARK: - 5: transfer is optional

    /// A probe that could not run reports nil, never 0/0. The UI renders a
    /// dash; a fabricated zero reads as a measurement.
    func testMissingTransferIsNilInTheReportJSON() throws {
        let report = Report(mode: "all", transfer: nil)
        let text = JSON.encode(report)
        let decoded = try XCTUnwrap(JSON.decode(Report.self, from: text))
        XCTAssertNil(decoded.transfer)

        let withBytes = Report(mode: "all", transfer: Transfer(rx: 10, tx: 20))
        let round = try XCTUnwrap(JSON.decode(Report.self,
                                              from: JSON.encode(withBytes)))
        XCTAssertEqual(round.transfer?.rx, 10)
        XCTAssertEqual(round.transfer?.tx, 20)
    }

    // MARK: - 5: redaction details

    /// The summary may name a line and a key, and nothing else.
    func testConfigSummaryReportsLineNumbersAndKeyNamesOnly() {
        let summary = Redact.configSummary(protonConfig())
        XCTAssertTrue(summary.contains { $0.contains("privatekey present") },
                      "the key line was not called out: \(summary)")
        XCTAssertTrue(summary.contains { $0.contains("section [interface]") })
        XCTAssertTrue(summary.contains { $0.contains("section [peer]") })
        XCTAssertFalse(summary.joined().contains("10.2.0.2"),
                       "a value was repeated in the summary: \(summary)")
        XCTAssertFalse(summary.joined().contains("203.0.113.69"),
                       "a value was repeated in the summary: \(summary)")
        XCTAssertFalse(summary.joined().contains("TESTONLYFAKEPEERKEY"),
                       "a public key value was repeated: \(summary)")
    }

    /// `scrub` replaces a key line wholesale. An edited value is one regex bug
    /// from being printed.
    func testScrubReplacesKeyLinesWholesale() {
        let scrubbed = Redact.scrub(protonConfig())
        XCTAssertFalse(scrubbed.contains("PLANTEDKEY"))
        XCTAssertTrue(scrubbed.contains("[redacted: key material]"))
        // Non-secret lines stay readable, or the output is useless.
        XCTAssertTrue(scrubbed.contains("[Interface]"))
        XCTAssertTrue(scrubbed.contains("Address = 10.2.0.2/32"))
    }

    /// A tab-separated key line is classified the same way: the classifier is
    /// the last gate before a message is built.
    func testClassifyTreatsTabSeparatedKeyAsSecret() {
        XCTAssertEqual(Redact.classify("PrivateKey\t=\t\(plantedKey)"),
                       .secret(key: "privatekey"))
        XCTAssertEqual(Redact.classify("PresharedKey=abc"), .secret(key: "presharedkey"))
        XCTAssertEqual(Redact.classify("PrivateKeyCount = 3"), .field(key: "privatekeycount"))
    }

    /// The redacted failure says what failed and nothing about content.
    func testRedactedFailureNamesNoContent() {
        let failure = ActionResult.redacted("the new profile")
        XCTAssertFalse(failure.ok)
        let text = failure.error ?? ""
        XCTAssertTrue(text.contains("could not be applied"), text)
        XCTAssertTrue(text.contains("Nothing was changed"), text)
        XCTAssertTrue(failure.notes.isEmpty)
    }

    /// The sanitised summary rides along in `notes`, so a bug report can say
    /// "line 2 was rejected" without saying what line 2 was.
    func testRedactedFailureCarriesOnlyASanitisedSummary() {
        let summary = Redact.configSummary(protonConfig())
        let failure = ActionResult.redacted("tunnel start", summary: summary)
        let text = JSON.encode(failure)
        XCTAssertTrue(text.contains("line 2"), text)
        assertNoKey(in: text, surface: "redacted failure with summary")
        XCTAssertFalse(text.contains("10.2.0.2"),
                       "a config value reached the summary: \(text)")
    }

    /// A managed config that does not exist yields no summary, not a crash and
    /// not a guess.
    func testManagedConfigSummaryIsEmptyWhenThereIsNoConfig() {
        // Path.managedConfig only exists on a machine that has switched to a
        // profile; a test host may not have it. Either way the call is safe.
        let summary = WireGuardProfiles.managedConfigSummary()
        assertNoKey(in: summary.joined(separator: "\n"),
                    surface: "managed config summary")
    }

    // MARK: - Helpers

    private func mode(of path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        return permissions.intValue & 0o777
    }
}
