// LogExport.swift — one plain-text file a user can attach to a bug report.
//
// Nothing here collects anything new: the route/DNS state is the same
// `ReportBuilder` output the window renders, the DPI counters are the engine's
// own `DPIStatus`, and the log lines are whatever `DebugLog` already wrote.
// The whole text goes through `Redact.forSharing` before it is capped, so the
// cap can never cut a key in half and leave a recognisable tail.

import Foundation

public enum LogExport {

    /// Mail and issue trackers choke above this; the newest lines matter most.
    public static let maxBytes = 1_000_000

    /// The files `DebugLog` writes, rotated copy first so lines stay in order.
    static let logNames = ["trace.log.1", "trace.log", "probe.log.1", "probe.log"]

    /// `menfez-debug-20261117-1430.txt`
    public static func fileName(at date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmm"
        return "menfez-debug-\(f.string(from: date)).txt"
    }

    /// Build the masked, capped report. Blocking (reads files, runs the local
    /// report commands when `report` is nil); call it off the main actor.
    public static func build(appVersion: String,
                             runMode: String,
                             dpi: DPIStatus?,
                             report: Report? = nil,
                             defaults: UserDefaults = .standard,
                             logDir: String = DebugLog.directory,
                             now: Date = Date()) -> String {
        let report = report ?? ReportBuilder().buildLocal()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        func json<T: Encodable>(_ value: T?) -> String {
            guard let value, let data = try? encoder.encode(value) else { return "(none)" }
            return String(decoding: data, as: UTF8.self)
        }

        let tunnelDNS = defaults.object(forKey: DNSManager.tunnelDNSKey) as? Bool ?? true
        let logging = defaults.bool(forKey: DebugLog.defaultsKey)
        let header = """
            Menfez debug log
            generated: \(ISO8601DateFormatter().string(from: now))
            app version: \(appVersion)
            macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
            run mode: \(runMode)
            route mode: \(report.mode)

            == DNS ==
            service: \(report.dnsService ?? "-")
            servers: \(report.dns.isEmpty ? "-" : report.dns.joined(separator: ", "))
            DoH provider: \(defaults.string(forKey: DoHProvider.defaultsKey) ?? DoHProvider.cloudflare.rawValue)
            DNS through tunnel: \(tunnelDNS)

            == DPI engine ==
            \(json(dpi))

            == Route state ==
            \(json(report))

            == Logs (debugLogging \(logging ? "on" : "off")) ==
            """
        let raw = logLines(in: logDir)
        // Added after masking: the bundle id would otherwise be read as a domain.
        let lines = raw.isEmpty
            ? ["(no log lines; turn logging on with: defaults write com.menfez.app debugLogging -bool true)"]
            : Redact.forSharing(raw.joined(separator: "\n"))
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return cap(header: Redact.forSharing(header), lines: lines)
    }

    /// Every `DebugLog` line, oldest first, tagged with its file.
    static func logLines(in dir: String) -> [String] {
        var tagged: [(Double, Int, String)] = []
        for name in logNames {
            let path = (dir as NSString).appendingPathComponent(name)
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let tag = name.replacingOccurrences(of: ".log", with: "")
            for line in text.split(separator: "\n") {
                let stamp = Double(line.prefix { $0 != " " }) ?? 0
                tagged.append((stamp, tagged.count, "[\(tag)] \(line)"))
            }
        }
        // Stable by timestamp, so trace and probe lines interleave in real order.
        return tagged.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
    }

    /// Header plus as many of the newest `lines` as fit in `maxBytes`.
    static func cap(header: String, lines: [String], maxBytes: Int = maxBytes) -> String {
        let full = header + "\n" + lines.joined(separator: "\n") + "\n"
        if full.utf8.count <= maxBytes { return full }
        // Room for the note; its number has at most 10 digits.
        var budget = maxBytes - header.utf8.count - 80
        var kept: [String] = []
        for line in lines.reversed() {
            let size = line.utf8.count + 1
            if size > budget { break }
            budget -= size
            kept.append(line)
        }
        let note = "[truncated: \(lines.count - kept.count) older lines dropped to stay under \(maxBytes) bytes]"
        return header + "\n" + note + "\n" + kept.reversed().joined(separator: "\n") + "\n"
    }
}
