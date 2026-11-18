// NetworkIdentity.swift — tell one network from another without asking for
// any permission.
//
// The Wi-Fi name (SSID) needs location permission and an entitlement on
// macOS 14+, so it is not used (ROADMAP §4.5, AS-13). What is readable as the
// user, with no prompt: the primary interface and its router from the system
// configuration store, the DHCP domain of that service, and the router's MAC
// address from the ARP (IPv4) or neighbour (IPv6) table. Those three are
// hashed into one id; the raw MAC is never stored, logged or reported.
//
// A router whose MAC looks random (locally administered) or cannot be read
// gives no id: such a network is "unknown", never a guess.

import Foundation
import CryptoKit
import SystemConfiguration

public enum NetworkIdentity {

    public enum Kind: String, Sendable { case wifi, wired, other }

    /// What the system store says about the primary network right now.
    public struct Primary: Equatable, Sendable {
        public var interface: String?
        public var kind: Kind
        public var routerV4: String?
        public var routerV6: String?
        /// The DHCP search domain or domain name of the primary service.
        public var domain: String?

        public init(interface: String?, kind: Kind, routerV4: String?,
                    routerV6: String?, domain: String?) {
            self.interface = interface
            self.kind = kind
            self.routerV4 = routerV4
            self.routerV6 = routerV6
            self.domain = domain
        }
    }

    // MARK: - Pure parts

    /// Lower-case, two digits per byte. Nil for anything that is not a single
    /// universal unicast MAC: a locally administered address is what phones'
    /// "private address" and many hotspots use, and would not stay put.
    public static func normalizeMAC(_ raw: String) -> String? {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6 else { return nil }
        var bytes: [UInt8] = []
        for p in parts {
            guard (1...2).contains(p.count), let b = UInt8(p, radix: 16) else { return nil }
            bytes.append(b)
        }
        if bytes[0] & 0x03 != 0 { return nil }          // locally administered or multicast
        if bytes.allSatisfy({ $0 == 0 }) { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    /// `arp -n <ip>`: "? (192.168.1.1) at 0:1a:2b:3c:4d:5e on en0 ifscope [ethernet]".
    /// "(incomplete)" and "-- no entry" give nil.
    public static func macFromARP(_ output: String) -> String? {
        for line in output.split(separator: "\n") {
            let words = line.split(separator: " ")
            guard let at = words.firstIndex(of: "at"), at + 1 < words.count else { continue }
            if let mac = normalizeMAC(String(words[at + 1])) { return mac }
        }
        return nil
    }

    /// `ndp -an`: the row whose neighbour is `router` (scope suffix ignored)
    /// on `interface` when known. Columns: Neighbor, Linklayer, Netif, ...
    public static func macFromNDP(_ output: String, router: String, interface: String?) -> String? {
        let want = bare(router)
        for line in output.split(separator: "\n") {
            let cols = line.split(separator: " ")
            guard cols.count >= 3, bare(String(cols[0])) == want else { continue }
            if let interface, cols[2] != interface { continue }
            if let mac = normalizeMAC(String(cols[1])) { return mac }
        }
        return nil
    }

    private static func bare(_ address: String) -> String {
        String(address.split(separator: "%").first ?? "").lowercased()
    }

    /// The stored id: SHA-256 of kind, router MAC and domain, as hex.
    public static func fingerprint(kind: Kind, mac: String, domain: String?) -> String {
        let text = "v1|\(kind.rawValue)|\(mac)|\((domain ?? "").lowercased())"
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The id of the network described by `primary`, or nil when it cannot
    /// be told apart. At most one short `arp` or `ndp` run, as the user.
    public static func id(of primary: Primary?, runner: CommandRunner = SystemRunner()) -> String? {
        guard let primary else { return nil }
        var mac: String?
        if let v4 = primary.routerV4, isIPv4(v4) {
            mac = macFromARP(runner.run("/usr/sbin/arp", ["-n", v4], timeout: 2).output)
        } else if let v6 = primary.routerV6 {
            mac = macFromNDP(runner.run("/usr/sbin/ndp", ["-an"], timeout: 2).output,
                             router: v6, interface: primary.interface)
        }
        guard let mac else { return nil }
        return fingerprint(kind: primary.kind, mac: mac, domain: primary.domain)
    }

    static func isIPv4(_ text: String) -> Bool {
        var addr = in_addr()
        return inet_pton(AF_INET, text, &addr) == 1
    }

    // MARK: - System store (no spawn)

    /// Primary interface, routers and domain from `SCDynamicStore`. The
    /// domain is the service's own DHCP answer, not the merged global one,
    /// so Menfez's own DNS changes in Tunnel mode do not change the id.
    public static func readPrimary() -> Primary? {
        guard let store = SCDynamicStoreCreate(nil, "Menfez" as CFString, nil, nil) else { return nil }
        func dict(_ key: String) -> [String: Any]? {
            SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any]
        }
        let v4 = dict("State:/Network/Global/IPv4")
        let v6 = dict("State:/Network/Global/IPv6")
        let global = v4 ?? v6
        guard let global else { return nil }
        let interface = global["PrimaryInterface"] as? String
        var domain: String?
        if let service = global["PrimaryService"] as? String,
           let dns = dict("State:/Network/Service/\(service)/DNS") {
            domain = (dns["SearchDomains"] as? [String])?.first ?? dns["DomainName"] as? String
        }
        return Primary(interface: interface, kind: kind(of: interface),
                       routerV4: v4?["Router"] as? String,
                       routerV6: v6?["Router"] as? String,
                       domain: domain)
    }

    private static func kind(of bsdName: String?) -> Kind {
        guard let bsdName,
              let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface],
              let match = all.first(where: { SCNetworkInterfaceGetBSDName($0) as String? == bsdName }),
              let type = SCNetworkInterfaceGetInterfaceType(match) else { return .other }
        if type == kSCNetworkInterfaceTypeIEEE80211 { return .wifi }
        if type == kSCNetworkInterfaceTypeEthernet { return .wired }
        return .other
    }
}
