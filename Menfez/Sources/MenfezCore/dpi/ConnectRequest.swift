// ConnectRequest.swift — the only HTTP this proxy parses: one request line.
//
// SCOPE, DELIBERATELY NARROW
// --------------------------
// A CONNECT tunnel needs exactly one thing from HTTP: the authority to dial.
// Everything after `\r\n\r\n` is TLS bytes and is never examined. This file
// therefore parses a request line and nothing else — no header folding, no
// chunked bodies, no keep-alive reuse.
//
// WHAT IS REFUSED AND WHY
// -----------------------
//   * Anything that is not CONNECT. A forward proxy for plain `GET http://…`
//     would have to rewrite the request target and strip hop-by-hop headers;
//     that is a different feature with a much larger surface, and the app this
//     proxy exists for (Electron) sends only CONNECT for the https/wss traffic
//     Discord uses. Refusing is honest; silently mangling would not be.
//   * A target without a port. RFC 7231 authority-form is `host:port`; a
//     missing port would need a guessed default, and guessing 443 on a
//     CONNECT the client meant for something else is how a proxy surprises
//     its user.
//   * A header block over the limit. Bounded before parsing, so a client that
//     sends a 10 MB request line costs 8 KiB of memory, not 10 MB.

import Foundation
import Network

/// The dial target of a CONNECT request.
public struct ConnectRequest: Equatable, Sendable {
    /// Host as written, without IPv6 brackets.
    public let host: String
    public let port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    /// How it was written, for logs: `[::1]:443` or `discord.com:443`.
    public var authority: String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    /// Why this target must not be dialled, or nil when it may be.
    ///
    /// The listener has no authentication, so anything local can use it. Without
    /// this check it would relay to loopback services (ssh, a dev server), the
    /// LAN and link-local metadata addresses. Discord needs only https/wss, so
    /// only port 443 to a public host is allowed. A name that resolves to a
    /// private address is caught after resolving, in `DPIEngine`'s dial.
    /// True for an IPv4 dotted quad or an IPv6 literal: nothing to resolve.
    var isAddressLiteral: Bool {
        host.contains(":") || Self.dottedQuad(host) != nil
    }

    public var policyRefusal: String? {
        guard port == 443 else { return "port \(port) is not allowed; only 443" }
        var name = host.lowercased()
        while name.hasSuffix(".") { name.removeLast() }
        if name == "localhost" || name.hasSuffix(".localhost") || name.hasSuffix(".local") {
            return "local name \(host) is not allowed"
        }
        if name.contains(":") {
            guard let v6 = IPv6Address(name) else { return "malformed IPv6 address" }
            return Self.isPrivate(v6: [UInt8](v6.rawValue)) ? "address \(host) is not public" : nil
        }
        // A last label starting with a digit is never a real TLD, so the host
        // must be a strict dotted quad; this also refuses `127.1`, `2130706433`
        // and `0x7f.0.0.1`, which a resolver would quietly turn into loopback.
        guard let last = name.split(separator: ".").last?.first, last.isNumber else { return nil }
        guard let v4 = Self.dottedQuad(name) else { return "ambiguous numeric host \(host)" }
        return Self.isPrivate(v4: v4) ? "address \(host) is not public" : nil
    }

    static func dottedQuad(_ text: String) -> [UInt8]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: [UInt8] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  part.count == 1 || part.first != "0",
                  let value = UInt8(part) else { return nil }
            out.append(value)
        }
        return out
    }

    /// 0/8, 10/8, 100.64/10, 127/8, 169.254/16, 172.16/12, 192.168/16, and
    /// 224/3 (multicast, reserved, broadcast).
    static func isPrivate(v4 a: [UInt8]) -> Bool {
        a[0] == 0 || a[0] == 10 || a[0] == 127 || a[0] >= 224
            || (a[0] == 100 && a[1] & 0xc0 == 64)
            || (a[0] == 169 && a[1] == 254)
            || (a[0] == 172 && a[1] & 0xf0 == 16)
            || (a[0] == 192 && a[1] == 168)
    }

    /// ::, ::1, fc00::/7, fe80::/10, multicast, and IPv4-mapped private v4.
    static func isPrivate(v6 b: [UInt8]) -> Bool {
        if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] <= 1 { return true }
        if b[0] & 0xfe == 0xfc || b[0] == 0xff { return true }
        if b[0] == 0xfe && b[1] & 0xc0 == 0x80 { return true }
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {
            return isPrivate(v4: Array(b[12..<16]))
        }
        return false
    }
}

