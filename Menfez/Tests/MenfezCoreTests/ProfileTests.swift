import XCTest
@testable import MenfezCore

/// A WireGuard config is a private key with some metadata around it, and this
/// layer is the one that lists those files, parses them, and rewrites one of
/// them for wg-quick. These tests pin the two promises that must never regress:
/// a key never leaves the layer, and the file the user owns is never modified.
///
/// Every test builds its own directory under NSTemporaryDirectory(); nothing
/// here reads or writes ~/Library/Application Support/Menfez.
final class ProfileTests: XCTestCase {

    // MARK: - Fixtures

    private var root = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("menfez-profiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if !root.isEmpty {
            try? FileManager.default.removeItem(atPath: root)
        }
        root = ""
        try super.tearDownWithError()
    }

    private func directory(_ name: String = "wireguard") throws -> String {
        let path = (root as NSString).appendingPathComponent(name)
        try FileManager.default.createDirectory(atPath: path,
                                                withIntermediateDirectories: true)
        return path
    }

    private func file(_ name: String, in directory: String) -> String {
        (directory as NSString).appendingPathComponent(name)
    }

    @discardableResult
    private func write(_ text: String, named name: String,
                       in directory: String) throws -> String {
        let path = file(name, in: directory)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// The shape ProtonVPN actually ships, with every line that the scanner has
    /// to ignore present.
    private func protonConfig(endpoint: String = "203.0.113.69:51820",
                              key: String = "TESTONLYFAKEKEYDONOTUSE0000000000000000000A=")
        -> String {
        """
        [Interface]
        # Bouncing = 15
        # NetShield = 2
        PrivateKey = \(key)
        Address = 10.2.0.2/32, 2a07:b944::2:2/128
        DNS = 10.2.0.1, 2a07:b944::2:1

        [Peer]
        # RO#229
        PublicKey = TESTONLYFAKEPEERKEYDONOTUSE000000000000000A=
        AllowedIPs = 0.0.0.0/0, ::/0
        Endpoint = \(endpoint)

        """
    }

    // MARK: - Keys never leave the layer

    /// The single most important rule in this file. `list()` parses user files
    /// that contain key material, and its result is encoded into JSON that is
    /// printed by the CLI, logged, and shown in the UI. If a key can reach that
    /// JSON it is a credential leak, so the assertion is on the whole encoded
    /// result rather than on any one field.
    func testListNeverReturnsAPrivateKeyAnywhereInItsJSON() throws {
        let dir = try directory()
        try write(protonConfig(key: "THISMUSTNEVERAPPEAR"),
                  named: "VPN-RO1-RO-229.conf", in: dir)
        try write(protonConfig(key: "THISMUSTNEVERAPPEAR"),
                  named: "VPN-DE1-DE-522.conf", in: dir)

        let profiles = WireGuardProfiles.list(directory: dir)
        XCTAssertEqual(profiles.count, 2)

        let encoded = JSON.encode(profiles)
        XCTAssertFalse(encoded.contains("THISMUSTNEVERAPPEAR"),
                       "the private key reached the encoded profile list: \(encoded)")
        XCTAssertFalse(encoded.lowercased().contains("privatekey"),
                       "a field named after the key reached the JSON: \(encoded)")
        for profile in profiles {
            // Belt and braces: no field of the model can carry the value.
            let fields = [profile.name, profile.file, profile.endpoint ?? "",
                          profile.host ?? "", profile.country ?? "",
                          profile.error ?? ""]
            for field in fields {
                XCTAssertFalse(field.contains("THISMUSTNEVERAPPEAR"))
            }
        }
    }

    /// The scanner keeps exactly two values. Everything else — the key above
    /// all — falls through to `default` and is dropped without being copied.
    func testScanKeepsOnlyAddressAndEndpoint() {
        let parsed = WireGuardProfiles.scan(
            protonConfig(key: "THISMUSTNEVERAPPEAR"))
        XCTAssertEqual(parsed.address, "10.2.0.2/32, 2a07:b944::2:2/128")
        XCTAssertEqual(parsed.endpoint, "203.0.113.69:51820")
        // The scanner has no field that could hold a key, and neither captured
        // value absorbed the key line.
        XCTAssertFalse(parsed.address?.contains("THISMUSTNEVERAPPEAR") ?? false)
        XCTAssertFalse(parsed.endpoint?.contains("THISMUSTNEVERAPPEAR") ?? false)
    }

    /// A key line in an unusual form must not leak either. `PrivateKey` with no
    /// spaces and a `PresharedKey` are both still key material.
    func testScannerIgnoresEverySpellingOfAKeyLine() {
        let text = """
        [Interface]
        PrivateKey=OBNOXIOUSKEYONE
        presharedkey = OBNOXIOUSKEYTWO
        Address = 10.9.0.2/32
        """
        let parsed = WireGuardProfiles.scan(text)
        XCTAssertEqual(parsed.address, "10.9.0.2/32")
        XCTAssertNil(parsed.endpoint)
        let encoded = JSON.encode(WireGuardProfiles.list(directory: root))
        XCTAssertFalse(encoded.contains("OBNOXIOUS"))
    }

    // MARK: - Management artefacts are hidden

    /// `wgsplit`, `wgmanaged` and any `*-split` copy are our own scaffolding,
    /// not servers the user chose. Offering them in the picker invites the user
    /// to "switch" to a file that is really an artefact of switching.
    func testManagementStemsAreHiddenAndRealProfilesAreNot() throws {
        let dir = try directory()
        try write(protonConfig(), named: "VPN-RO1-RO-229.conf", in: dir)
        try write(protonConfig(), named: "VPN-DE1-DE-522.conf", in: dir)
        try write(protonConfig(), named: "wgsplit.conf", in: dir)
        try write(protonConfig(), named: "wgmanaged.conf", in: dir)
        try write(protonConfig(), named: "VPN-RO1-RO-229-split.conf", in: dir)
        try write(protonConfig(), named: "anything-split.conf", in: dir)

        let names = WireGuardProfiles.list(directory: dir).map(\.name)
        XCTAssertEqual(names, ["VPN-DE1-DE-522", "VPN-RO1-RO-229"],
                       "management artefacts leaked into the picker: \(names)")
        XCTAssertFalse(names.contains("wgsplit"))
        XCTAssertFalse(names.contains("wgmanaged"))
        XCTAssertFalse(names.contains { $0.hasSuffix("-split") })
    }

    /// Only `.conf` files are profiles. A stray README or editor backup in the
    /// directory must not become a row the user can click.
    func testOnlyConfFilesAreListed() throws {
        let dir = try directory()
        try write(protonConfig(), named: "VPN-RO1-RO-229.conf", in: dir)
        try write(protonConfig(), named: "notes.txt", in: dir)
        try write(protonConfig(), named: "VPN-DE1-DE-522.conf.bak", in: dir)

        let names = WireGuardProfiles.list(directory: dir).map(\.name)
        XCTAssertEqual(names, ["VPN-RO1-RO-229"])
    }

    /// The listing is sorted so the picker does not jitter: filesystem order
    /// changes when a file is rewritten.
    func testListingIsSortedByName() throws {
        let dir = try directory()
        for stem in ["VPN-NL1-NL-350", "VPN-BG1-BG-23", "VPN-GR1-GR-70"] {
            try write(protonConfig(), named: stem + ".conf", in: dir)
        }
        let names = WireGuardProfiles.list(directory: dir).map(\.name)
        XCTAssertEqual(names, names.sorted())
        XCTAssertEqual(names.count, 3)
    }

    /// A missing directory is an empty picker, not a crash: the app runs before
    /// the user has ever added a profile.
    func testMissingDirectoryListsNothing() {
        let absent = (root as NSString).appendingPathComponent("does-not-exist")
        XCTAssertTrue(WireGuardProfiles.list(directory: absent).isEmpty)
    }

    // MARK: - Country parsing

    /// Proton names files "VPN-<city>-<CC><number>", so the country is the
    /// second group. The third group is the city's own code, and reading it
    /// would put the wrong flag on the row.
    func testCountryComesFromTheCityGroup() {
        XCTAssertEqual(WireGuardProfiles.countryCode("VPN-RO1-RO-229"), "RO")
        XCTAssertEqual(WireGuardProfiles.countryCode("VPN-DE1-DE-522"), "DE")
        XCTAssertEqual(WireGuardProfiles.countryCode("VPN-BG1-BG-23"), "BG")
        XCTAssertEqual(WireGuardProfiles.countryCode("VPN-NL1-NL-350"), "NL")
        XCTAssertEqual(WireGuardProfiles.countryCode("VPN-GR1-GR-70"), "GR")
    }

    /// A stem that does not match yields nil — the UI draws no flag rather than
    /// a wrong one. It must never guess and never crash.
    func testUnrecognisedStemHasNoCountry() {
        for stem in ["", "myprofile", "vpn-ro1-ro-229", "WI-FI",
                     "VPN-RO-229", "AB-RO1-RO-229", "VPN-1RO-RO-229",
                     "wgsplit", "VPN-", "-RO1"] {
            XCTAssertNil(WireGuardProfiles.countryCode(stem),
                         "\"\(stem)\" must not yield a country code")
        }
    }

    /// The parsed country must reach the row, so the flag the user sees comes
    /// from the filename and nothing else.
    func testListingCarriesTheParsedCountry() throws {
        let dir = try directory()
        try write(protonConfig(), named: "VPN-RO1-RO-229.conf", in: dir)
        try write(protonConfig(), named: "my own server.conf", in: dir)

        let profiles = WireGuardProfiles.list(directory: dir)
        let romania = try XCTUnwrap(profiles.first { $0.name == "VPN-RO1-RO-229" })
        XCTAssertEqual(romania.country, "RO")
        let unnamed = try XCTUnwrap(profiles.first { $0.name == "my own server" })
        XCTAssertNil(unnamed.country)
    }

    // MARK: - Endpoint parsing

    /// The endpoint is read from [Peer] only. The same key under [Interface] is
    /// not the peer we talk to, and reading it would make the wrong profile
    /// look active.
    func testEndpointIsReadFromThePeerSection() {
        let text = """
        [Interface]
        PrivateKey = ABC
        Endpoint = 203.0.113.9:1111
        Address = 10.2.0.2/32

        [Peer]
        PublicKey = DEF
        Endpoint = 198.51.100.7:51820
        """
        XCTAssertEqual(WireGuardProfiles.scan(text).endpoint,
                       "198.51.100.7:51820")
    }

    /// An endpoint before any section header belongs to no section, so it must
    /// be ignored rather than adopted by whichever section comes next.
    func testEndpointBeforeAnySectionIsIgnored() {
        let text = """
        Endpoint = 203.0.113.9:1111
        PrivateKey = ABC

        [Interface]
        Address = 10.2.0.2/32

        [Peer]
        PublicKey = DEF
        """
        XCTAssertNil(WireGuardProfiles.scan(text).endpoint)
    }

    /// Section headers are matched case-insensitively; Proton's own files use
    /// title case, but a hand-edited file may not.
    func testSectionsAreMatchedCaseInsensitively() {
        let text = """
        [INTERFACE]
        ADDRESS = 10.2.0.2/32
        [peer]
        endpoint = 198.51.100.7:51820
        """
        let parsed = WireGuardProfiles.scan(text)
        XCTAssertEqual(parsed.address, "10.2.0.2/32")
        XCTAssertEqual(parsed.endpoint, "198.51.100.7:51820")
    }

    /// Both endpoint shapes occur in real profiles: a bare IPv4 or hostname,
    /// and a bracketed IPv6 literal. The host half is what gets compared with
    /// the live tunnel endpoint, so the brackets must come off.
    func testHostPartHandlesBothEndpointShapes() {
        XCTAssertEqual(WireGuardProfiles.hostPart("198.51.100.7:51820"),
                       "198.51.100.7")
        XCTAssertEqual(WireGuardProfiles.hostPart("[2001:db8::7]:51820"),
                       "2001:db8::7")
        XCTAssertEqual(WireGuardProfiles.hostPart("node.example.net:51820"),
                       "node.example.net")
        XCTAssertNil(WireGuardProfiles.hostPart(""))
    }

    /// The bracketed IPv6 form has to survive the whole path from file to model.
    func testIPv6EndpointReachesTheModelWithoutBrackets() throws {
        let dir = try directory()
        try write(protonConfig(endpoint: "[2a02:6ea0:da08:6202::10]:51820"),
                  named: "VPN-RO1-RO-229.conf", in: dir)

        let profile = try XCTUnwrap(WireGuardProfiles.list(directory: dir).first)
        XCTAssertEqual(profile.endpoint, "[2a02:6ea0:da08:6202::10]:51820")
        XCTAssertEqual(profile.host, "2a02:6ea0:da08:6202::10")
    }

    /// A commented-out endpoint is the form Proton uses to offer IPv6 in the
    /// same file. Treating a comment as data would point the app at an address
    /// the user deliberately did not choose.
    func testCommentedEndpointIsIgnored() throws {
        let dir = try directory()
        let text = protonConfig() + "# Endpoint = [2a02:6ea0:da08:6202::11]:51820\n"
        try write(text, named: "VPN-RO1-RO-229.conf", in: dir)

        let profile = try XCTUnwrap(WireGuardProfiles.list(directory: dir).first)
        XCTAssertEqual(profile.endpoint, "203.0.113.69:51820")
        XCTAssertEqual(profile.host, "203.0.113.69")
    }

    /// Windows line endings are common in exported Proton files. A trailing
    /// carriage return must not end up inside the parsed endpoint.
    func testCRLFEndpointHasNoTrailingCarriageReturn() throws {
        let dir = try directory()
        let text = protonConfig().replacingOccurrences(of: "\n", with: "\r\n")
        try write(text, named: "VPN-RO1-RO-229.conf", in: dir)

        let profile = try XCTUnwrap(WireGuardProfiles.list(directory: dir).first)
        XCTAssertEqual(profile.endpoint, "203.0.113.69:51820")
        XCTAssertEqual(profile.host, "203.0.113.69")
    }

    // MARK: - Malformed input

    /// A file the scanner cannot make sense of is still returned to the caller,
    /// so the picker can show the name the user gave it and mark it as broken
    /// instead of silently swallowing it. Nothing here may crash.
    func testMalformedProfilesAreListedAndDoNotHideTheGoodOnes() throws {
        let dir = try directory()
        try write(protonConfig(), named: "VPN-RO1-RO-229.conf", in: dir)
        try write("", named: "empty.conf", in: dir)
        try write("just some text\nwith no sections\n",
                  named: "no-sections.conf", in: dir)
        try write("[Interface]\nAddress = 10.0.0.2/32\n",
                  named: "no-peer.conf", in: dir)
        try write("[Peer]\nPublicKey = DEF\n", named: "no-endpoint.conf", in: dir)
        try write("[Interface]\nPrivateKey = ABC\n[Peer]\nPublicKey = DEF\n",
                  named: "no-address.conf", in: dir)

        let profiles = WireGuardProfiles.list(directory: dir)
        XCTAssertEqual(profiles.count, 6, "a malformed file hid another profile")

        let good = try XCTUnwrap(profiles.first { $0.name == "VPN-RO1-RO-229" })
        XCTAssertEqual(good.endpoint, "203.0.113.69:51820")
        XCTAssertNil(good.error)

        let empty = try XCTUnwrap(profiles.first { $0.name == "empty" })
        XCTAssertNil(empty.endpoint)
        XCTAssertNil(empty.host)
        XCTAssertNil(empty.country)
        XCTAssertFalse(empty.active)

        let noEndpoint = try XCTUnwrap(profiles.first { $0.name == "no-endpoint" })
        XCTAssertNil(noEndpoint.endpoint)
    }

    /// The stated contract is that a broken profile is *reported*, not merely
    /// tolerated: the UI has an `error` field on `Profile` for exactly this.
    /// A file with no [Interface], no [Peer] or no Endpoint carries a message
    /// instead of reaching the user as an ordinary row with empty values.
    func testMalformedProfileIsReportedWithAnError() throws {
        let dir = try directory()
        try write("[Interface]\nAddress = 10.0.0.2/32\n",
                  named: "no-peer.conf", in: dir)
        try write("", named: "empty.conf", in: dir)

        let profiles = WireGuardProfiles.list(directory: dir)
        for profile in profiles {
            XCTAssertNotNil(profile.error,
                            "\(profile.name) is unusable but carries no error")
        }
        // A complete profile must not be flagged.
        try write(protonConfig(), named: "VPN-RO1-RO-229.conf", in: dir)
        let good = try XCTUnwrap(WireGuardProfiles.list(directory: dir)
                                    .first { $0.name == "VPN-RO1-RO-229" })
        XCTAssertNil(good.error)
    }

    /// A file that cannot be read as UTF-8 is skipped rather than turned into a
    /// half-parsed row: there is no safe way to guess what the bytes meant.
    func testUnreadableFileIsSkippedWithoutBreakingTheListing() throws {
        let dir = try directory()
        try write(protonConfig(), named: "VPN-RO1-RO-229.conf", in: dir)
        let junk = file("binary.conf", in: dir)
        try Data([0xff, 0xfe, 0x00, 0x01, 0x80]).write(to: URL(fileURLWithPath: junk))

        let names = WireGuardProfiles.list(directory: dir).map(\.name)
        XCTAssertEqual(names, ["VPN-RO1-RO-229"])
    }

    // MARK: - Managed config

    /// The rewrite is what makes wg-quick usable under a route table we own:
    /// `Table = off` stops wg-quick adding its own routes, `AllowedIPs` must
    /// accept everything we send, and a `DNS =` line would hijack the resolver
    /// behind the app's back.
    func testManagedConfigRewritesTableAllowedIPsAndDNS() throws {
        let dir = try directory()
        let source = try write(protonConfig(), named: "VPN-RO1-RO-229.conf",
                               in: dir)
        let destination = file("wgmanaged.conf", in: dir)

        XCTAssertTrue(WireGuardProfiles.writeManagedConfig(from: source,
                                                           to: destination))
        let output = try String(contentsOfFile: destination, encoding: .utf8)

        let sections = decomposed(output)
        XCTAssertTrue(sections.interface.contains("Table = off"),
                      "Table = off is missing from [Interface]:\n\(output)")
        XCTAssertEqual(sections.interface.filter { $0 == "Table = off" }.count, 1,
                       "Table = off must appear exactly once")

        XCTAssertEqual(sections.peer.filter { $0.hasPrefix("AllowedIPs") },
                       ["AllowedIPs = 0.0.0.0/0, ::/0"])
        XCTAssertFalse(output.contains("DNS ="),
                       "the DNS line would let wg-quick hijack the resolver")
        XCTAssertFalse(output.contains("2a07:b944::2:1"),
                       "the DNS address survived in the managed config")
    }

    /// An explicit `Table = auto` in the user's file must be replaced, not
    /// duplicated: two Table keys are a wg-quick error.
    func testExistingTableLineIsReplacedNotDuplicated() throws {
        let dir = try directory()
        let source = try write("""
        [Interface]
        PrivateKey = ABC
        Address = 10.2.0.2/32
        Table = auto

        [Peer]
        PublicKey = DEF
        AllowedIPs = 10.0.0.0/8
        Endpoint = 198.51.100.7:51820
        """, named: "hand.conf", in: dir)
        let destination = file("wgmanaged.conf", in: dir)

        XCTAssertTrue(WireGuardProfiles.writeManagedConfig(from: source,
                                                           to: destination))
        let output = try String(contentsOfFile: destination, encoding: .utf8)
        let interface = decomposed(output).interface
        XCTAssertEqual(interface.filter { $0.hasPrefix("Table") }, ["Table = off"])
        XCTAssertFalse(output.contains("Table = auto"))
    }

    /// A narrow AllowedIPs in the source must not survive: the peer has to
    /// accept every packet we route to it, or part of the tunnel is black-holed.
    func testNarrowAllowedIPsIsReplacedByTheDefaultRoute() throws {
        let dir = try directory()
        let source = try write("""
        [Interface]
        PrivateKey = ABC
        Address = 10.2.0.2/32

        [Peer]
        PublicKey = DEF
        AllowedIPs = 162.159.128.0/18
        Endpoint = 198.51.100.7:51820
        """, named: "hand.conf", in: dir)
        let destination = file("wgmanaged.conf", in: dir)

        XCTAssertTrue(WireGuardProfiles.writeManagedConfig(from: source,
                                                           to: destination))
        let output = try String(contentsOfFile: destination, encoding: .utf8)
        XCTAssertFalse(output.contains("162.159.128.0/18"))
        XCTAssertTrue(output.contains("AllowedIPs = 0.0.0.0/0, ::/0"))
    }

    /// The key is the one line that must be copied through untouched: without
    /// it the generated config cannot bring an interface up. "Byte for byte"
    /// means no re-wrapping, no normalising of the base64 padding and no
    /// change of the spaces around the equals sign.
    func testManagedConfigPreservesThePrivateKeyByteForByte() throws {
        let dir = try directory()
        let key = "TESTONLYFAKEKEYDONOTUSE0000000000000000000A="
        let sourceLine = "PrivateKey = \(key)"
        let source = try write(protonConfig(key: key), named: "VPN-RO1-RO-229.conf",
                               in: dir)
        let destination = file("wgmanaged.conf", in: dir)

        XCTAssertTrue(WireGuardProfiles.writeManagedConfig(from: source,
                                                           to: destination))
        let output = try String(contentsOfFile: destination, encoding: .utf8)
        XCTAssertTrue(output.contains(sourceLine),
                      "the PrivateKey line was altered:\n\(output)")
        XCTAssertEqual(output.components(separatedBy: key).count - 1, 1,
                       "the key appears more or less than once")
        XCTAssertTrue(output.contains("Address = 10.2.0.2/32"),
                      "the interface address is needed by wg-quick")
        XCTAssertTrue(output.contains("Endpoint = 203.0.113.69:51820"))
        XCTAssertTrue(output.hasSuffix("\n"),
                      "wg-quick insists on a trailing newline")
    }

    /// A key line with no spaces around the equals sign is still key material
    /// and must be passed through in the form the user wrote it.
    func testPrivateKeyWithoutSpacesIsAlsoPreserved() throws {
        let dir = try directory()
        let source = try write("""
        [Interface]
        PrivateKey=SHORTFORMKEY=
        Address = 10.2.0.2/32

        [Peer]
        PublicKey = DEF
        Endpoint = 198.51.100.7:51820
        """, named: "hand.conf", in: dir)
        let destination = file("wgmanaged.conf", in: dir)

        XCTAssertTrue(WireGuardProfiles.writeManagedConfig(from: source,
                                                           to: destination))
        let output = try String(contentsOfFile: destination, encoding: .utf8)
        XCTAssertTrue(output.contains("PrivateKey=SHORTFORMKEY="), output)
    }

    /// The generated file holds a working key, so it must never be world- or
    /// group-readable. 0600 has to be set even when the file already existed.
    func testManagedConfigIsCreatedWithMode0600() throws {
        let dir = try directory()
        let source = try write(protonConfig(), named: "VPN-RO1-RO-229.conf",
                               in: dir)
        let destination = file("wgmanaged.conf", in: dir)

        XCTAssertTrue(WireGuardProfiles.writeManagedConfig(from: source,
                                                           to: destination))
        XCTAssertEqual(try mode(of: destination), 0o600)

        // A previous run shipped 0644; the rewrite must tighten it.
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: destination)
        XCTAssertTrue(WireGuardProfiles.writeManagedConfig(from: source,
                                                           to: destination))
        XCTAssertEqual(try mode(of: destination), 0o600,
                       "an existing 0644 managed config stayed readable")
    }

    /// The rewrite returns false and writes nothing when the source cannot be
    /// read: a half-written config would be handed to wg-quick.
    func testMissingSourceWritesNothing() throws {
        let dir = try directory()
        let destination = file("wgmanaged.conf", in: dir)

        XCTAssertFalse(WireGuardProfiles.writeManagedConfig(
            from: file("absent.conf", in: dir), to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination))
    }

    /// The user's own file is the thing this layer exists to protect. It must
    /// come out of a rewrite byte-for-byte identical, key included.
    func testRewriteLeavesTheSourceFileUntouched() throws {
        let dir = try directory()
        let text = protonConfig()
        let source = try write(text, named: "VPN-RO1-RO-229.conf", in: dir)
        let before = try Data(contentsOf: URL(fileURLWithPath: source))

        XCTAssertTrue(WireGuardProfiles.writeManagedConfig(
            from: source, to: file("wgmanaged.conf", in: dir)))

        let after = try Data(contentsOf: URL(fileURLWithPath: source))
        XCTAssertEqual(before, after, "the user's profile was modified")
        XCTAssertEqual(try String(contentsOfFile: source, encoding: .utf8), text)
    }

    // MARK: - Path safety

    /// The picker only ever gets a name from `list()`, and `switchTo` resolves
    /// the name it is given back through that listing. So the safety property
    /// that matters is: a listed name never contains a path separator and never
    /// points outside the directory. That is what stops a crafted file from
    /// turning a server name into a write elsewhere.
    func testListedNamesNeverContainPathSeparators() throws {
        let dir = try directory()
        try write(protonConfig(), named: "VPN-RO1-RO-229.conf", in: dir)
        // A file *outside* the profile directory must not be reachable.
        try write(protonConfig(), named: "outside.conf", in: root)

        let profiles = WireGuardProfiles.list(directory: dir)
        XCTAssertEqual(profiles.count, 1)
        for profile in profiles {
            XCTAssertFalse(profile.name.contains("/"), profile.name)
            XCTAssertFalse(profile.name.contains("\\"), profile.name)
            XCTAssertFalse(profile.name.contains(".."), profile.name)
            XCTAssertEqual((profile.file as NSString).deletingLastPathComponent,
                           dir)
            XCTAssertFalse(profile.name.hasPrefix("."))
        }
    }

    /// Editor scratch files are not profiles. `contentsOfDirectory` returns
    /// dot-files, so a `.foo.conf.swp` would otherwise become a clickable row.
    ///
    /// Note: a dot-file that *is* a `.conf` (e.g. `.hidden.conf`) is still
    /// listed today, because only the extension is checked. That is a gap in
    /// the filter, not a rule this test defends; it is reported rather than
    /// asserted here.
    func testEditorScratchFilesAreNotListed() throws {
        let dir = try directory()
        try write(protonConfig(), named: "VPN-RO1-RO-229.conf", in: dir)
        try write(protonConfig(), named: ".VPN-RO1-RO-229.conf.swp", in: dir)
        try write(protonConfig(), named: "VPN-RO1-RO-229.conf~", in: dir)
        try write(protonConfig(), named: "VPN-RO1-RO-229.conf.tmp", in: dir)

        let names = WireGuardProfiles.list(directory: dir).map(\.name)
        XCTAssertEqual(names, ["VPN-RO1-RO-229"], "\(names)")
    }

    /// `list()` must be read-only: it is called on every UI refresh, so a write
    /// there would rewrite files the user owns just by opening a menu.
    func testListingDoesNotModifyTheDirectory() throws {
        let dir = try directory()
        try write(protonConfig(), named: "VPN-RO1-RO-229.conf", in: dir)
        let before = try snapshot(of: dir)

        _ = WireGuardProfiles.list(directory: dir)
        _ = WireGuardProfiles.list(directory: dir)

        XCTAssertEqual(try snapshot(of: dir), before)
    }

    // MARK: - Helpers

    /// Split a config into the lines belonging to each section, so an assertion
    /// can say "inside [Interface]" rather than "somewhere in the file".
    private func decomposed(_ text: String) -> (interface: [String], peer: [String]) {
        var interface: [String] = []
        var peer: [String] = []
        var section = ""
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") {
                section = line.lowercased()
                continue
            }
            switch section {
            case "[interface]": interface.append(line)
            case "[peer]": peer.append(line)
            default: continue
            }
        }
        return (interface.filter { !$0.isEmpty }, peer.filter { !$0.isEmpty })
    }

    private func mode(of path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        return permissions.intValue & 0o777
    }

    /// Name, size and mtime of every entry, so a stray write shows up.
    private func snapshot(of directory: String) throws -> [String] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory)
        return try names.sorted().map { name in
            let path = (directory as NSString).appendingPathComponent(name)
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let size = (attributes[.size] as? NSNumber)?.intValue ?? -1
            let modified = (attributes[.modificationDate] as? Date)?
                .timeIntervalSince1970 ?? -1
            return "\(name)|\(size)|\(modified)"
        }
    }
}
