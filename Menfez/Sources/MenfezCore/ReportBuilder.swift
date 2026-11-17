// ReportBuilder.swift — assemble one Report, and the popup details that go
// with it.
//
// This is the Swift replacement for cmd_report and cmd_detail in
// menfez-route.py. The Python ran as root and shelled out to wg, route and
// networksetup directly; here the mutating layer (RouteManager, DNSManager,
// RouteStateStore) owns those calls and this file only asks it questions. The
// probes it does own are the read-only ones in Probes.swift.
//
// WHY `full` EXISTS
// A report without the network probes costs a handful of local commands and
// finishes in well under 100 ms, which is what the UI's 2-second refresh
// wants. egressIP and geo need two HTTPS round trips each (~300 ms on a good
// mobile link, seconds on a captive portal) and the Discord probe needs a
// third, so those three are only fetched when the user opens the sheet that
// shows them. A refresh loop that hammered ipify every two seconds would also
// start being rate limited, which would quietly turn a working egress row
// into a permanent dash.
//
// WHY EVERYTHING DEGRADES
// Each probe can fail independently: no tunnel, no network, a resolver that
// times out, ipinfo down. None of those is an error for the report as a whole
// — the UI can show a partly filled card, which is more useful than an error
// page. `error` is reserved for a structural inconsistency the user has to
// act on, such as a state file that claims a mode while no tunnel exists.

import Foundation

public struct ReportBuilder {

    /// How much of the report the caller is allowed to see.
    ///
    /// This used to be a `full: Bool`, which conflated two independent
    /// questions: "may I make outbound HTTPS probes" and "may I ask the
    /// privileged helper for the tunnel facts". The app's 5-second refresh
    /// answered yes to the second one forever, which is the reason a root
    /// process was spawned every 5 seconds. They are separate now.
    public enum Depth {
        /// Local commands only, nothing privileged, no network. This is what a
        /// window that is merely visible needs: every field it fills comes from
        /// a command that works as the user (`route`, `networksetup`,
        /// `ifconfig`, `ipconfig`), and the privileged fields stay nil.
        case local
        /// `local`, plus the outbound HTTPS probes (egress address, geo,
        /// Discord reachability).
        case probed
    }

    public init() {}