public enum ConnectParseError: Error, Equatable, CustomStringConvertible {
    /// Not enough bytes yet: keep reading.
    case incomplete
    /// The header block grew past the limit.
    case headerTooLarge(limit: Int)
    case malformedRequestLine
    case unsupportedMethod(String)
    case unsupportedVersion(String)
    case malformedTarget
    case missingPort
    case invalidPort(String)

    public var description: String {
        switch self {
        case .incomplete:            return "request line incomplete"
        case .headerTooLarge(let l): return "request header larger than \(l) bytes"
        case .malformedRequestLine:  return "malformed request line"
        case .unsupportedMethod(let m): return "method \(m) is not supported; only CONNECT"
        case .unsupportedVersion(let v): return "HTTP version \(v) is not supported"
        case .malformedTarget:       return "malformed CONNECT target"
        case .missingPort:           return "CONNECT target has no port"
        case .invalidPort(let p):    return "CONNECT target port \(p) is not 1-65535"
        }
    }
}

public enum ConnectRequestParser {

    /// Maximum size of the whole CONNECT header block, terminator included.
    ///
    /// 8 KiB, because Chromium's CONNECT is a few hundred bytes (`CONNECT
    /// host:443 HTTP/1.1` plus `Host`, `Proxy-Connection`, `User-Agent`) and
    /// 8 KiB is what production HTTP servers use as their large-header limit
    /// (nginx `large_client_header_buffers` defaults to 8k). A request bigger
    /// than that would be rejected by the origin anyway, so buffering past it
    /// buys nothing and is exactly what a memory-exhaustion attempt wants.
    public static let maxHeaderBytes = 8 * 1024

    /// Longest authority accepted. `host:port` is at most 253 (DNS name) or
    /// 47 (`[IPv6]:port`); 512 leaves room for anything legitimate while still
    /// refusing to build a dial string from a megabyte of junk.
    public static let maxAuthorityBytes = 512

    /// Parse a complete header block. `head` must include `\r\n\r\n`.
    ///
    /// Only the first line is read: the request line. Header fields are ignored
    /// on purpose — a CONNECT tunnel inherits nothing from them, and acting on
    /// `Proxy-Authorization` or `Host` would be scope this proxy does not need.
    public static func parse(head: [UInt8]) throws -> ConnectRequest {
        guard let line = firstLine(of: head) else { throw ConnectParseError.incomplete }
        let text = String(decoding: line, as: UTF8.self)

        // Split on single spaces, as the RFC's request-line grammar does. Using
        // split(separator:) would collapse "CONNECT  host:443" into a valid
        // request, and a proxy should not repair malformed input silently.
        let parts = text.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw ConnectParseError.malformedRequestLine }

        let method = String(parts[0])
        guard method == "CONNECT" else {
            // A method we recognise but do not serve gets its own error, so the
            // log says "GET is not supported" rather than "malformed".
            if method.allSatisfy({ $0.isASCII && $0.isLetter }) {
                throw ConnectParseError.unsupportedMethod(method)
            }
            throw ConnectParseError.malformedRequestLine
        }

        let version = String(parts[2])
        guard version == "HTTP/1.1" || version == "HTTP/1.0" else {
            throw ConnectParseError.unsupportedVersion(version)
        }

