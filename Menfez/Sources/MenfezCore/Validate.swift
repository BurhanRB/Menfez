// Validate.swift — the one place a user-supplied address or prefix is checked.
//
// WHY THIS EXISTS
// Two different kinds of input reach root-owned tools: a resolver from
// `dns set`, and (through the route layer) prefixes that end up in
// `route add -net`. Both are passed as argv elements, so they can never become
// shell syntax — but a malformed value is still handed to a privileged tool
// that may interpret it in ways nobody intended, and `networksetup` happily
// writes whatever it is given into the system resolver configuration.
//
// The rule is therefore: parse first, and refuse with a sentence the user can
// act on. Never "pass it through and let the tool complain", because the tool's
// complaint is the raw output that the redaction rules exist to keep out of
// the JSON.
//
// The other, quieter job here is path safety: `isSafeStem` is the check that a
// profile name cannot escape the profile directory.

import Foundation

public enum Validate {

    /// A `--if-generation` value: a plain non-negative integer, else nil.
    ///
    /// The revert timer passes this. Reading "abc" or a missing value as "no
    /// generation" turned a guarded `down` into an unconditional one.
    public static func generation(_ raw: String?) -> Int? {
        guard let raw, !raw.isEmpty, raw.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(raw)
    }

    // MARK: - Addresses

    /// The address in canonical form, or nil when it is not an IPv4/IPv6
    /// literal.
    ///
    /// `inet_pton` is used rather than a hand-rolled parser because it rejects
    /// the forms a routing tool may accept but which mean something
    /// surprising: leading zeros ("010.1.1.1" is octal in some parsers), a
    /// zone suffix ("fe80::1%en0"), brackets, and a port.
    public static func ipAddress(_ text: String) -> String? {
        var canonical = text.trimmingCharacters(in: .whitespaces)
        guard !canonical.isEmpty, canonical.count <= 64 else { return nil }
        // A trailing dot ("1.1.1.1.") is a DNS spelling, not an address; and a
        // bare "0x7f.1" is a legacy form. Both are refused by inet_pton, but
        // the explicit whitespace check keeps " 1.1.1.1 " from being trimmed
        // into something the user did not type.
        guard !canonical.contains(" "), !canonical.contains("\t"),
              !canonical.contains("%") else { return nil }

        // Leading zeros are accepted by inet_pton but mean octal to several
        // libc parsers, so "010.1.1.1" is 8.1.1.1 there and 10.1.1.1 here.
        // Two tools disagreeing about which host a resolver address names is
        // exactly the ambiguity this validator exists to remove, so the dotted
        // form is rejected outright when any octet has a leading zero.
        if canonical.contains(".") {
            for octet in canonical.split(separator: ".", omittingEmptySubsequences: false) {
                if octet.count > 3 { return nil }
                if octet.count > 1 && octet.hasPrefix("0") { return nil }
                if !octet.allSatisfy({ $0.isNumber }) { return nil }
            }
        }

        var v4 = in_addr()
        if inet_pton(AF_INET, canonical, &v4) == 1 { return canonical }

        var v6 = in6_addr()
        if inet_pton(AF_INET6, canonical, &v6) == 1 {
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &v6, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil
            else { return canonical }
            return String(cString: buffer)
        }
        canonical = ""
        return nil
    }

    // MARK: - Networks

    /// "162.159.128.0/18" when `text` is a network in canonical form, else nil.
    ///
    /// "Canonical form" includes the host bits being zero. A prefix such as
    /// "10.1.2.3/8" is not an accident worth silently repairing: the caller
    /// asked for a network and named a host, and `route add -net` would install
    /// a prefix that does not match what they typed. `networkProblem` explains
    /// the difference to the user.
    public static func network(_ text: String) -> String? {
        guard let parsed = parseNetwork(text), parsed.hostBitsAreZero else { return nil }
        return parsed.canonical
    }

    /// A sentence explaining why `text` is not a usable network, or nil when it
    /// is one. This is what the CLI prints before exiting 2.
    public static func networkProblem(_ text: String) -> String? {
        guard let parsed = parseNetwork(text) else {
            return "'\(text)' is not a CIDR prefix (expected address/bits, e.g. 162.159.128.0/18)"
        }
        guard parsed.hostBitsAreZero else {
            return "'\(text)' has host bits set; the network is \(parsed.canonical)"
        }
        return nil
    }

    private struct ParsedNetwork {
        var canonical: String
        var hostBitsAreZero: Bool
    }

    private static func parseNetwork(_ text: String) -> ParsedNetwork? {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let addressText = String(parts[0])
        guard let bits = Int(parts[1]), bits >= 0 else { return nil }

        var v4 = in_addr()
        if inet_pton(AF_INET, addressText, &v4) == 1 {
            guard bits <= 32 else { return nil }
            let value = UInt32(bigEndian: v4.s_addr)
            let mask: UInt32 = bits == 0 ? 0 : ~((1 &<< (32 - UInt32(bits))) - 1)
            let network = value & mask
            var out = in_addr(s_addr: network.bigEndian)
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &out, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil
            else { return nil }
            return ParsedNetwork(canonical: "\(String(cString: buffer))/\(bits)",
                                 hostBitsAreZero: network == value)
        }

        var v6 = in6_addr()
        if inet_pton(AF_INET6, addressText, &v6) == 1 {
            guard bits <= 128 else { return nil }
            let bytes = withUnsafeBytes(of: &v6) { Array($0) }
            guard bytes.count == 16 else { return nil }

            var masked = bytes
            var leftover = bits
            for index in 0..<16 {
                if leftover >= 8 {
                    leftover -= 8
                    continue
                }
                if leftover == 0 {
                    masked[index] = 0
                } else {
                    masked[index] &= UInt8(truncatingIfNeeded: 0xFF << (8 - leftover))
                    leftover = 0
                }
            }

            var out = in6_addr()
            withUnsafeMutableBytes(of: &out) { destination in
                for (index, byte) in masked.enumerated() { destination[index] = byte }
            }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &out, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil
            else { return nil }
            return ParsedNetwork(canonical: "\(String(cString: buffer))/\(bits)",
                                 hostBitsAreZero: masked == bytes)
        }
        return nil
    }

    // MARK: - Profile names

    /// True when `name` can only ever name an entry inside the profile
    /// directory.
    ///
    /// The picker only ever produces names from `list()`, but `switch` takes a
    /// string from the CLI, and the app passes whatever the helper last showed.
    /// A name is a filename stem, so anything that could change the *directory*
    /// part of a path — a separator, a "..", a leading dot, an embedded NUL, an
    /// empty string — is refused before it is compared with a listing.
    public static func isSafeStem(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 255 else { return false }
        guard name != ".", name != ".." else { return false }
        guard !name.hasPrefix(".") else { return false }
        if name.contains("/") || name.contains("\\") { return false }
        if name.contains("\0") { return false }
        // Control characters are legal on HFS+ but not something a server name
        // needs, and they make a log line lie about itself.
        if name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            return false
        }
        return true
    }
}
