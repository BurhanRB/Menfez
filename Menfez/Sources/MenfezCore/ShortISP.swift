// ShortISP.swift — turn a legal network name into something a person
// recognises.
//
// ipinfo hands back strings like
//   "AS47524 Turksat Uydu Haberlesme Kablo TV ve Isletme A.S."
// which is unreadable in a 200 pt column. This reduces it to a brand.
//
// The alias table is data, not logic: add a regex and a label. Order matters
// only inside Turkey, where several operators share words ("turk", "telekom"),
// so the more specific brands come first.
//
// Everything here is pure: same input, same output, no I/O. That is what makes
// it cheap to unit test and safe to call from the UI thread.

import Foundation

public enum ShortISP {
    /// Curated aliases. Lowercased regex over the raw `org` value.
    static let aliases: [(pattern: String, label: String)] = [
        // --- Turkey, most specific first ---
        ("turksat|kablonet|kablo\\s*net", "Türksat"),
        ("turk\\s*telekom|ttnet", "Türk Telekom"),
        ("superonline|turkcell", "Turkcell"),
        ("vodafone", "Vodafone"),
        ("turknet|turk\\s*net", "TurkNet"),
        ("gibirnet|gibir", "GibirNet"),
        ("millenicom", "Millenicom"),
        ("netspeed", "NetSpeed"),
        ("comnet", "Comnet"),
        ("extranet", "Extranet"),
        ("d\\s*smart|dsmart", "D-Smart"),
        ("tivibu", "Tivibu"),
        ("radore", "Radore"),
        ("natro", "Natro"),
        ("isimtescil|isim\\s*tescil", "İsimtescil"),
        ("niobe", "Niobe"),
        ("hostinger", "Hostinger"),
        // --- VPN and hosting, visible while a tunnel is up ---
        ("proton", "Proton VPN"),
        ("m247", "M247"),
        ("datacamp|cdn77|psychz", "Datacamp"),
        ("cloudflare", "Cloudflare"),
        ("digitalocean", "DigitalOcean"),
        ("hetzner", "Hetzner"),
        ("ovh|soyoustart|kimsufi", "OVH"),
        ("leaseweb", "Leaseweb"),
        ("contabo", "Contabo"),
        ("vultr|choopa", "Vultr"),
        ("linode|akamai", "Linode"),
        ("amazon|\\baws\\b", "Amazon AWS"),
        ("microsoft|azure", "Microsoft Azure"),
        ("google", "Google"),
        ("oracle", "Oracle Cloud"),
        ("gcore", "Gcore"),
        ("zenlayer", "Zenlayer"),
        ("cogent", "Cogent"),
        ("lumen|level3", "Lumen"),
        ("retn", "RETN"),
        ("hurricane|he\\.net", "Hurricane Electric"),
    ]

    /// Legal suffixes and Turkish corporate filler that carry no meaning in a
    /// narrow column. Only used when no alias matched.
    static let noise = try! NSRegularExpression(
        pattern: "\\b(a\\.?s\\.?|ltd\\.?|limited|inc\\.?|llc|gmbh|b\\.?v\\.?|nv|"
            + "s\\.?r\\.?l\\.?|plc|co\\.?|corp\\.?|corporation|holding|holdings|group|"
            + "telekomunikasyon|iletisim|haberlesme|uydu|kablo|isletme|i\\s*letme|"
            + "ticaret|sanayi|anonym|shares)\\b",
        options: [.caseInsensitive])

    static let domain = try! NSRegularExpression(
        pattern: "\\b([a-z0-9][a-z0-9-]{1,30})\\.(?:com|net|org|co|tv)(?:\\.[a-z]{2})?\\b",
        options: [.caseInsensitive])

    /// Matches the registry prefix with or without something after it.
    ///
    /// The trailing `\s*` (not `\s+`) matters: ipinfo occasionally returns a
    /// bare "AS9999" with no organisation name, and with `\s+` that string
    /// survived every later pass and was shown to the user verbatim.
    static let asPrefix = try! NSRegularExpression(
        pattern: "^AS\\d+\\s*", options: [.caseInsensitive])

    /// "AS47524 Turksat Uydu..." -> "Türksat".
    ///
    /// Three passes, most specific first:
    ///   1. the curated alias table;
    ///   2. a domain-like name ("foo.com.tr" -> "Foo");
    ///   3. noise stripped, then the leading word.
    public static func short(_ org: String?) -> String? {
        guard var text = org?.trimmingCharacters(in: .whitespaces),
              !text.isEmpty else { return nil }

        let range = NSRange(text.startIndex..., in: text)
        text = asPrefix.stringByReplacingMatches(in: text, range: range,
                                                 withTemplate: "")
        let lower = text.lowercased()

        for (pattern, label) in aliases {
            if lower.range(of: pattern, options: .regularExpression) != nil {
                return label
            }
        }

        if let match = domain.firstMatch(in: lower,
                                         range: NSRange(lower.startIndex..., in: lower)),
           let r = Range(match.range(at: 1), in: lower) {
            let name = String(lower[r])
            if !["www", "mail", "static", "ip", "host", "ns"].contains(name) {
                return name.replacingOccurrences(of: "-", with: " ").capitalized
            }
        }

        let stripped = noise.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text),
            withTemplate: " ")
        let words = stripped
            .split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "/" })
            .map(String.init)
            .filter { $0.count > 1 && !$0.allSatisfy(\.isNumber) }

        guard let head = words.first else {
            // Nothing but the AS number was left ("AS9999"). Returning it
            // would put a bare registry id in the provider column, so report
            // "unknown" instead of pretending it is a brand.
            let remainder = text.trimmingCharacters(in: .whitespaces)
            return remainder.isEmpty ? nil : "Unknown"
        }
        let trimmed = head.trimmingCharacters(in: CharacterSet(charactersIn: ".,-"))
        if trimmed.count < 3, words.count > 1 {
            return "\(trimmed) \(words[1])"
        }
        return trimmed
    }
}
