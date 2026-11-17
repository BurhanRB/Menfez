// TLSRecordReframer.swift — the whole bypass, expressed as arithmetic on
// five-byte headers.
//
// THE MEASURED RESULT THIS IMPLEMENTS (see docs/DPI-ENGINE.md)
// ---------------------------------------------------------------------
// The block is SNI-based DPI on TCP/443 that reassembles TCP, so splitting the
// ClientHello across TCP segments does not help. Re-cutting the ClientHello's
// *single TLS record* into two records does defeat it, provided the first
// record's payload is short enough (measured: <= 40 bytes passes, 41 resets).
//
// That works because the handshake bytes are untouched: the same payload, in
// the same order, with two 5-byte record headers inserted instead of one. The
// server's TLS stack reassembles records into the same handshake message it
// would have read anyway. The DPI, which only ever looks at a record it can
// parse, never sees a hostname.
//
// WHY THIS IS A LENGTH RULE AND NOT AN SNI RULE
// ---------------------------------------------
// `spike_split_rule.py` separated the two hypotheses: a 40-byte first record
// that *contains* the whole SNI still passed, and a 160-byte first record with
// no SNI at all still reset. The predictor is the length of the first record,
// not where the hostname sits inside it. So no ClientHello parsing is needed
// here — no SNI search, no extension walk, no length validation of the
// handshake. Nothing in this file looks below the record layer.
//
// WHAT IS DELIBERATELY NOT DONE
// -----------------------------
//   * No validation that the payload is a well-formed ClientHello. A malformed
//     record must never crash the app; it is forwarded like any other bytes.
//   * No reassembly of the second record. Once the first record has been
//     re-cut, the rest of the stream is a byte-for-byte pipe.
//
// HONESTY NOTE
// ------------
// The 40-byte boundary was measured on one ISP on one day, while the block was
// present in the same run. It is not an independently re-verified constant.
// It is one knob (`firstRecordPayloadLimit`) precisely so a different network
// can retune it without touching the proxy.

import Foundation

public enum TLSRecordReframer {

    /// First TLS record payload size. Measured on one ISP at 40; the DPI there
    /// failed to parse a first record this short. A different DPI may need a
    /// different value, so this is the one knob: this is the default, and
    /// `DPIEngine.Configuration.firstRecordPayloadLimit` (UserDefaults key
    /// `dpi.firstRecordPayloadLimit`, 1...200) overrides it per engine.
    ///
    /// Lower is not always safer: a first record of 1 byte defeats the same
    /// DPI (the spike saw 1,N pass for every N tried), but it makes the server
    /// do more work and looks more unusual on the wire. 40 is the largest value
    /// known to pass on the measured network, which is why it is the default.
    public static let firstRecordPayloadLimit = 40

    /// One TLS record header: content type (1), version (2), length (2).
    public static let recordHeaderLength = 5

    public static let handshakeContentType: UInt8 = 0x16
    public static let tlsMajorVersion: UInt8 = 0x03

    /// Bytes needed before the split decision can be made: the record header
    /// plus the first record's payload limit. Larger records are cut as soon as
    /// this many bytes exist, without waiting for the record to finish.
    public static var decisionWindow: Int {
        recordHeaderLength + firstRecordPayloadLimit
    }

    /// The two records produced by a split.
    ///
    /// `bytes` is `header1 + payload[0..<N] + header2 + payload[N...]`, so its
    /// length is `5 + N + 5 + (len - N)`.
    public struct Reframe: Equatable, Sendable {
        public let bytes: [UInt8]
        public let firstPayloadLength: Int
        public let secondPayloadLength: Int

        public init(bytes: [UInt8], firstPayloadLength: Int, secondPayloadLength: Int) {
            self.bytes = bytes
            self.firstPayloadLength = firstPayloadLength
            self.secondPayloadLength = secondPayloadLength
        }
    }

