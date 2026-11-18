// Redact.swift — what may be said about a config that failed.
//
// WHY
// `wg-quick` and `wg` echo the offending config line on a parse error
// ("Line unrecognized: '<line>'", "Invalid key: '<value>'"). The managed config
// necessarily contains the user's `PrivateKey`, so the raw output of a config
// operation is the one path by which key material could reach the JSON the UI
// prints — and from there the screen, a screenshot, or a bug report.
//
// The rule this file enforces: a config operation never returns tool text.
// What the user gets instead is a fixed sentence plus a summary that can only
// contain line numbers, section names and the *names* of keys. Nothing here
// even looks at a value: a line is classified by its key prefix and, when that
// key is key material, its number alone is reported.
//
// This is deliberately a whitelist. A new tool message that says something
// useful will not leak by default; it will simply not appear until somebody
// adds a rule for it.

import Foundation

public enum Redact {

    /// Keys whose *value* is a credential, compared case-insensitively after
    /// trimming. `PublicKey` is not here: it is published in every handshake.
    static let secretKeys: Set<String> = [
        "privatekey", "presharedkey",
    ]

    /// One summarisable fact about a line of config.
    enum LineKind: Equatable {
        /// "[Peer]" / "[Interface]" — the section name is safe to repeat.
        case section(String)
        /// "PrivateKey = …" — only the line number and the key name.
        case secret(key: String)
        /// "AllowedIPs = …" — the key name; the value is not repeated either,
        /// because values are the part that can be confused with a key when a
        /// parser mangles two adjacent lines.
        case field(key: String)
        case comment
        case blank
        case unparsable
    }

    /// Classify one line without ever holding its value.
    static func classify(_ line: String) -> LineKind {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .blank }
        if trimmed.hasPrefix("#") || trimmed.hasPrefix(";") { return .comment }
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
            return .section(trimmed.lowercased())
        }
        guard let equals = trimmed.firstIndex(of: "=") else { return .unparsable }
        let key = trimmed[trimmed.startIndex..<equals]
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        if secretKeys.contains(key) { return .secret(key: key) }
        if key.isEmpty || !key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
            // A line whose "key" is not a word is a mangled line; guessing at
            // it is how the value ends up in an error message.
            return .unparsable
        }
        return .field(key: key)
    }

    /// The sanitised summary of a config file, safe to put in JSON.
    ///
    /// Only the paths that need it (the "cannot apply this config" message)
    /// should call it, and only for the managed config the app wrote itself —
    /// this is about reporting a problem with our own rewrite, not about
    /// inspecting the user's file.
    public static func configSummary(_ text: String) -> [String] {
        var summary: [String] = []
        var section = ""
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, raw) in lines.enumerated() {
            let number = index + 1
            switch classify(String(raw)) {
            case .section(let name):
                section = name
                summary.append("line \(number): section \(name)")
            case .secret(let key):
                // The line number is the diagnostic; the value never appears.
                summary.append("line \(number): \(key) present (value withheld)")
            case .field(let key):
                summary.append("line \(number): \(key)\(section.isEmpty ? "" : " in \(section)")")
            case .unparsable:
                summary.append("line \(number): unparsable line (content withheld)")
            case .comment, .blank:
                continue
            }
            // A 60-line config would make the message useless; the first
            // problems are the ones that matter.
            if summary.count >= 12 { break }
        }
        return summary
    }

    /// What the user is told when a config operation fails.
    ///
    /// `lineNumbers` are 1-based lines the parser rejected, when a caller can
    /// tell (wg's own messages sometimes name one). No caller may pass text.
    public static func configFailure(_ operation: String,
                                     lineNumbers: [Int] = []) -> String {
        var message = "\(operation) could not be applied; the config was rejected"
        if !lineNumbers.isEmpty {
            let list = lineNumbers.map(String.init).joined(separator: ", ")
            message += " (line \(list))"
        }
        return message + ". Nothing was changed."
    }

    /// Strip anything that looks like key material from a block of tool output.
    ///
    /// This is the second line of defence, for output whose shape is not known
    /// in advance. Every line containing a secret key name is replaced
    /// wholesale rather than edited: a filter that keeps "everything after the
    /// equals sign except…" is one regex bug away from printing the key.
    public static func scrub(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var cleaned: [String] = []
        for raw in lines {
            if case .secret = classify(String(raw)) {
                cleaned.append("[redacted: key material]")
            } else {
                cleaned.append(String(raw))
            }
        }
        return cleaned.joined(separator: "\n")
    }
}

