// Types.swift — the JSON contract between the helper and the app.
//
// These types are the single definition of the wire format. The helper encodes
// them, the app decodes them, and no string keys are written by hand anywhere
// else. Adding a field means adding it here and it is automatically available
// to both sides.
//
// Every optional field is optional for a reason: a probe that could not run
// (no network, no tunnel, missing tool) reports nil rather than failing the
// whole report. The UI renders nil as a dash.

import Foundation

// MARK: - Tunnel health

/// Why the tunnel is or is not usable.
///
/// This is deliberately richer than a boolean. The UI needs to distinguish
/// "no interface" from "interface exists but never completed a handshake" from
/// "handshake is stale", because each one has a different fix.
public struct Health: Codable, Equatable, Sendable {
    public enum Code: String, Codable, Sendable {
        case ok
        case gone          // the utun disappeared
        case noHandshake = "nohandshake"
        case stale         // handshake older than the tolerance
        case down          // no tunnel at all
        /// The interface is up but nothing has read the handshake yet.
        ///
        /// This code is produced *only by the app*, when the unprivileged
        /// report has no privileged sample to merge in. It must never be
        /// emitted by `menfez-route`: `Report.health` is non-optional, so an
        /// older app decoding an unknown code fails on the whole payload, and
        /// the app must keep working against whatever helper is on disk.
        /// Keeping the case here (rather than inventing a parallel type) means
        /// the UI has one enum to switch on.
        case unknown
    }

    public var ok: Bool
    public var code: Code
    public var ageS: Int?

    enum CodingKeys: String, CodingKey {
        case ok, code
        case ageS = "age_s"
    }

    public init(ok: Bool, code: Code, ageS: Int? = nil) {
        self.ok = ok
        self.code = code
        self.ageS = ageS
    }

    public static let down = Health(ok: false, code: .down)
}

// MARK: - Report

public struct RouteInfo: Codable, Equatable, Sendable {
    public var cidr: String
    public var present: Bool

    public init(cidr: String, present: Bool) {
        self.cidr = cidr
        self.present = present
    }
}

public struct Geo: Codable, Equatable, Sendable {
    public var country: String?
    public var city: String?
    public var region: String?
    public var org: String?
    /// Brand name derived from `org`, e.g. "Türksat" instead of the legal name.
    public var ispShort: String?

    enum CodingKeys: String, CodingKey {
        case country, city, region, org
        case ispShort = "isp_short"
    }

    public init(country: String? = nil, city: String? = nil, region: String? = nil,
                org: String? = nil, ispShort: String? = nil) {
        self.country = country
        self.city = city
        self.region = region
        self.org = org
        self.ispShort = ispShort
    }
}

public struct Transfer: Codable, Equatable, Sendable {
    public var rx: Int
    public var tx: Int

    public init(rx: Int = 0, tx: Int = 0) {
        self.rx = rx
        self.tx = tx
    }
}

public struct DiscordProbe: Codable, Equatable, Sendable {
    /// HTTP status, 0 when the request never completed.
    public var code: Int
    public var ms: Int?
    /// Why the request did not complete; nil when it did.
    public var failure: Failure?

    /// The step a failed request stopped at, from curl's exit status.
    public enum Failure: String, Codable, Sendable {
        /// The name did not resolve (curl 6, or 28 while resolving).
        case dns
        /// The TCP connection failed (curl 7).
        case connect
        /// The TLS handshake failed (curl 35 and the other TLS codes).
        case tls
        /// The local DPI proxy answered the CONNECT with an error (curl 56):
        /// it could not resolve or reach Discord, so nothing was tried past it.
        case proxy
        /// Anything else: a reset, a timeout after connecting.
        case blocked

        /// The app's string-table key for the Discord row.
        public var labelKey: String {
            switch self {
            case .dns: return "dns_blocked"
            case .connect: return "conn_failed"
            case .tls: return "tls_blocked"
            case .proxy: return "proxy_failed"
            case .blocked: return "blocked"
            }
        }
    }

    public init(code: Int = 0, ms: Int? = nil, failure: Failure? = nil) {
        self.code = code
        self.ms = ms
        self.failure = failure
    }
}