    /// Build the report the UI renders, using commands every user can run.
    ///
    /// The privileged fields — handshake age, byte counters, peer key, and the
    /// tunnel's endpoint — are left nil *on purpose*. They are not zero and not
    /// guessed: the app fills them in from a `TunnelFacts` snapshot it already
    /// holds, and a field nobody could measure renders as a dash. See
    /// `TunnelFacts` for why these five are the only ones on the list.
    /// - Parameter statePath: where to read the recorded route set from.
    ///   Injectable for the same reason `RouteManager.statePath` is: a test
    ///   must not be able to see or change the real /var/run/menfez file, and
    ///   two tests running in parallel must not share one.
    /// - Parameter dnsCache: when given, the service name and resolvers are
    ///   read from it while it is valid, saving two `networksetup` per tick.
    public func buildLocal(depth: Depth = .local,
                           statePath: String = Path.routeState,
                           dnsCache: DNSInfoCache? = nil,
                           using runner: CommandRunner = SystemRunner()) -> Report {
        var report = Report()

        // `wg show interfaces` needs no root on this platform: it reads
        // /var/run/wireguard, which is 0755. An enumerating failure is "we do
        // not know", not "no tunnel", so it is distinguished here and reported
        // as an unknown health rather than a confident down.
        let list = RouteManager.interfaceList(using: runner)
        let tunnel = list?.first

        report.tunnel = tunnel
        if let tunnel {
            // An interface the kernel still knows, but whose handshake we cannot
            // read. `unknown` is the honest code and the UI says "checking";
            // calling it noHandshake would claim a measurement we did not take.
            let exists = RouteManager.interfaceExists(tunnel, using: runner)
            report.health = exists
                ? Health(ok: false, code: .unknown)
                : Health(ok: false, code: .gone)
        } else {
            report.health = list == nil
                ? Health(ok: false, code: .unknown)
                : Health.down
        }

        let state = RouteStateStore.load(path: statePath)
        report.mode = state.mode
        report.hosts = state.hosts
        report.profile = state.profile

        // A recorded CIDR that is not in the table is the interesting case: the
        // app thinks it routed traffic and the kernel disagrees.
        //
        // `route -n get` is a normal read, and `not in table` is a successful
        // exit with that text, so `routeExists` already decides presence from
        // the output rather than the status.
        // One `netstat -rn` for every prefix; an unreadable table reads as
        // "not present", as a failed `route get` did.
        let table = state.routes.isEmpty ? [] : (RouteManager.routeTable(using: runner) ?? [])
        report.routes = state.routes.map { cidr in
            RouteInfo(cidr: cidr,
                      present: RouteManager.routeExists(cidr, iface: tunnel, in: table))
        }

        // One `route -n get default` for both values.
        //
        // This used to be three separate calls per report: `primaryInterface()`,
        // `physicalGateway()` and again inside `DNSManager.activeService()`.
        // Each was a process, and on the fast path a process is the thing we are
        // trying not to start. The default route does not change between two
        // reads microseconds apart, so reading it once is strictly better.
        let defaultRoute = RouteManager.routeGetValues(["default"], using: runner)
        let primary = defaultRoute["interface"].flatMap { $0.isEmpty ? nil : $0 }
        let liveGateway = defaultRoute["gateway"].flatMap { gateway -> String? in
            guard !gateway.isEmpty, Validate.ipAddress(gateway) != nil else { return nil }
            return gateway
        }

        report.interface = primary
        if let primary {
            let result = runner.run("ipconfig", ["getifaddr", primary], timeout: 5)
            let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.ok, !text.isEmpty { report.localIP = text }
        }

        // Prefer the live gateway reading and fall back to the one recorded
        // when the routes were applied, because that is the value the endpoint
        // pin still points at even if the default route has since moved.
        report.gateway = liveGateway ?? state.gateway

        // The service name is what `networksetup` speaks; it is derived from the
        // same interface, so it is passed in rather than looked up again.
        let dnsInfo = dnsCache?.lookup(interface: primary) ?? {
            let service = DNSManager.activeService(interface: primary, using: runner)
            let info = DNSInfoCache.Info(
                service: service,
                servers: service.map { DNSManager.current(service: $0, using: runner) } ?? [])
            dnsCache?.store(info, interface: primary)
            return info
        }()
        report.dnsService = dnsInfo.service
        report.dns = dnsInfo.servers

        if depth == .probed {
            let probed = Self.probes(using: runner)
            report.egressIP = probed.egressIP
            report.geo = probed.geo
            report.discord = probed.discord
        }

        // Structural problems only. A probe that failed is already visible as a
        // dash, and repeating it as an error banner would train the user to
        // ignore the banner. `unknown` health means we could not look, so the
        // "no tunnel" sentence would be a claim we cannot support.
        if state.mode != "off", tunnel == nil, list != nil {
            report.error = "mode is \(state.mode) but no tunnel is up"
        }

        report.ts = Int(Date().timeIntervalSince1970)
        return report
    }

    /// The three network-backed rows: egress address, its geo, Discord.
    public struct ProbeResult: Equatable, Sendable {
        public var egressIP: String?
        public var geo: Geo?
        public var discord: DiscordProbe

        public init(egressIP: String? = nil, geo: Geo? = nil,
                    discord: DiscordProbe = DiscordProbe()) {
            self.egressIP = egressIP
            self.geo = geo
            self.discord = discord
        }
    }

