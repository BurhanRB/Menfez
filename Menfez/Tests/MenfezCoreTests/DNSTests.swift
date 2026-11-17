import XCTest
@testable import MenfezCore

/// The resolver layer decides whether a blocked network works at all: if the
/// ISP answers Discord's names with a private address, the tunnel never gets a
/// chance. These tests pin what "poisoned" means, what the preset table
/// promises, and what the state file is allowed to do when it is damaged.
///
/// Nothing here asserts a live latency number and nothing writes to the real
/// /var/run/menfez or to the user's network service; the report test tolerates
/// whatever this machine's resolvers happen to be.
final class DNSTests: XCTestCase {

    // MARK: - Fixtures

    private var tempDir = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("menfez-dns-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: tempDir,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if !tempDir.isEmpty {
            try? FileManager.default.removeItem(atPath: tempDir)
        }
        tempDir = ""
        try super.tearDownWithError()
    }

    private func path(_ name: String) -> String {
        (tempDir as NSString).appendingPathComponent(name)
    }

    private func write(_ text: String, to name: String) throws {
        try text.write(toFile: path(name), atomically: true, encoding: .utf8)
    }

    // MARK: - Address classification

    /// A captive portal or a transparent interceptor answers a blocked name
    /// with an address on the local network. Those answers are the reason the
    /// picker exists, so every such range must be recognised.
    func testPrivateLoopbackAndLinkLocalAnswersArePoisoned() {
        let poisoned = [
            "10.0.0.1",          // 10/8
            "10.255.255.254",    // 10/8 upper end
            "172.16.0.1",        // 172.16/12 lower bound
            "172.31.255.254",    // 172.16/12 upper bound
            "192.168.1.1",       // 192.168/16
            "192.168.255.255",
            "127.0.0.1",         // loopback
            "127.255.255.254",
            "169.254.1.1",       // link-local, the self-assigned range
            "169.254.255.255",
            "0.0.0.0",           // unspecified, a blocking answer's favourite
        ]
        for address in poisoned {
            XCTAssertTrue(DNSManager.looksPoisoned([address]),
                          "\(address) must count as a poisoned answer")
        }
    }

    /// 224/4 is multicast and 240/4 is reserved. A resolver that answers with
    /// either is not answering the question that was asked.
    func testMulticastAndReservedAnswersArePoisoned() {
        for address in ["224.0.0.1", "239.255.255.250", "240.0.0.1",
                        "255.255.255.255"] {
            XCTAssertTrue(DNSManager.looksPoisoned([address]),
                          "\(address) must count as a poisoned answer")
        }
    }

    /// The 172.16/12 boundary is the one that is easy to get wrong: a mask of
    /// /12 covers 16..31 inclusive, so 172.15.x and 172.32.x are public.
    func testPrivateRangeBoundariesAreExact() {
        XCTAssertFalse(DNSManager.looksPoisoned(["172.15.255.255"]),
                       "172.15/16 is public and must stay untainted")
        XCTAssertTrue(DNSManager.looksPoisoned(["172.16.0.0"]),
                      "172.16.0.0 is the first address of the private /12")
        XCTAssertFalse(DNSManager.looksPoisoned(["172.32.1.1"]),
                       "172.32/16 is past the private /12")
        XCTAssertFalse(DNSManager.looksPoisoned(["192.167.1.1"]))
        XCTAssertFalse(DNSManager.looksPoisoned(["192.169.1.1"]))
        XCTAssertFalse(DNSManager.looksPoisoned(["11.0.0.1"]))
        XCTAssertFalse(DNSManager.looksPoisoned(["9.254.0.1"]))
    }

    /// An ISP that only speaks IPv6 must not be able to slip a private answer
    /// through, and `::ffff:192.168.1.5` is a private IPv4 address wearing an
    /// IPv6 mask — the exact form a resolver reaches for when it is faking.
    func testIPv4MappedIPv6IsJudgedByItsIPv4Part() {
        XCTAssertTrue(DNSManager.looksPoisoned(["::ffff:192.168.1.5"]))
        XCTAssertTrue(DNSManager.looksPoisoned(["::ffff:10.0.0.1"]))
        XCTAssertTrue(DNSManager.looksPoisoned(["::ffff:127.0.0.1"]))
        XCTAssertFalse(DNSManager.looksPoisoned(["::ffff:8.8.8.8"]),
                       "a mapped public address is still a public address")
    }

    /// The IPv6 equivalents: unspecified, loopback, link-local, multicast and
    /// unique-local. A blocked network that answers AAAA queries has to be
    /// caught too, or the client prefers the v6 answer and stalls.
    func testIPv6PrivateAndSpecialAnswersArePoisoned() {
        for address in ["::", "::1", "fe80::1", "fe80::abcd:1", "ff02::1",
                        "fc00::1", "fd12:3456::1"] {
            XCTAssertTrue(DNSManager.looksPoisoned([address]),
                          "\(address) must count as a poisoned answer")
        }
        XCTAssertFalse(DNSManager.looksPoisoned(["2606:4700:4700::1111"]))
        XCTAssertFalse(DNSManager.looksPoisoned(["2001:4860:4860::8888"]))
        XCTAssertFalse(DNSManager.looksPoisoned(["fec0::1"]),
                       "fec0::/10 is deprecated site-local, not link-local")
    }

    /// No answer at all is the same failure as a private answer: a resolver
    /// that will not answer example.com is not a resolver. Treating an empty
    /// list as clean would let a silently-blocking resolver win the ranking.
    func testEmptyAnswerListIsPoisoned() {
        XCTAssertTrue(DNSManager.looksPoisoned([]))
    }

    /// A single bad address taints the whole answer set, and text that is not
    /// an address at all is as suspicious as a private one.
    func testOneBadAddressTaintsTheWholeAnswerSet() {
        XCTAssertTrue(DNSManager.looksPoisoned(["1.1.1.1", "192.168.1.1"]))
        XCTAssertTrue(DNSManager.looksPoisoned(["10.0.0.1", "8.8.8.8"]))
        XCTAssertTrue(DNSManager.looksPoisoned(["not-an-address"]))
        XCTAssertTrue(DNSManager.looksPoisoned(["1.1.1.1", ""]),
                      "a blank line from dig is not an address")
    }

    func testOrdinaryPublicAnswersAreNotPoisoned() {
        for address in ["1.1.1.1", "8.8.8.8", "9.9.9.9", "94.140.14.14",
                        "208.67.222.222", "77.88.8.8", "162.159.128.1"] {
            XCTAssertFalse(DNSManager.looksPoisoned([address]),
                           "\(address) is a normal public answer")
        }
        XCTAssertFalse(DNSManager.looksPoisoned(["1.1.1.1", "1.0.0.1"]))
    }

    // MARK: - Preset table

    /// `resolve(target:)` looks presets up by id, so a duplicate id would make
    /// one row of the picker apply somebody else's servers.
    func testPresetIdsAreUnique() {
        let ids = DNSManager.presets.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate preset id in \(ids)")
        XCTAssertFalse(ids.contains(""))
    }

    /// Every preset must be presentable: an empty name renders as a blank row
    /// the user cannot identify.
    func testEveryPresetHasIdAndName() {
        for preset in DNSManager.presets {
            XCTAssertFalse(preset.name.isEmpty, "preset \(preset.id) has no name")
            XCTAssertFalse(preset.id.isEmpty)
        }
    }

    /// Exactly one automatic row, and it carries no addresses: an empty `v4`
    /// is what routes the row to `restoreAutomatic` instead of `set`.
    func testExactlyOneSystemPresetAndItHasNoAddresses() {
        let automatic = DNSManager.presets.filter { $0.v4.isEmpty }
        XCTAssertEqual(automatic.count, 1,
                       "only the automatic row may have an empty v4 list")
        XCTAssertEqual(automatic.first?.id, "system")
        XCTAssertFalse(automatic.first?.name.isEmpty ?? true)
        XCTAssertTrue(DNSManager.presets.contains { $0.id == "system" })
    }

    /// A single resolver is a single point of failure: if it is blocked or
    /// down the user has no DNS at all, so every real preset ships a pair.
    func testEveryRealPresetHasAtLeastTwoResolvers() {
        for preset in DNSManager.presets where preset.id != "system" {
            XCTAssertGreaterThanOrEqual(
                preset.v4.count, 2,
                "preset \(preset.id) has only one resolver: \(preset.v4)")
        }
    }

    /// Presets are what the app offers as the *fix*, so none of them may be an
    /// address that `looksPoisoned` would reject — that preset could never be
    /// reported as ok.
    func testNoPresetAddressIsItselfPoisoned() {
        for preset in DNSManager.presets {
            for address in preset.v4 {
                XCTAssertFalse(DNSManager.looksPoisoned([address]),
                               "\(preset.id) offers \(address), which is poisoned")
                XCTAssertTrue(isDottedIPv4(address),
                              "\(preset.id) offers \(address), which is not IPv4")
            }
        }
    }

    // MARK: - Report shape

    /// One `report()` is expensive (it probes every resolver live), and the
    /// shape assertions below all describe the same snapshot.
    private static let sharedReport = DNSManager().report()

    /// Only one row may claim to be in effect. Two highlighted rows would make
    /// the picker lie about what the machine is actually using.
    func testReportMarksAtMostOnePresetActive() {
        let active = Self.sharedReport.presets.filter(\.active)
        XCTAssertLessThanOrEqual(active.count, 1,
                                 "more than one preset claims to be active")
    }

    /// `active` is an exact match, not a subset: a resolver list of
    /// 1.1.1.1+1.0.0.1+9.9.9.9 is not Cloudflare, and showing Cloudflare as
    /// selected would hide the third server from the user.
    func testActivePresetMatchesTheLiveResolverListExactly() {
        let report = Self.sharedReport
        for preset in report.presets {
            let expected = !report.current.isEmpty
                && !preset.v4.isEmpty
                && preset.v4 == report.current
            XCTAssertEqual(preset.active, expected,
                           "\(preset.id) active=\(preset.active) but live "
                           + "resolvers are \(report.current) and its own are \(preset.v4)")
        }
        for preset in report.presets where preset.active {
            XCTAssertEqual(preset.v4, report.current,
                           "an active preset must be the live resolver list")
        }
    }

    /// A list that merely contains a preset's servers must not light that
    /// preset up. This is the subset half of the rule above, stated on its own
    /// so a future "contains" shortcut fails with a clear message.
    func testAPresetIsNeverActiveAsASubsetOfTheLiveList() {
        let report = Self.sharedReport
        guard !report.current.isEmpty else { return }
        for preset in report.presets where !preset.v4.isEmpty {
            let isStrictSubset = preset.v4.count < report.current.count
                && Set(preset.v4).isSubset(of: Set(report.current))
            if isStrictSubset {
                XCTAssertFalse(preset.active,
                               "\(preset.id) is only a subset of \(report.current)")
            }
        }
    }

    /// The ranking sort must not lose or duplicate a row: the picker has to
    /// offer every preset exactly once whatever the latencies were.
    func testReportKeepsEveryPresetExactlyOnce() {
        let report = Self.sharedReport
        XCTAssertEqual(report.presets.count, DNSManager.presets.count)
        XCTAssertEqual(Set(report.presets.map(\.id)).count,
                       DNSManager.presets.count)
        XCTAssertEqual(Set(report.presets.map(\.id)),
                       Set(DNSManager.presets.map(\.id)))
    }

    /// Every preset carries its own v4 list through the ranking unchanged; the
    /// sort reorders rows, it never rewrites what a row would apply.
    func testRerankingDoesNotRewritePresetAddresses() {
        let expected = Dictionary(uniqueKeysWithValues:
                                    DNSManager.presets.map { ($0.id, $0.v4) })
        for preset in Self.sharedReport.presets {
            XCTAssertEqual(preset.v4, expected[preset.id])
        }
    }

    /// A probe that failed yields nil, never 0. A fabricated "0 ms" would put
    /// an unreachable resolver at the top of the list.
    func testReportNeverReportsZeroLatency() {
        for preset in Self.sharedReport.presets {
            XCTAssertNotEqual(preset.ms, 0,
                              "\(preset.id) reports 0 ms, which is not a measurement")
            if let ms = preset.ms {
                XCTAssertGreaterThan(ms, 0)
            }
        }
    }

    /// Unreachable resolvers sort last, and the reachable ones ascend. Both are
    /// user-visible promises of the picker.
    func testReportSortsUnreachableLastThenFastestFirst() {
        var sawMissing = false
        var previous: Int?
        for preset in Self.sharedReport.presets {
            if preset.ms == nil {
                sawMissing = true
                continue
            }
            XCTAssertFalse(sawMissing,
                           "\(preset.id) has a latency but sorts after a failed probe")
            if let previous, let ms = preset.ms {
                XCTAssertLessThanOrEqual(previous, ms,
                                         "latencies are not in ascending order")
            }
            previous = preset.ms
        }
    }

    /// When the service cannot be resolved there is no live list, and an empty
    /// list must not read as "Automatic is selected".
    func testNoServiceMeansNoCurrentResolversAndNoActiveRow() {
        let report = Self.sharedReport
        if report.service == nil {
            XCTAssertTrue(report.current.isEmpty)
            XCTAssertFalse(report.presets.contains(where: \.active))
        } else {
            XCTAssertFalse(report.service?.isEmpty ?? true)
        }
    }

    // MARK: - Latency semantics

    /// TEST-NET-1 (192.0.2.0/24) is reserved for documentation and is never
    /// routed, so this resolver cannot answer. The answer must be "no
    /// measurement" rather than a number.
    func testUnreachableResolverYieldsNilLatencyNotZero() {
        XCTAssertNil(DNSManager.latency(server: "192.0.2.99"))
        XCTAssertNil(Probes.dnsLatency(server: "192.0.2.99"))
    }

    /// An empty server name is not a resolver; probing it must be refused
    /// before a process is started, not turned into a measurement.
    func testEmptyServerNameHasNoLatency() {
        XCTAssertNil(DNSManager.latency(server: ""))
        XCTAssertNil(Probes.dnsLatency(server: ""))
        XCTAssertTrue(DNSManager.answers(server: "").isEmpty)
    }

    // MARK: - Target parsing

    /// `apply` accepts a preset id or literal addresses. A preset id must win
    /// over the literal parser, or "google" would not apply anything.
    func testResolvePrefersPresetIds() throws {
        let google = try XCTUnwrap(DNSManager.presets.first { $0.id == "google" })
        XCTAssertEqual(DNSManager.resolve(target: "google"), google.v4)
        XCTAssertEqual(DNSManager.resolve(target: "system"), [])
    }

    /// Literal addresses arrive from the CLI with commas or spaces, and the
    /// filter exists to keep shell metacharacters and prose out of the command
    /// that networksetup will run.
    func testResolveAcceptsCommaAndSpaceSeparatedAddresses() {
        XCTAssertEqual(DNSManager.resolve(target: "1.1.1.1,8.8.8.8"),
                       ["1.1.1.1", "8.8.8.8"])
        XCTAssertEqual(DNSManager.resolve(target: "1.1.1.1 8.8.8.8"),
                       ["1.1.1.1", "8.8.8.8"])
        XCTAssertEqual(DNSManager.resolve(target: "  9.9.9.9 , 149.112.112.112 "),
                       ["9.9.9.9", "149.112.112.112"])
    }

    func testResolveDropsAnythingThatIsNotAddressLike() {
        XCTAssertTrue(DNSManager.resolve(target: "").isEmpty)
        XCTAssertTrue(DNSManager.resolve(target: "$(rm -rf /)").isEmpty)
        XCTAssertTrue(DNSManager.resolve(target: "1.1.1.1;reboot").isEmpty)
        XCTAssertTrue(DNSManager.resolve(target: "1.1.1.1|reboot").isEmpty)
        XCTAssertTrue(DNSManager.resolve(target: "1.1.1.1&reboot").isEmpty)
        // A token is dropped individually: when one of them is a real address
        // it is still applied, and the operator word is not.
        XCTAssertEqual(DNSManager.resolve(target: "1.1.1.1 && reboot"),
                       ["1.1.1.1"])
        // Hex letters and dots are address characters, so a stray word like
        // "cafe" or "notes.txt" survives the filter; the kernel is the
        // authority on whether it is a valid address. That is the documented
        // trade-off of this regex, not an oversight: what matters is that
        // shell metacharacters never reach the networksetup argument list.
        XCTAssertEqual(DNSManager.resolve(target: "abcd::1"), ["abcd::1"])
        XCTAssertEqual(DNSManager.resolve(target: "1.1.1.1"), ["1.1.1.1"])
    }

    // MARK: - State file

    /// A missing file means "we never changed anything". Inventing a saved
    /// value would make the next restore write a resolver nobody chose.
    func testMissingStateFileLoadsAsEmpty() {
        let state = DNSStateStore.load(path: path("absent.json"))
        XCTAssertTrue(state.previous.isEmpty)
        XCTAssertTrue(state.applied.isEmpty)
    }

    /// A truncated or garbled file is the same situation as a missing one, and
    /// loading it must not rewrite it: the user's last known original is not
    /// ours to discard while we are only reading.
    func testCorruptStateFileLoadsAsEmptyAndIsLeftAlone() throws {
        let cases = ["", "{", "not json at all", "{\"previous\":\"wrong shape\"}",
                     "{\"previous\":{\"Wi-Fi\":[\"1.1.1.1\"]}"]
        for (index, text) in cases.enumerated() {
            let name = "corrupt-\(index).json"
            try write(text, to: name)

            let state = DNSStateStore.load(path: path(name))
            XCTAssertTrue(state.previous.isEmpty,
                          "\(name) yielded a previous value it could not have read")
            XCTAssertTrue(state.applied.isEmpty)

            let after = try String(contentsOfFile: path(name), encoding: .utf8)
            XCTAssertEqual(after, text,
                           "\(name) was rewritten by a read-only load")
        }
    }

    /// The decoder is deliberately loose so a file with one field still yields
    /// the other instead of being thrown away wholesale.
    func testStateFileWithOneFieldKeepsTheOther() throws {
        try write("{\"applied\":[\"1.1.1.1\",\"1.0.0.1\"]}", to: "partial.json")
        let appliedOnly = DNSStateStore.load(path: path("partial.json"))
        XCTAssertEqual(appliedOnly.applied, ["1.1.1.1", "1.0.0.1"])
        XCTAssertTrue(appliedOnly.previous.isEmpty)

        try write("{\"previous\":{\"Wi-Fi\":[]}}", to: "previous.json")
        let previousOnly = DNSStateStore.load(path: path("previous.json"))
        XCTAssertEqual(previousOnly.previous["Wi-Fi"], [])
        XCTAssertTrue(previousOnly.applied.isEmpty)
    }

    /// The saved original must survive a write/read cycle exactly, including
    /// the empty list that means "DHCP".
    func testSaveRoundTripsTheSavedOriginal() {
        let state = DNSState(previous: ["Wi-Fi": [], "USB 10/100/1000 LAN": ["192.168.1.1"]],
                             applied: ["1.1.1.1", "1.0.0.1"])
        let file = path("written.json")
        XCTAssertTrue(DNSStateStore.save(state, path: file))

        let loaded = DNSStateStore.load(path: file)
        XCTAssertEqual(loaded.previous["Wi-Fi"], [])
        XCTAssertEqual(loaded.previous["USB 10/100/1000 LAN"], ["192.168.1.1"])
        XCTAssertEqual(loaded.applied, ["1.1.1.1", "1.0.0.1"])
    }

    /// The state file is read by a non-root UI, so it must be written but not
    /// be group- or world-writable.
    func testSavedStateFileIsNotGroupOrWorldWritable() throws {
        let file = path("perms.json")
        XCTAssertTrue(DNSStateStore.save(DNSState(previous: ["Wi-Fi": ["1.1.1.1"]]),
                                         path: file))
        let attributes = try FileManager.default.attributesOfItem(atPath: file)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o022, 0,
                       "state file is writable by group or others")
    }

    /// Saving somewhere impossible is a false, not a crash: the caller decides
    /// whether that matters.
    func testSaveToAnImpossiblePathReturnsFalse() {
        XCTAssertFalse(DNSStateStore.save(DNSState(), path: "/dev/null/nope.json"))
    }

    // MARK: - apply / restoreAutomatic through the seams

    /// A fake machine: resolvers per service, and a log of writes.
    private final class FakeNet {
        var servers: [String: [String]] = [:]
        var active: String? = "Wi-Fi"
        var readFails = false
        var refuse: Set<String> = []
        var writes: [(String, [String])] = []
        var exists: Set<String>? = nil   // nil: every service exists
    }

    private func manager(_ net: FakeNet, state: String? = nil, legacy: String? = nil) -> DNSManager {
        var m = DNSManager()
        m.statePath = state ?? path("support/dns-state.json")
        m.legacyStatePath = legacy
        m.findService = { net.active }
        m.readServers = { net.readFails ? nil : (net.servers[$0] ?? []) }
        m.writeServers = { service, list in
            net.writes.append((service, list))
            guard !net.refuse.contains(service) else { return false }
            net.servers[service] = list
            return true
        }
        m.listServices = { net.exists.map(Array.init) ?? Array(net.servers.keys) }
        return m
    }

    /// `restoreAutomatic` puts the machine back from a missing file (no-op to
    /// DHCP) and from a corrupt one (DHCP, damaged file left untouched).
    func testRestoreAutomaticSurvivesAMissingOrCorruptStateFile() throws {
        let net = FakeNet()
        net.servers["Wi-Fi"] = ["8.8.8.8"]
        XCTAssertTrue(manager(net).restoreAutomatic().ok)
        XCTAssertEqual(net.servers["Wi-Fi"], [])

        try write("{", to: "corrupt.json")
        net.servers["Wi-Fi"] = ["8.8.8.8"]
        let result = manager(net, state: path("corrupt.json")).restoreAutomatic()
        XCTAssertTrue(result.ok)
        XCTAssertFalse(result.notes.isEmpty)
        XCTAssertEqual(net.servers["Wi-Fi"], [])
        XCTAssertEqual(try String(contentsOfFile: path("corrupt.json"), encoding: .utf8), "{")
    }

    /// `apply` records only the first observation of the original resolver.
    func testApplyDoesNotOverwriteTheFirstObservation() {
        let net = FakeNet()
        net.servers["Wi-Fi"] = ["192.168.1.1"]
        let m = manager(net)
        XCTAssertTrue(m.apply(target: "cloudflare").ok)
        XCTAssertTrue(m.apply(target: "google").ok)
        let saved = DNSStateStore.load(path: m.statePath)
        XCTAssertEqual(saved.previous["Wi-Fi"], ["192.168.1.1"])
        XCTAssertEqual(saved.applied, ["8.8.8.8", "8.8.4.4"])
        XCTAssertTrue(m.restoreAutomatic().ok)
        XCTAssertEqual(net.servers["Wi-Fi"], ["192.168.1.1"])
    }

    /// (a) A corrupt state file is never overwritten by `apply`.
    func testApplyRefusesOverACorruptStateFile() throws {
        try write("not json", to: "corrupt.json")
        let net = FakeNet()
        let result = manager(net, state: path("corrupt.json")).apply(target: "cloudflare")
        XCTAssertFalse(result.ok)
        XCTAssertTrue(net.writes.isEmpty)
        XCTAssertEqual(try String(contentsOfFile: path("corrupt.json"), encoding: .utf8), "not json")
    }

    /// (b) A failed set must not record `applied`.
    func testFailedSetDoesNotRecordApplied() {
        let net = FakeNet()
        net.refuse = ["Wi-Fi"]
        let m = manager(net)
        XCTAssertFalse(m.apply(target: "cloudflare").ok)
        XCTAssertEqual(DNSStateStore.load(path: m.statePath).applied, [])
    }

    /// (c) Every service recorded is restored, not only the active one.
    func testRestoreCoversEveryRecordedService() {
        let net = FakeNet()
        net.servers = ["Wi-Fi": ["10.0.0.1"], "Ethernet": []]
        let m = manager(net)
        XCTAssertTrue(m.apply(target: "cloudflare").ok)
        net.active = "Ethernet"
        XCTAssertTrue(m.apply(target: "quad9").ok)
        XCTAssertTrue(m.restoreAutomatic().ok)
        XCTAssertEqual(net.servers["Wi-Fi"], ["10.0.0.1"])
        XCTAssertEqual(net.servers["Ethernet"], [])
        XCTAssertTrue(DNSStateStore.load(path: m.statePath).previous.isEmpty)
    }

    /// A service that refuses the restore stays recorded for the next attempt.
    func testRefusedRestoreKeepsThatServiceRecorded() {
        let net = FakeNet()
        net.servers = ["Wi-Fi": ["10.0.0.1"]]
        let m = manager(net)
        XCTAssertTrue(m.apply(target: "cloudflare").ok)
        net.refuse = ["Wi-Fi"]
        XCTAssertFalse(m.restoreAutomatic().ok)
        XCTAssertEqual(DNSStateStore.load(path: m.statePath).previous["Wi-Fi"], ["10.0.0.1"])
    }

    /// A recorded service that no longer exists is dropped with a note, not
    /// reported as a failure; one that exists but refuses still fails.
    func testRestoreDropsAVanishedServiceButKeepsARefusingOne() {
        let net = FakeNet()
        net.servers = ["Wi-Fi": ["10.0.0.1"], "USB LAN": ["192.168.1.1"]]
        let m = manager(net)
        XCTAssertTrue(m.apply(target: "cloudflare").ok)
        net.active = "USB LAN"
        XCTAssertTrue(m.apply(target: "cloudflare").ok)

        net.refuse = ["USB LAN"]
        net.exists = ["Wi-Fi"]
        let gone = m.restoreAutomatic()
        XCTAssertTrue(gone.ok)
        XCTAssertTrue(gone.notes.contains { $0.contains("USB LAN") })
        XCTAssertTrue(DNSStateStore.load(path: m.statePath).previous.isEmpty)

        net.refuse = []
        XCTAssertTrue(m.apply(target: "cloudflare").ok)  // active is still "USB LAN"
        net.refuse = ["USB LAN"]
        net.exists = ["USB LAN"]
        XCTAssertFalse(m.restoreAutomatic().ok)
        XCTAssertNotNil(DNSStateStore.load(path: m.statePath).previous["USB LAN"])
    }

    /// (d) A failed read is not recorded as "automatic".
    func testUnreadableCurrentResolverRefusesApply() {
        let net = FakeNet()
        net.readFails = true
        let m = manager(net)
        XCTAssertFalse(m.apply(target: "cloudflare").ok)
        XCTAssertTrue(net.writes.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: m.statePath))
    }

    func testCurrentCheckedTellsErrorFromAutomatic() {
        struct Canned: CommandRunner {
            let result: CommandResult
            func run(_ tool: String, _ args: [String], timeout: TimeInterval) -> CommandResult { result }
        }
        func read(_ status: Int32, _ text: String) -> [String]? {
            DNSManager.currentChecked(service: "Wi-Fi",
                                      using: Canned(result: CommandResult(status: status, output: text)))
        }
        XCTAssertEqual(read(0, "There aren't any DNS Servers set on Wi-Fi.\n"), [])
        XCTAssertEqual(read(0, "1.1.1.1\n1.0.0.1\n"), ["1.1.1.1", "1.0.0.1"])
        XCTAssertNil(read(0, "** Error: The parameters were not valid.\n"))
        XCTAssertNil(read(1, ""))
    }

    func testAllServicesSkipsTheLegendAndKeepsDisabledOnes() {
        struct Canned: CommandRunner {
            let result: CommandResult
            func run(_ tool: String, _ args: [String], timeout: TimeInterval) -> CommandResult { result }
        }
        let text = "An asterisk (*) denotes that a network service is disabled.\nWi-Fi\n*USB LAN\n"
        XCTAssertEqual(DNSManager.allServices(using: Canned(result: CommandResult(status: 0, output: text))),
                       ["Wi-Fi", "USB LAN"])
        XCTAssertNil(DNSManager.allServices(using: Canned(result: CommandResult(status: 1, output: ""))))
    }

    /// (e) A record left by an older release in /var/run is read, then moved.
    func testLegacyStateIsMigrated() throws {
        let legacy = path("legacy-dns-state.json")
        XCTAssertTrue(DNSStateStore.save(DNSState(previous: ["Wi-Fi": ["10.0.0.1"]]), path: legacy))
        let net = FakeNet()
        net.servers["Wi-Fi"] = ["1.1.1.1"]
        let m = manager(net, legacy: legacy)
        XCTAssertTrue(m.apply(target: "google").ok)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy))
        XCTAssertEqual(DNSStateStore.load(path: m.statePath).previous["Wi-Fi"], ["10.0.0.1"])
        var st = stat()
        XCTAssertEqual(lstat((m.statePath as NSString).deletingLastPathComponent, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o700)
    }

    // MARK: - Helpers

    /// IPv4 dotted quad, used to keep the preset claims honest.
    private func isDottedIPv4(_ text: String) -> Bool {
        let groups = text.split(separator: ".", omittingEmptySubsequences: false)
        guard groups.count == 4 else { return false }
        return groups.allSatisfy { group in
            !group.isEmpty && group.count <= 3 && group.allSatisfy(\.isNumber)
        }
    }
}