/// Everything the UI needs for one frame.
public struct Report: Codable, Equatable, Sendable {
    public var ts: Int
    public var tunnel: String?
    public var health: Health
    public var mode: String
    public var routes: [RouteInfo]
    public var hosts: [String]
    public var profile: String?
    public var endpoint: String?
    public var peerPubkey: String?
    public var handshakeAgeS: Int?
    public var handshakeEpoch: Int?
    /// nil when the probe could not run or the interface has no peer. It was
    /// a non-optional `Transfer()` once, which rendered a fabricated "0 B / 0 B"
    /// as a measurement — the one thing `Probes.swift` forbids.
    public var transfer: Transfer?
    public var dns: [String]
    public var dnsService: String?
    public var gateway: String?
    public var localIP: String?
    public var interface: String?
    public var egressIP: String?
    public var geo: Geo?
    /// Address seen from inside the tunnel. Only meaningful in `all` mode:
    /// in `discord` mode the probe endpoint is outside the routed ranges, so
    /// there is no single tunnel egress to report and this stays nil.
    public var vpnIP: String?
    public var vpnGeo: Geo?
    public var discord: DiscordProbe
    public var error: String?

    enum CodingKeys: String, CodingKey {
        case ts, tunnel, health, mode, routes, hosts, profile, endpoint
        case transfer, dns, gateway, interface, geo, discord, error
        case peerPubkey = "peer_pubkey"
        case handshakeAgeS = "handshake_age_s"
        case handshakeEpoch = "handshake_epoch"
        case dnsService = "dns_service"
        case localIP = "local_ip"
        case egressIP = "egress_ip"
        case vpnIP = "vpn_ip"
        case vpnGeo = "vpn_geo"
    }

    public init(ts: Int = Int(Date().timeIntervalSince1970),
                tunnel: String? = nil,
                health: Health = .down,
                mode: String = "off",
                routes: [RouteInfo] = [],
                hosts: [String] = [],
                profile: String? = nil,
                endpoint: String? = nil,
                peerPubkey: String? = nil,
                handshakeAgeS: Int? = nil,
                handshakeEpoch: Int? = nil,
                transfer: Transfer? = nil,
                dns: [String] = [],
                dnsService: String? = nil,
                gateway: String? = nil,
                localIP: String? = nil,
                interface: String? = nil,
                egressIP: String? = nil,
                geo: Geo? = nil,
                vpnIP: String? = nil,
                vpnGeo: Geo? = nil,
                discord: DiscordProbe = DiscordProbe(),
                error: String? = nil) {
        self.ts = ts
        self.tunnel = tunnel
        self.health = health
        self.mode = mode
        self.routes = routes
        self.hosts = hosts
        self.profile = profile
        self.endpoint = endpoint
        self.peerPubkey = peerPubkey
        self.handshakeAgeS = handshakeAgeS
        self.handshakeEpoch = handshakeEpoch
        self.transfer = transfer
        self.dns = dns
        self.dnsService = dnsService
        self.gateway = gateway
        self.localIP = localIP
        self.interface = interface
        self.egressIP = egressIP
        self.geo = geo
        self.vpnIP = vpnIP
        self.vpnGeo = vpnGeo
        self.discord = discord
        self.error = error
    }
}

// MARK: - Profiles

public struct Profile: Codable, Equatable, Sendable, Identifiable {
    /// Filename stem, e.g. "VPN-RO1-RO-229".
    public var name: String
    public var file: String
    public var endpoint: String?
    public var host: String?
    /// Two-letter country: from the filename when it names one, otherwise
    /// filled in from the exit IP by the picker.
    public var country: String?
    /// What the picker shows. May come from a `# Name =` comment in the config,
    /// a city in the filename, or the filename itself — see `ProfileNaming`.
    public var display: String?
    public var active: Bool
    public var error: String?

    public var id: String { name }

    public init(name: String, file: String, endpoint: String? = nil,
                host: String? = nil, country: String? = nil,
                display: String? = nil,
                active: Bool = false, error: String? = nil) {
        self.name = name
        self.file = file
        self.endpoint = endpoint
        self.host = host
        self.country = country
        self.display = display
        self.active = active
        self.error = error
    }