    /// Run the outbound probes, the two independent chains in parallel.
    ///
    /// ipify -> ipinfo is one chain (geo needs the address), Discord is the
    /// other. Run one after the other, a blocked Discord name (8 s) used to
    /// hold the IP row back for the whole run.
    /// - Parameter discordProxyPort: the DPI proxy's port while Discord goes
    ///   through it; the Discord request then takes the same path.
    public static func probes(discordProxyPort: Int? = nil,
                              using runner: CommandRunner = SystemRunner()) -> ProbeResult {
        let lock = NSLock()
        var result = ProbeResult()
        DispatchQueue.concurrentPerform(iterations: 2) { lane in
            if lane == 0 {
                let ip = Probes.publicIP(using: runner)
                let geo = ip.flatMap { Probes.geo(ip: $0, using: runner) }
                lock.lock(); result.egressIP = ip; result.geo = geo; lock.unlock()
            } else {
                let discord = Probes.discord(proxyPort: discordProxyPort, using: runner)
                lock.lock(); result.discord = discord; lock.unlock()
            }
        }
        return result
    }

    /// Build the report with everything filled in.
    ///
    /// Kept for the CLI (`menfez-route report`), which runs as root and is the
    /// only caller that may read the tunnel facts and the live endpoint. The
    /// app no longer calls it on a timer; it calls `buildLocal` and merges a
    /// `TunnelFacts` snapshot instead.
    ///
    /// - Parameter full: also run the HTTPS probes (egress address, its geo,
    ///   and the Discord reachability check). False keeps the whole build
    ///   local.
    public func build(full: Bool) -> Report {
        build(full: full, using: SystemRunner())
    }

    public func build(full: Bool,
                      statePath: String = Path.routeState,
                      using runner: CommandRunner) -> Report {
        var report = buildLocal(depth: full ? .probed : .local,
                                statePath: statePath,
                                using: runner)
        let tunnel = RouteManager.interfaceList(using: runner)?.first

        // Tunnel facts. When there is no interface at all, `health` says down
        // and the rest stays nil — the same shape the Python emitted, so the
        // UI does not need a second code path for "no tunnel". This is the one
        // place in the whole program that reads `wg show <iface>` outside a
        // mutation, and it only runs as root.
        if let tunnel {
            let facts = RouteManager.facts(iface: tunnel, using: runner)
            report.health = RouteManager.health(iface: tunnel,
                                               exists: true,
                                               handshakeEpoch: facts.handshakeEpoch)
            report.endpoint = facts.endpoint
            report.peerPubkey = facts.peerPubkey
            report.handshakeEpoch = facts.handshakeEpoch
            report.handshakeAgeS = facts.handshakeEpoch.map {
                max(0, Int(Date().timeIntervalSince1970) - $0)
            }
            report.transfer = facts.transfer
        } else {
            // Deliberately NOT `.unknown` here. This function is what the
            // helper puts on the wire, and `health` is non-optional in the
            // JSON: an older app decodes `Report` whole, so one unrecognised
            // code makes it fail to decode the entire payload. `.down` is what
            // every previous helper version emitted in this situation, and
            // "cannot enumerate" has always degraded to "nothing to show".
            report.health = Health.down
        }

        return report
    }
}

// MARK: - Detail popups

/// The extra rows behind one click, mirroring cmd_detail.
///
/// Each kind is cheap enough to run on click: local commands plus at most one
/// HTTPS call, and the DNS one is three dig queries per resolver. Nothing here
/// is cached, because the whole point of the popup is to show the state right
/// now.
public enum Details {

    /// Build the popup for one row.
    ///
    /// - Parameters:
    ///   - what: "ip", "routes", "dns", "tunnel" or "discord".
    ///   - value: for "ip", the address to describe. Everything else ignores
    ///     it, as the Python did.
    public static func build(what: String, value: String? = nil) -> DetailResponse {
        build(what: what, value: value, using: SystemRunner())
    }

    /// The same popups, with the process launcher injected.
    ///
    /// Only useful for measurement and for the app's own call path; every popup
    /// is already a user-initiated action, so making one privileged call is
    /// fine and is what the click has always done.
    public static func build(what: String, value: String? = nil,
                             using runner: CommandRunner) -> DetailResponse {
        switch what {
        case "ip":
            return ipDetail(value, using: runner)
        case "routes":
            return routesDetail(using: runner)
        case "dns":
            return dnsDetail(using: runner)
        case "tunnel":
            return tunnelDetail(using: runner)
        case "discord":
            return discordDetail(using: runner)
        default:
            return DetailResponse(what: what, error: "unknown detail \(what)")
        }
    }