        let target = String(parts[1])
        guard target.utf8.count <= maxAuthorityBytes else {
            throw ConnectParseError.malformedTarget
        }
        return try authority(target)
    }

    /// Split `host:port` or `[v6]:port`.
    ///
    /// Rejects any target that would be ambiguous once it reaches
    /// `NWEndpoint.Host`: an empty host, a host containing characters that do
    /// not belong in a name or an IP literal, or a port outside 1-65535.
    /// Rejecting here is what keeps a malformed client byte from becoming a
    /// dial to something nobody asked for.
    static func authority(_ target: String) throws -> ConnectRequest {
        guard !target.isEmpty else { throw ConnectParseError.malformedTarget }

        let host: String
        let portText: String

        if target.hasPrefix("[") {
            guard let close = target.firstIndex(of: "]") else {
                throw ConnectParseError.malformedTarget
            }
            host = String(target[target.index(after: target.startIndex)..<close])
            let rest = target[target.index(after: close)...]
            guard rest.hasPrefix(":") else { throw ConnectParseError.missingPort }
            portText = String(rest.dropFirst())
        } else {
            // rpartition on the last colon: a bare IPv6 address without
            // brackets would then parse as host:port and fail the host check
            // below, which is the honest outcome — RFC 3986 requires brackets.
            guard let colon = target.lastIndex(of: ":") else {
                throw ConnectParseError.missingPort
            }
            host = String(target[target.startIndex..<colon])
            portText = String(target[target.index(after: colon)...])
        }

        guard !host.isEmpty else { throw ConnectParseError.malformedTarget }
        // Letters, digits, dots, hyphens and underscores (seen in real DNS
        // names, e.g. CDN hosts) for names; hex digits and colons for
        // IPv6. No path separators, no whitespace, no control bytes, and no
        // '%' — percent-encoded hosts are a client-side construct that would
        // only obscure what this proxy dials.
        let hostScalars = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyz0123456789.-_:")
        guard host.lowercased().unicodeScalars.allSatisfy({ hostScalars.contains($0) }) else {
            throw ConnectParseError.malformedTarget
        }

        guard !portText.isEmpty, portText.count <= 5,
              portText.allSatisfy({ $0.isASCII && $0.isNumber }),
              let port = Int(portText), port >= 1, port <= 65535 else {
            throw ConnectParseError.invalidPort(portText)
        }
        return ConnectRequest(host: host, port: port)
    }

    /// The bytes before the first CRLF, or nil if there is no CRLF yet.
    static func firstLine(of head: [UInt8]) -> [UInt8]? {
        var index = 0
        while index + 1 < head.count {
            if head[index] == 0x0d && head[index + 1] == 0x0a {
                return Array(head[0..<index])
            }
            index += 1
        }
        return nil
    }
}

/// Bounded accumulator for the CONNECT header block.
///
/// WHY A SEPARATE TYPE
/// The limit has to be enforced *while* reading, not after. A caller that
/// appends to its own `Data` until it sees `\r\n\r\n` has already buffered
/// whatever the client sent; the check would run too late to protect anything.
/// This type refuses the byte that would cross the limit, so the peak buffer is
/// `maxBytes` exactly.
///
/// It also splits the chunk at the terminator, so bytes that arrive in the same
/// segment as the request head (Chromium sends the ClientHello immediately) are
/// returned as `remainder` instead of being counted against the header limit.
public struct ConnectHeadReader {

    public let maxBytes: Int
    private var buffer: [UInt8] = []

    public init(maxBytes: Int = ConnectRequestParser.maxHeaderBytes) {
        self.maxBytes = maxBytes
    }

    public var count: Int { buffer.count }
    public var bytes: [UInt8] { buffer }

    /// Add bytes. Returns the head and any bytes that followed it, or nil while
    /// the terminator has not arrived.
    ///
    /// Throws `headerTooLarge` instead of growing past `maxBytes`, which is what
    /// turns a 10 MB header line into an 8 KiB rejection. Only the bytes
    /// *before* `\r\n\r\n` count against the limit.
    public mutating func append(_ chunk: [UInt8])
        throws -> (head: [UInt8], remainder: [UInt8])? {
        var index = 0
        while index < chunk.count {
            buffer.append(chunk[index])
            index += 1

            if buffer.count >= 4, isTerminatorAtEnd() {
                let head = buffer
                buffer.removeAll(keepingCapacity: false)
                return (head, Array(chunk[index...]))
            }
            // A head of exactly `maxBytes` with no terminator cannot become a
            // valid head — a terminator would have to arrive at `maxBytes + 1`
            // or later — so the limit is enforced before that byte is stored.
            // That keeps the peak buffer at `maxBytes` rather than one past it.
            if buffer.count >= maxBytes {
                throw ConnectParseError.headerTooLarge(limit: maxBytes)
            }
        }
        return nil
    }

    private func isTerminatorAtEnd() -> Bool {
        let n = buffer.count
        return buffer[n - 4] == 0x0d && buffer[n - 3] == 0x0a
            && buffer[n - 2] == 0x0d && buffer[n - 1] == 0x0a
    }
}