    /// The localisation key of the main window's "tunnel is set up" line. The
    /// server row says "none" until one is active, so "ready" alone would
    /// contradict it.
    public static func tunnelReadyKey(_ profiles: [Profile]) -> String {
        if profiles.isEmpty { return "tunnel_ready_add" }
        return profiles.contains(where: \.active) ? "tunnel_ready" : "tunnel_ready_pick"
    }
}

public struct ProfilesResponse: Codable, Sendable {
    public var profiles: [Profile]
    public var activeIface: String?

    enum CodingKeys: String, CodingKey {
        case profiles
        case activeIface = "active_iface"
    }

    public init(profiles: [Profile], activeIface: String? = nil) {
        self.profiles = profiles
        self.activeIface = activeIface
    }
}

// MARK: - DNS

public struct DNSPreset: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var note: String?
    public var v4: [String]
    /// Measured round trip in milliseconds, nil when the probe failed.
    public var ms: Int?
    /// False when the resolver did not answer or answered with a private
    /// address, which usually means the query was intercepted.
    public var ok: Bool
    public var active: Bool

    public init(id: String, name: String, note: String? = nil, v4: [String],
                ms: Int? = nil, ok: Bool = true, active: Bool = false) {
        self.id = id
        self.name = name
        self.note = note
        self.v4 = v4
        self.ms = ms
        self.ok = ok
        self.active = active
    }
}

public struct DNSReport: Codable, Sendable {
    public var service: String?
    public var current: [String]
    public var presets: [DNSPreset]

    public init(service: String? = nil, current: [String] = [], presets: [DNSPreset] = []) {
        self.service = service
        self.current = current
        self.presets = presets
    }
}

// MARK: - Detail popups

public struct DetailItem: Codable, Equatable, Sendable, Identifiable {
    public var label: String
    public var value: String
    public var id: String { "\(label)|\(value)" }

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

public struct DetailResponse: Codable, Sendable {
    public var what: String
    public var items: [DetailItem]
    public var error: String?

    public init(what: String, items: [DetailItem] = [], error: String? = nil) {
        self.what = what
        self.items = items
        self.error = error
    }
}

// MARK: - Actions

/// Uniform result for every mutating command.
public struct ActionResult: Codable, Sendable {
    public var ok: Bool
    public var error: String?
    public var mode: String?
    public var iface: String?
    public var profile: String?
    public var endpoint: String?
    public var routes: [String]
    public var servers: [String]?
    /// Human-readable remarks the user must see: "safety net not armed",
    /// "reverted to the previous set", a redacted config failure. These used to
    /// live only in the journal, which nothing ever read, so a warning like
    /// "safety net not armed" was invisible while the UI claimed success.
    public var notes: [String]
    /// Machine-readable failure kind, so the app never parses `error`.
    /// Only `configMissing` exists today; absent on success and older helpers.
    public var code: String?

    /// `up` found no managed config: /var/run was cleared at boot.
    public static let configMissing = "config_missing"

    enum CodingKeys: String, CodingKey {
        case ok, error, mode, iface, profile, endpoint, routes, servers, notes, code
    }

    public init(ok: Bool, error: String? = nil, mode: String? = nil,
                iface: String? = nil, profile: String? = nil,
                endpoint: String? = nil, routes: [String] = [],
                servers: [String]? = nil, notes: [String] = []) {
        self.ok = ok
        self.error = error
        self.mode = mode
        self.iface = iface
        self.profile = profile
        self.endpoint = endpoint
        self.routes = routes
        self.servers = servers
        self.notes = notes
    }

    public static func failure(_ message: String) -> ActionResult {
        ActionResult(ok: false, error: message)
    }