    /// True when the first bytes look like a TLS handshake record.
    ///
    /// Only two bytes are needed: `0x16` (handshake) and `0x03` (SSL 3.0
    /// through TLS 1.3 all use 0x030x record versions). This is the same test
    /// the spike's proxy used, and it is intentionally shallow: a proxy that
    /// parsed further would be a proxy that can be confused by a malformed
    /// ClientHello.
    public static func isHandshakeRecord(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 2 && bytes[0] == handshakeContentType && bytes[1] == tlsMajorVersion
    }

    /// The payload length declared by the record header, or nil if there is no
    /// complete header.
    public static func declaredPayloadLength(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= recordHeaderLength else { return nil }
        return (Int(bytes[3]) << 8) | Int(bytes[4])
    }

    /// Split one complete TLS handshake record into two records.
    ///
    /// Returns nil — "forward unchanged" — when the input is not a handshake
    /// record, when the record is incomplete, or when its payload already fits
    /// inside `firstRecordPayloadLimit`. The last case matters: producing a
    /// zero-length second record would be a change to the stream that buys
    /// nothing, and some servers reject empty records.
    public static func reframe(record: [UInt8],
                               limit: Int = firstRecordPayloadLimit) -> Reframe? {
        guard limit > 0, isHandshakeRecord(record),
              let declared = declaredPayloadLength(record),
              declared > limit,
              record.count >= recordHeaderLength + declared else { return nil }

        let payloadStart = recordHeaderLength
        let payload = Array(record[payloadStart..<(payloadStart + declared)])
        let first = Array(payload[0..<limit])
        let second = Array(payload[limit...])

        var out: [UInt8] = []
        out.reserveCapacity(recordHeaderLength * 2 + declared)
        out.append(contentsOf: header(major: record[1], minor: record[2], length: first.count))
        out.append(contentsOf: first)
        out.append(contentsOf: header(major: record[1], minor: record[2], length: second.count))
        out.append(contentsOf: second)

        return Reframe(bytes: out, firstPayloadLength: first.count,
                       secondPayloadLength: second.count)
    }

    /// A record header for the same content type as the handshake.
    ///
    /// The second record carries the same version bytes as the first. The spike
    /// did the same (`struct.pack("!BHH", 0x16, ver, ...)`), and a server
    /// accepts it because record-layer version negotiation already allows a
    /// ClientHello's records to say 0x0301 while the handshake offers 1.3.
    static func header(major: UInt8, minor: UInt8, length: Int) -> [UInt8] {
        [handshakeContentType, major, minor,
         UInt8((length >> 8) & 0xff), UInt8(length & 0xff)]
    }

    /// The bytes to emit for a full decision window: `header1 + limit +
    /// header2`, with the second header's length taken from the declared record
    /// length (which is why the remainder can stream through untouched).
    ///
    /// The caller guarantees `window.count == decisionWindow` and a header that
    /// `splitApplies` accepts.
    static func splitWindow(_ window: [UInt8],
                            limit: Int = firstRecordPayloadLimit) -> [UInt8] {
        let declared = (Int(window[3]) << 8) | Int(window[4])
        var out: [UInt8] = []
        out.reserveCapacity(window.count + recordHeaderLength)
        out.append(contentsOf: header(major: window[1], minor: window[2],
                                      length: limit))
        out.append(contentsOf: window[recordHeaderLength...])
        out.append(contentsOf: header(major: window[1], minor: window[2],
                                      length: declared - limit))
        return out
    }

    /// True when the decision window describes a record worth splitting.
    static func splitApplies(_ window: [UInt8], limit: Int = firstRecordPayloadLimit) -> Bool {
        isHandshakeRecord(window) && (declaredPayloadLength(window) ?? 0) > limit
    }
}

// MARK: - Streaming splitter