// MARK: - Shareable text

extension Redact {

    /// Mask a block of diagnostic text so the user can attach it to a bug report.
    ///
    /// Unlike `scrub`, this edits values: the export is useless without the
    /// shape of the addresses and names, and useless to a stranger with them.
    /// Order matters — key tokens go first so no later rule can see a key, and
    /// IPv6 before IPv4 so a mapped address is handled once.
    public static func forSharing(_ text: String) -> String {
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            // Whole line, wherever the name sits ("… PrivateKey = …", "private_key: …").
            let flat = line.lowercased().filter { $0.isLetter }
            return !secretKeys.contains(where: { flat.contains($0) })
        }
        var out = kept.joined(separator: "\n")
        out = replace(#"(?<![A-Za-z0-9+/])[A-Za-z0-9+/]{43}=(?![A-Za-z0-9+/=])"#, in: out) { _ in
            "[redacted: key]"
        }
        // A router MAC or a network id (feature 5) says where the user is.
        out = replace(#"(?<![\w:])(?:[0-9A-Fa-f]{1,2}:){5}[0-9A-Fa-f]{1,2}(?![\w:])"#, in: out) { _ in "[mac]" }
        out = replace(#"(?<![0-9A-Fa-f])[0-9A-Fa-f]{64}(?![0-9A-Fa-f])"#, in: out) { _ in "[id]" }
        out = replace(#"(?<![\w:.])(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}(?![\w:])"#, in: out, maskIPv6)
        out = replace(#"(?<![\w.])(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?![\w.])"#, in: out, maskIPv4)
        out = replace(#"(?<![\w.*-])(?:[A-Za-z0-9-]+\.)+([A-Za-z]{2,})(?![\w.-])"#, in: out) { m in
            let tld = m.split(separator: ".").last!
            // "menfez.log", "Menfez.app": a file name, not a host.
            if fileExtensions.contains(tld.lowercased()) { return m }
            return "\(m.first!)*****.\(tld)"
        }
        return out
    }

    /// Endings that make a dotted token a file name rather than a domain.
    static let fileExtensions: Set<String> = ["log", "txt", "json", "plist", "conf", "app", "swift", "sh"]

    /// The DoH providers' public resolvers: everyone's, so they identify nobody.
    static let publicResolvers = Set(DoHProvider.allCases.flatMap(\.addresses))

    /// Private, loopback, link-local and CGNAT stay readable: they say which
    /// interface or tunnel address was involved and identify nobody.
    static func maskIPv4(_ text: String) -> String {
        if publicResolvers.contains(text) { return text }
        let o = text.split(separator: ".").compactMap { Int($0) }
        guard o.count == 4, o.allSatisfy({ $0 <= 255 }) else { return text }
        let local = o[0] == 10 || o[0] == 127 || o[0] == 0
            || (o[0] == 172 && (16...31).contains(o[1]))
            || (o[0] == 192 && o[1] == 168)
            || (o[0] == 169 && o[1] == 254)
            || (o[0] == 100 && (64...127).contains(o[1]))
        return local ? text : "\(o[0]).\(o[1]).x.x"
    }

    static func maskIPv6(_ text: String) -> String {
        var addr = in6_addr()
        guard inet_pton(AF_INET6, text, &addr) == 1 else { return text }
        let b = withUnsafeBytes(of: addr) { Array($0) }
        let unspecifiedOrLoopback = b[0..<15].allSatisfy { $0 == 0 } && b[15] <= 1
        let linkLocal = b[0] == 0xfe && (b[1] & 0xc0) == 0x80
        let uniqueLocal = (b[0] & 0xfe) == 0xfc
        if unspecifiedOrLoopback || linkLocal || uniqueLocal { return text }
        let g0 = UInt16(b[0]) << 8 | UInt16(b[1]), g1 = UInt16(b[2]) << 8 | UInt16(b[3])
        return String(format: "%x:%x:…", g0, g1)
    }

    private static func replace(_ pattern: String, in text: String,
                                _ transform: (String) -> String) -> String {
        let regex = try! NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += transform(ns.substring(with: m.range))
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }
}
