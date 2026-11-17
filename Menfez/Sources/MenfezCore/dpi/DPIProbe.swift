// DPIProbe.swift — is the proxy actually helping right now?
//
// WHY THIS EXISTS
// ---------------
// `DPIStatus.reframed > 0` proves the proxy split a record. It does not prove
// the network needed the split. Two very different situations produce the same
// counters:
//
//   * the block is active and the split is the reason Discord loads;
//   * the block lifted (as it did during the spike) and everything would load
//     anyway — the split is decoration.
//
// The only way to tell them apart is to ask the network twice, at nearly the
// same moment, the same way: once directly, once through the proxy. Direct
// success means the proxy is not needed now. Direct failure with a proxied
// success means the split is doing its job. Both failing means the proxy is not
// helping on this network — the block changed shape or something else is wrong.
//
// WHY A REAL TLS REQUEST AND NOT A TCP CONNECT
// --------------------------------------------
// The DPI keys on the ClientHello. A probe that only proves the TCP handshake
// works would pass straight through the block and report "not needed" on a
// fully blocked network, which is the exact lie this type exists to prevent.
// So both attempts perform a real TLS handshake to the same hostname, one with
// `--proxy` and one without — the same difference Discord experiences.
//
// WHY curl AND NOT Network.framework
// ----------------------------------
// Doing a TLS handshake *through* a CONNECT tunnel needs a protocol framer in
// Network.framework, and getting that wrong produces a probe that fails for its
// own reasons and blames the network. `curl -x` already implements CONNECT plus
// TLS correctly, the app already depends on curl for every other probe
// (`Probes.swift`), and the runner is injectable, so the probe is testable with
// no socket at all.
//
// WHAT IT IS NOT
// --------------
// Not a timer. Every probe makes two real requests, so it runs only when the
// user asks. A background probe would spend the user's bandwidth on a schedule
// and would turn "no samples" into "seems fine" in the UI.

import Foundation

public struct DPIProbeOutcome: Codable, Equatable, Sendable {

    /// What one attempt did.
    public struct Attempt: Codable, Equatable, Sendable {
        /// curl's exit status: 0 means the whole request completed. The HTTP
        /// code is deliberately not used, because a 403 from a captive portal
        /// would otherwise look like success.
        public var exit: Int
        /// Milliseconds for the attempt, nil when curl did not report.
        public var ms: Int?
        /// A fixed, non-sensitive reason (curl's own error class), never raw
        /// response bytes.
        public var error: String?

        /// True when the request completed end to end.
        public var ok: Bool { exit == 0 }

        /// True when the request stopped before the name resolved.
        public var dnsFailed: Bool { error == DPIProbe.dnsError }

        public init(exit: Int = -1, ms: Int? = nil, error: String? = nil) {
            self.exit = exit
            self.ms = ms
            self.error = error
        }
    }

    public var host: String
    public var direct: Attempt
    public var proxied: Attempt
    public var at: Date

    public init(host: String, direct: Attempt, proxied: Attempt, at: Date = Date()) {
        self.host = host
        self.direct = direct
        self.proxied = proxied
        self.at = at
    }

    public enum Verdict: String, Codable, Sendable {
        /// Direct failed, proxied worked: the split is what got through.
        case working
        /// Both worked: the proxy is not needed on this network right now.
        case notNeeded
        /// Both failed: the proxy is not helping here.
        case notHelping
        /// Both failed and the direct attempt never resolved the name, even
        /// over DoH: a DNS block, not a verdict on the split.
        case dnsBlocked
        /// Direct worked, proxied did not: the proxy is the problem.
        case proxyBroken
        /// The proxy was not running, or the request never reached it, so the
        /// two attempts cannot be compared. Distinct from `proxyBroken`: this
        /// one means "no measurement", the other means "a measurement that
        /// failed".
        case proxyOff

        /// The sentence the UI shows. Deliberately about the probe, not about
        /// Discord: one request cannot claim a whole app will work.
        public var sentence: String {
            switch self {
            case .working:
                return "Direct failed, the proxy got through — the split is helping."
            case .notNeeded:
                return "Direct works — this network is not blocking the host right now, so the split is not needed."
            case .notHelping:
                return "Both failed — the split is not helping on this network."
            case .dnsBlocked:
                return "Both failed and the name did not resolve — DNS is blocked, so the split was never tried."
            case .proxyBroken:
                return "Direct works but the proxy does not — the proxy is at fault, not the network."
            case .proxyOff:
                return "The proxy is not running, so there was nothing to compare."
            }
        }
    }

    public var verdict: Verdict {
        // `proxied.exit == -1` means no attempt was made (no port to try). It
        // is not a failure, so it must not fall into `proxyBroken`.
        guard proxied.exit >= 0 else { return .proxyOff }
        switch (direct.ok, proxied.ok) {
        case (false, true):  return .working
        case (true, true):   return .notNeeded
        case (false, false): return direct.dnsFailed ? .dnsBlocked : .notHelping
        case (true, false):  return .proxyBroken
        }
    }
}