/// The proxy's per-connection state machine for the first record.
///
/// It buffers at most `TLSRecordReframer.decisionWindow` (45) bytes and makes
/// exactly one decision per connection:
///
///   * not a handshake record           -> `.passthrough`, everything unchanged
///   * payload fits in the limit        -> `.passthrough`, everything unchanged
///   * payload longer than the limit    -> `.split`, emit `header1 + first 40 +
///     header2` and pass the rest through as it arrives
///
/// The split is emitted as soon as the first 45 bytes exist, not when the whole
/// record has arrived. That keeps the buffered byte count bounded and adds no
/// latency: the server cannot start parsing the record until its header says
/// the payload is complete anyway.
public struct FirstRecordSplitter: Sendable {

    public enum Outcome: String, Sendable, Equatable {
        /// Fewer than 45 bytes seen; nothing has been forwarded yet.
        case undecided
        /// The first record was re-cut into two records.
        case split
        /// The stream is forwarded byte for byte.
        case passthrough
    }

    public private(set) var outcome: Outcome = .undecided

    /// Undecided bytes. Never exceeds `5 + limit`.
    private var pending: [UInt8] = []

    /// First record payload size for this connection.
    public let limit: Int

    /// `limit` below 1 falls back to the default: a 0-byte first record is
    /// not a split.
    public init(limit: Int = TLSRecordReframer.firstRecordPayloadLimit) {
        self.limit = limit > 0 ? limit : TLSRecordReframer.firstRecordPayloadLimit
    }

    /// Bytes seen but not yet forwarded. Bounded by `decisionWindow`.
    public var bufferedBytes: Int { pending.count }

    /// Feed one chunk of client bytes; returns the bytes to forward upstream.
    ///
    /// Returns an empty array while still undecided. Once a decision is made,
    /// every later chunk is returned unchanged, so callers can stop consulting
    /// this type after the first non-empty result.
    public mutating func feed(_ chunk: [UInt8]) -> [UInt8] {
        switch outcome {
        case .split, .passthrough:
            return chunk
        case .undecided:
            break
        }

        let window = TLSRecordReframer.recordHeaderLength + limit
        var consumed = 0
        if pending.count < window && !chunk.isEmpty {
            let take = min(window - pending.count, chunk.count)
            pending.append(contentsOf: chunk[0..<take])
            consumed = take
        }
        let rest = chunk[consumed...]

        // Decide as soon as one byte proves the stream is not a TLS handshake,
        // so a plain-text tunnel never waits for 45 bytes.
        guard let decided = decide() else { return [] }

        var out: [UInt8] = []
        switch decided {
        case .passthrough:
            outcome = .passthrough
            out = pending
            out.append(contentsOf: rest)
        case .split:
            outcome = .split
            out = TLSRecordReframer.splitWindow(pending, limit: limit)
            out.append(contentsOf: rest)
        }
        pending.removeAll(keepingCapacity: false)
        return out
    }

    /// End of stream before a decision: give back the buffered bytes
    /// unchanged and settle on passthrough. Empty once decided.
    public mutating func flush() -> [UInt8] {
        guard outcome == .undecided else { return [] }
        outcome = .passthrough
        defer { pending.removeAll(keepingCapacity: false) }
        return pending
    }

    private enum Decision { case passthrough, split }

    private func decide() -> Decision? {
        guard let first = pending.first else { return nil }
        if first != TLSRecordReframer.handshakeContentType { return .passthrough }
        guard pending.count >= 2 else { return nil }
        if pending[1] != TLSRecordReframer.tlsMajorVersion { return .passthrough }
        guard let declared = TLSRecordReframer.declaredPayloadLength(pending) else { return nil }
        // A record that already fits, or an empty one, has nothing to gain from
        // a split: emitting an empty second record would be a change with no
        // benefit and a small compatibility risk.
        if declared <= limit { return .passthrough }
        guard pending.count >= TLSRecordReframer.recordHeaderLength + limit else { return nil }
        return .split
    }
}