    // MARK: ip

    private static func ipDetail(_ value: String?,
                                 using runner: CommandRunner) -> DetailResponse {
        // `value` is what the row already showed, so the user never sees a
        // different address in the popup than in the row. Only a row without
        // an address falls back to a fresh lookup.
        //
        // The value reaches `host` and a curl URL, as root when it comes
        // through the helper, so only a parsed address is passed on: "-x" or
        // "1.1.1.1/../x" would otherwise be a flag or a different URL.
        if let value, !value.isEmpty, Validate.ipAddress(value) == nil {
            return DetailResponse(what: "ip", error: "not an IP address")
        }
        let address = (value?.isEmpty == false ? value : nil)
            ?? Probes.publicIP(using: runner)
        guard let ip = address.flatMap({ Validate.ipAddress($0) }) else {
            return DetailResponse(what: "ip", error: "no address")
        }

        var items = [DetailItem(label: "IP", value: ip)]

        // 8 s: a PTR that nobody answers times out on its own, and the popup
        // must not hold the sheet open while it does.
        let reverse = runner.run("host", [ip], timeout: 8)
        if reverse.ok, let ptr = reversePointer(reverse.output) {
            items.append(DetailItem(label: "Reverse DNS", value: ptr))
        }

        // ipinfo's own deadline is 6 s and the outer budget 9 s, so curl
        // reports its timeout instead of being killed by us. The address is
        // looked up even when `value` came from the row, because the popup is
        // where the user asked for the details.
        let geoCall = runner.run("curl",
                                 ["-sS", "--max-time", "6",
                                  "https://ipinfo.io/\(ip)/json"],
                                 timeout: 9)
        if geoCall.ok, let object = Probes.jsonObject(geoCall.output) {
            // Same key order and labels as the Python popup.
            let fields: [(String, String)] = [
                ("city", "City"),
                ("region", "Region"),
                ("country", "Country"),
                ("postal", "Postal"),
                ("timezone", "Timezone"),
                ("loc", "Coordinates"),
                ("org", "Network"),
            ]
            for (key, label) in fields {
                if let text = Probes.stringValue(object[key]) {
                    items.append(DetailItem(label: label, value: text))
                }
            }
            // "—" when the org string produced no brand: an em dash is
            // honest, an empty value makes the row look broken.
            let org = Probes.stringValue(object["org"])
            items.append(DetailItem(label: "Provider",
                                    value: ShortISP.short(org) ?? "—"))
        }

        // Outside the geo block on purpose: the route lookup is local and
        // works offline, and it is the row that explains a black hole.
        items.append(DetailItem(label: "Routing",
                                value: Probes.routeSummary(ip: ip, using: runner)))
        return DetailResponse(what: "ip", items: items)
    }

