// NetworkRules.swift — "home: Direct, school: DPI": the remembered networks,
// what each one wants, and the pure decision of what to do on joining one.
//
// Networks are keyed by `NetworkIdentity`'s hashed id. Names are the user's
// own ("Ağ 1" until renamed), never derived from the network itself.

import Foundation

/// What a remembered network asks for. `leave` ("Dokunma") changes nothing.
public enum NetworkMode: String, Codable, CaseIterable, Sendable {
    case direct, dpi, tunnel, leave

    public var runMode: RunMode? {
        switch self {
        case .direct: return .direct
        case .dpi: return .dpi
        case .tunnel: return .tunnel
        case .leave: return nil
        }
    }
}

public struct KnownNetwork: Codable, Equatable, Identifiable, Sendable {
    /// `NetworkIdentity.fingerprint`; other per-network settings key on it too.
    public var id: String
    public var name: String
    public var mode: NetworkMode

    public init(id: String, name: String, mode: NetworkMode) {
        self.id = id
        self.name = name
        self.mode = mode
    }

    enum CodingKeys: String, CodingKey { case id, name, mode }

    /// A mode a later version wrote and this one does not know reads as
    /// "leave", rather than throwing the whole file away.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        mode = (try? c.decode(NetworkMode.self, forKey: .mode)) ?? .leave
    }
}

/// `~/Library/Application Support/Menfez/networks.json` (0600). A file that
/// cannot be read is kept as `networks.json.bak` and the list starts empty
/// (§6.2); `load` says so and the app tells the user.
public struct NetworkList: Codable, Equatable, Sendable {
    public var version: Int
    public var networks: [KnownNetwork]

    public static let maxNetworks = 32
    public static let maxName = 40
    /// UserDefaults key of the global "change mode by network" switch (off by default).
    public static let enabledKey = "networks.auto"

    public init(networks: [KnownNetwork] = []) {
        self.version = 1
        self.networks = networks
    }

    public static var path: String {
        (Path.support as NSString).appendingPathComponent("networks.json")
    }

    public static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    public static func load(path: String = NetworkList.path) -> (list: NetworkList, recovered: Bool) {
        guard let data = FileManager.default.contents(atPath: path) else { return (NetworkList(), false) }
        if let list = try? JSONDecoder().decode(NetworkList.self, from: data), list.version == 1 {
            var clean: [KnownNetwork] = []
            for var n in list.networks where !n.id.isEmpty && !clean.contains(where: { $0.id == n.id }) {
                n.name = cleanName(n.name) ?? n.name.prefix(maxName).description
                clean.append(n)
            }
            return (NetworkList(networks: Array(clean.prefix(maxNetworks))), false)
        }
        let backup = path + ".bak"
        unlink(backup)
        _ = try? FileManager.default.moveItem(atPath: path, toPath: backup)
        return (NetworkList(), true)
    }

    @discardableResult
    public func save(path: String = NetworkList.path) -> Bool {
        StateFile.write(JSON.encode(self), to: path, mode: 0o600, dirMode: 0o700)
    }

    /// Trimmed, one line, at most `maxName`; nil when nothing is left.
    public static func cleanName(_ raw: String) -> String? {
        let flat = raw.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return flat.isEmpty ? nil : String(flat.prefix(maxName))
    }

    /// "Ağ 1", "Ağ 2", ...: the first `prefix n` not already taken.
    public func nextName(prefix: String) -> String {
        var n = 1
        while networks.contains(where: { $0.name == "\(prefix) \(n)" }) { n += 1 }
        return "\(prefix) \(n)"
    }

    public func entry(_ id: String?) -> KnownNetwork? {
        guard let id else { return nil }
        return networks.first { $0.id == id }
    }
}

/// What to do about the network the Mac is on.
public enum NetworkAction: Equatable, Sendable {
    case none
    case switchTo(RunMode)
    /// The rule says Tunnel but the tunnel cannot start here (no helper or no
    /// server): stay as is and tell the user.
    case needsTunnel
}

/// The current network and whether its rule is still owed.
///
/// A rule is applied once per join. Until then it is `pending`; the user's own
/// mode change on this network wins (`manual`) until the next network change.
public struct NetworkWatch: Equatable, Sendable {
    public private(set) var id: String?
    public private(set) var pending = false
    public private(set) var manual = false
    private var started = false

    public init() {}

    /// A fresh reading. A different id (or the first reading) is a join.
    public mutating func observe(_ id: String?) {
        guard !started || id != self.id else { return }
        started = true
        self.id = id
        pending = id != nil
        manual = false
    }

    /// The user picked a mode by hand.
    public mutating func userChose() { manual = true }

    /// The rule for this join was acted on (or found nothing to do).
    public mutating func settled() { pending = false }

    /// The user edited the rules or turned the feature on: apply again now.
    public mutating func reapply() {
        pending = id != nil
        manual = false
    }

    /// Pure decision for the current state.
    public static func decide(rule: NetworkMode?, enabled: Bool, pending: Bool, manual: Bool,
                              current: RunMode, tunnelReady: Bool) -> NetworkAction {
        guard enabled, pending, !manual, let target = rule?.runMode, target != current else { return .none }
        if target == .tunnel && !tunnelReady { return .needsTunnel }
        return .switchTo(target)
    }
}
