// PACFile.swift — "DPI in the browser": the proxy auto-config script the DPI
// engine serves at http://127.0.0.1:<port>/menfez.pac (1.0.8).
//
// The system proxy setting (helper `proxy pac <port>`) points Safari, Chrome
// and other Chromium browsers at this script. Only https to a name on the
// user's browser list (or a subdomain of one) goes to the proxy; everything
// else, and every plain http URL (the proxy speaks CONNECT only), is DIRECT.
// "PROXY ...; DIRECT" means a dead port (the app quit or crashed) falls back
// to a direct connection instead of failing the page.
//
// Names reach a JavaScript string, so only `[a-z0-9.-]` is accepted: nothing
// in an accepted entry needs escaping, and a quote, backslash or newline can
// never get into the script (PACFileTests tries).

import Foundation

public enum PACFile {

    /// Fixed path (AS-16): the listener is loopback-only and the Host check
    /// below keeps web pages out, so a secret path would add nothing.
    public static let path = "/menfez.pac"
    public static let contentType = "application/x-ns-proxy-autoconfig"

    /// The entry as stored, or nil when it cannot go into a PAC: a site name
    /// or a public IPv4 address (an IPv6 literal is left out; browsers write
    /// it in brackets and it is rare on a block list).
    public static func entry(_ raw: String) -> String? {
        guard let entry = SiteRoutes.normalize(raw), isSafe(entry) else { return nil }
        return entry
    }

    static func isSafe(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 253
            && text.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7a) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2e || $0 == 0x2d }
            && (SiteRoutes.isHostname(text) || ConnectRequest.dottedQuad(text) != nil)
    }

    /// The script for `entries` and the engine's port. Entries that fail
    /// `entry` are dropped, not escaped.
    public static func script(entries: [String], port: Int) -> String {
        var names: [String] = []
        for raw in entries.prefix(SiteRoutes.maxSites) {
            if let name = entry(raw), !names.contains(name) { names.append(name) }
        }
        let list = names.map { "\"\($0)\"" }.joined(separator: ", ")
        return """
        // Menfez: sites on your browser list go through Menfez's DPI proxy.
        function FindProxyForURL(url, host) {
          var u = url.toLowerCase();
          if (u.substring(0, 6) != "https:" && u.substring(0, 4) != "wss:") return "DIRECT";
          host = host.toLowerCase();
          var sites = [\(list)];
          for (var i = 0; i < sites.length; i++) {
            if (host == sites[i] || dnsDomainIs(host, "." + sites[i])) return "PROXY 127.0.0.1:\(port); DIRECT";
          }
          return "DIRECT";
        }

        """
    }

    /// True for exactly `GET /menfez.pac HTTP/1.x` whose Host is this
    /// machine's loopback. Anything else stays with the CONNECT parser (and
    /// its refusal). The Host check stops a web page from reading the list
    /// through a name that resolves to 127.0.0.1 (DNS rebinding).
    public static func isRequest(head: [UInt8]) -> Bool {
        let text = String(decoding: head, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first,
              first == "GET \(path) HTTP/1.1" || first == "GET \(path) HTTP/1.0" else { return false }
        let hosts = lines.dropFirst().compactMap { line -> String? in
            guard let colon = line.firstIndex(of: ":"),
                  line[..<colon].lowercased() == "host" else { return nil }
            return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces).lowercased()
        }
        guard hosts.count == 1, let host = hosts.first else { return false }
        let name = host.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
        let port = host.split(separator: ":", maxSplits: 1).dropFirst().first
        guard name == "127.0.0.1" || name == "localhost" else { return false }
        return port.map { !$0.isEmpty && $0.allSatisfy(\.isNumber) } ?? true
    }

    /// The whole HTTP reply.
    public static func response(entries: [String], port: Int) -> String {
        let body = script(entries: entries, port: port)
        return "HTTP/1.1 200 OK\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(body.utf8.count)\r\n"
            + "Cache-Control: no-store\r\n"
            + "Connection: close\r\n\r\n"
            + body
    }
}