    /// The name in `host`'s PTR line, without the trailing root dot.
    private static func reversePointer(_ output: String) -> String? {
        for line in output.split(separator: "\n") {
            guard line.contains("domain name pointer") else { continue }
            // "x.y.z.in-addr.arpa domain name pointer host.example.com."
            guard let range = line.range(of: "pointer") else { continue }
            let name = line[range.upperBound...]
                .trimmingCharacters(in: .whitespaces)
            var trimmed = name
            while trimmed.hasSuffix(".") { trimmed.removeLast() }
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    // MARK: routes

    private static func routesDetail(using runner: CommandRunner) -> DetailResponse {
        let state = RouteStateStore.load()
        let iface = RouteManager.interfaceList(using: runner)?.first

        var items: [DetailItem] = []
        for cidr in state.routes {
            let present = iface.map {
                RouteManager.routeExists(cidr, iface: $0, using: runner)
            } ?? false
            items.append(DetailItem(label: cidr,
                                    value: present ? "active" : "missing"))
        }
        // The host pins are not routes we added for traffic; they exist so the
        // encrypted transport itself cannot fall into the tunnel. The gateway is
        // probed rather than assumed: the old code reported "pinned to gateway"
        // from the state file alone, which is the one row that explains a black
        // hole and the one row that was never measured.
        for host in state.hosts {
            let gateway = RouteManager.hostRouteGateway(host, using: runner)
            let value: String
            switch gateway {
            case let gateway? where !gateway.isEmpty:
                value = "pinned via \(gateway)"
            case .some:
                value = "on-link, no gateway"
            case nil:
                value = "MISSING"
            }
            items.append(DetailItem(label: "host " + host, value: value))
        }

        if items.isEmpty {
            return DetailResponse(what: "routes", error: "no routes recorded")
        }
        return DetailResponse(what: "routes", items: items)
    }

    // MARK: dns

    private static func dnsDetail(using runner: CommandRunner) -> DetailResponse {
        let service = DNSManager.activeService(using: runner)
        let servers = service.map { DNSManager.current(service: $0, using: runner) } ?? []

        var items: [DetailItem] = []
        if servers.isEmpty {
            // No configured resolver is not an error: it means the network
            // hands them out over DHCP and there is nothing to measure.
            items.append(DetailItem(label: "Resolver",
                                    value: "automatic (from DHCP)"))
        }
        for server in servers {
            let ms = Probes.dnsLatency(server: server, using: runner)
            items.append(DetailItem(label: server,
                                    value: ms.map { "\($0) ms" } ?? "no answer"))
        }
        return DetailResponse(what: "dns", items: items)
    }

    // MARK: tunnel

    private static func tunnelDetail(using runner: CommandRunner) -> DetailResponse {
        guard let iface = RouteManager.interfaceList(using: runner)?.first else {
            return DetailResponse(what: "tunnel", error: "tunnel is down")
        }

        let state = RouteStateStore.load()
        let facts = RouteManager.facts(iface: iface, using: runner)
        var items: [DetailItem] = [
            DetailItem(label: "Interface", value: iface),
            DetailItem(label: "Mode", value: state.mode),
            DetailItem(label: "Endpoint", value: facts.endpoint ?? "—"),
        ]

        let age = facts.handshakeEpoch.map {
            max(0, Int(Date().timeIntervalSince1970) - $0)
        }
        items.append(DetailItem(label: "Handshake",
                                value: age.map { "\($0) s ago" } ?? "never"))

        // `wg show <iface> transfer` prints nothing when the interface has no
        // peer, and the Python therefore showed no Received/Sent rows in that
        // case. A nil transfer is the same situation: omit the rows rather than
        // print "0 B", which reads as "the tunnel moved no traffic".
        if facts.peerPubkey != nil, let transfer = facts.transfer {
            items.append(DetailItem(label: "Received",
                                    value: Probes.humanBytes(transfer.rx)))
            items.append(DetailItem(label: "Sent",
                                    value: Probes.humanBytes(transfer.tx)))
        }

        return DetailResponse(what: "tunnel", items: items)
    }

    // MARK: discord

    private static func discordDetail(using runner: CommandRunner) -> DetailResponse {
        // These are the three names Discord actually needs. Resolving them
        // through the system resolver is the point: a tunnel that routes
        // Discord's ranges but leaves the resolver alone still breaks the
        // client, and this popup is where that shows up.
        var items: [DetailItem] = []
        for host in ["discord.com", "gateway.discord.gg", "cdn.discordapp.com"] {
            let answers = Probes.systemAnswers(host, using: runner)
            items.append(DetailItem(label: host,
                                    value: answers.isEmpty
                                        ? "no answer"
                                        : answers.prefix(3).joined(separator: ", ")))
        }

        let probe = Probes.discord(using: runner)
        // The Python rendered "HTTP 200 · None ms" when curl gave a status but
        // no timing. A missing timing is not worth a row that reads as broken,
        // so the timing is dropped when absent.
        let https: String
        if probe.code != 0 {
            https = probe.ms.map { "HTTP \(probe.code) · \($0) ms" }
                ?? "HTTP \(probe.code)"
        } else {
            https = "unreachable (\((probe.failure ?? .blocked).rawValue))"
        }
        items.append(DetailItem(label: "HTTPS", value: https))

        return DetailResponse(what: "discord", items: items)
    }
}