public enum DPIProbe {

    /// The host the probe asks for.
    ///
    /// `discord.com`: the host the block targets and the one the spike
    /// measured. A neutral third party would answer a different question and
    /// could be blocked for unrelated reasons.
    public static let defaultHost = "discord.com"

    /// Per-request deadline.
    ///
    /// 5 s in curl and 8 s outside it, matching `Probes.discord` so the two
    /// numbers in the UI are comparable. 5 s is long enough for a TLS handshake
    /// on a slow tether and short enough that a blackholed SYN — which is what
    /// a DPI block looks like when it is not a reset — does not leave the user
    /// watching a spinner.
    public static let curlTimeout: TimeInterval = 5
    public static let outerTimeout: TimeInterval = 8

    /// Run one direct request and one through the proxy.
    ///
    /// Sequential, not parallel: a direct attempt that trips the DPI resets a
    /// flow on the shared path, so overlapping them would make the result
    /// harder to attribute. Sequential also means the engine's counters show
    /// exactly one new connection after a probe, which makes them checkable by
    /// hand.
    public static func run(port: Int?,
                           host: String = defaultHost,
                           doh: Bool = Probes.curlSupportsDoH,
                           using runner: CommandRunner = SystemRunner()) -> DPIProbeOutcome {
        let direct = attempt(host: host, proxyPort: nil, doh: doh, using: runner)
        guard let port, port > 0, port <= 65535 else {
            // `exit: -1` with no timing is the "no attempt was made" marker:
            // the verdict reads it as `proxyOff` rather than as a failure.
            return DPIProbeOutcome(host: host, direct: direct,
                                   proxied: .init(exit: -1, ms: nil,
                                                  error: "proxy not running"))
        }
        let proxied = attempt(host: host, proxyPort: port, using: runner)
        return DPIProbeOutcome(host: host, direct: direct, proxied: proxied)
    }

    /// One `curl` request, with or without a proxy.
    ///
    /// `-sS` keeps stdout quiet but lets errors through; `-o /dev/null` throws
    /// the body away so a large page never enters the process; `-I` asks for
    /// headers only, which still performs the full TLS handshake — the
    /// ClientHello is what the DPI inspects, and a HEAD sends one.
    ///
    /// The attempt is judged on curl's exit status, not on the HTTP code. A
    /// captive portal answering 200 with a login page would otherwise count as
    /// "the network is fine".
    public static func attempt(host: String,
                               proxyPort: Int?,
                               doh: Bool = false,
                               using runner: CommandRunner = SystemRunner()) -> DPIProbeOutcome.Attempt {
        var args = ["-sS", "-o", "/dev/null", "-I",
                    "--max-time", "\(Int(curlTimeout))"]
        if let proxyPort {
            // The proxy is HTTP CONNECT only; `--proxy` uses it for https.
            args += ["--proxy", "http://127.0.0.1:\(proxyPort)"]
        }
        // `--noproxy '*'` bypasses every proxy for the direct attempt, so an
        // https_proxy/ALL_PROXY in the environment cannot route it through a
        // proxy too — which would compare the proxy with itself and always
        // report "not needed". (An empty list would leave those in force.)
        if proxyPort == nil { args += ["--noproxy", "*"] }
        // The proxy resolves over DoH, so the direct attempt does too: then the
        // split is the only difference and a plain-DNS block cannot pass for a
        // TLS block.
        if proxyPort == nil, doh { args += ["--doh-url", DoHProvider.current().endpoints[0]] }
        args.append("https://\(host)/")

        let started = Date()
        let result = runner.run("curl", args, timeout: outerTimeout)
        let ms = Int(Date().timeIntervalSince(started) * 1000)

        if result.ok {
            return .init(exit: 0, ms: ms, error: nil)
        }
        if result.timedOut {
            return .init(exit: 28, ms: ms, error: "timed out")
        }
        return .init(exit: Int(result.status), ms: ms,
                     error: describe(exit: result.status, output: result.output))
    }

    static let dnsError = "could not resolve the host"


    /// Turn curl's exit code into a fixed sentence.
    ///
    /// The code is what matters and the text is only a hint: curl's stderr can
    /// contain the hostname and a resolver address, which is fine, but it must
    /// never be echoed verbatim into the UI where it could be mistaken for
    /// something the proxy said.
    static func describe(exit: Int32, output: String) -> String {
        switch exit {
        case 5:  return "could not resolve the proxy address"
        case 6:  return dnsError
        case 28 where output.contains("Resolving timed out"): return dnsError
        case 7:  return "could not connect"
        case 28: return "timed out"
        case 35: return "TLS handshake failed"
        case 52: return "server closed the connection without a reply"
        case 55: return "send failed"
        case 56: return "connection reset during transfer"
        case 60: return "TLS certificate not trusted"
        default:
            return "curl exit \(exit)"
        }
    }
}