    /// Decode with a default for `notes`.
    ///
    /// A non-optional array would make decoding fail for any payload that
    /// predates the field, and the app decodes whatever the helper on disk
    /// produced. This is the one place a missing array is not an error.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decode(Bool.self, forKey: .ok)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        mode = try container.decodeIfPresent(String.self, forKey: .mode)
        iface = try container.decodeIfPresent(String.self, forKey: .iface)
        profile = try container.decodeIfPresent(String.self, forKey: .profile)
        endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint)
        routes = try container.decodeIfPresent([String].self, forKey: .routes) ?? []
        servers = try container.decodeIfPresent([String].self, forKey: .servers)
        notes = try container.decodeIfPresent([String].self, forKey: .notes) ?? []
        code = try container.decodeIfPresent(String.self, forKey: .code)
    }

    /// Failure that also carries the journal, so a warning the user must see
    /// ("safety net not armed") survives alongside the error.
    public static func failure(_ message: String, notes: [String]) -> ActionResult {
        ActionResult(ok: false, error: message, notes: notes)
    }

    /// Failure for an operation whose tool output must not be repeated.
    ///
    /// `wg-quick` and `wg` echo the offending config line, and the managed
    /// config contains the user's private key, so the raw text can never go
    /// into `error` or `notes`. What the user gets is a fixed sentence about
    /// what failed, plus a summary that can only contain line numbers and key
    /// *names* (see `Redact.configSummary`) — enough to file a useful report,
    /// not enough to carry the key.
    ///
    /// - Parameter summary: lines from `Redact.configSummary`. Passing raw tool
    ///   output here would defeat the whole point; the call sites are the two
    ///   config operations, and neither has any other source.
    public static func redacted(_ operation: String,
                                summary: [String] = [],
                                notes: [String] = []) -> ActionResult {
        var allNotes = notes
        if !summary.isEmpty {
            allNotes.append(contentsOf: summary)
        }
        return ActionResult(ok: false,
                            error: Redact.configFailure(operation),
                            notes: allNotes)
    }
}

// MARK: - Persisted state

/// Which routes this app added, so `down` removes exactly those.
public struct RouteState: Codable, Sendable {
    public var mode: String
    public var iface: String?
    public var routes: [String]
    public var hosts: [String]
    public var gateway: String?
    public var profile: String?
    /// True while a run is between "I am about to add these" and "these are
    /// live". A crash in that window leaves routes in the table that no
    /// completed run ever recorded, so start-up treats a pending file as a list
    /// of garbage to remove rather than as a claim of what is installed.
    public var pending: Bool
    /// Bumped on every successful apply. An armed `--revert-after` timer carries
    /// the generation it was armed with, so a timer left over from an earlier
    /// run cannot tear down a tunnel that a later run installed.
    public var generation: Int

    public init(mode: String = "off", iface: String? = nil,
                routes: [String] = [], hosts: [String] = [],
                gateway: String? = nil, profile: String? = nil,
                pending: Bool = false, generation: Int = 0) {
        self.mode = mode
        self.iface = iface
        self.routes = routes
        self.hosts = hosts
        self.gateway = gateway
        self.profile = profile
        self.pending = pending
        self.generation = generation
    }

    public static let empty = RouteState()
}

/// The resolver that was active before we changed it.
public struct DNSState: Codable, Sendable {
    public var previous: [String: [String]]
    public var applied: [String]

    public init(previous: [String: [String]] = [:], applied: [String] = []) {
        self.previous = previous
        self.applied = applied
    }
}

// MARK: - JSON helpers

public enum JSON {
    public static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    public static func decode<T: Decodable>(_ type: T.Type, from text: String) -> T? {
        // External tools print warnings before their output, and a pretty-
        // printed payload spans several lines. Try the whole text first, then
        // from the first brace onward, then line by line from the end. The
        // first attempt that decodes wins.
        let whole = Data(text.utf8)
        if let value = try? JSONDecoder().decode(T.self, from: whole) { return value }

        if let start = text.firstIndex(of: "{"),
           let value = try? JSONDecoder().decode(T.self, from: Data(text[start...].utf8)) {
            return value
        }

        for line in text.split(separator: "\n").reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{") else { continue }
            if let value = try? JSONDecoder().decode(T.self, from: Data(trimmed.utf8)) {
                return value
            }
        }
        return nil
    }
}
