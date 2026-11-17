// TunnelLoss.swift — did the tunnel the user chose stop carrying traffic?
//
// The kill-switch gap: the user picked tunnel mode, the interface vanished or
// its handshake went stale, and the status line kept looking calm while
// traffic went out unencrypted. This decides when to say so, from what the
// periodic report already measures.

import Foundation

public enum TunnelLoss {

    /// True when tunnel mode is selected but the latest report shows the
    /// tunnel is gone, down, or has a stale handshake.
    ///
    /// Deliberately silent on `.unknown` (we could not look) and
    /// `.noHandshake` (a fresh tunnel before its first handshake, or no
    /// privileged sample yet): a false alarm here would be the most alarming
    /// thing the app can say. Also silent while a switch is settling, when the
    /// report on screen may predate the tunnel coming up.
    public static func isLost(runMode: RunMode, report: Report?, settling: Bool) -> Bool {
        guard runMode == .tunnel, !settling, let report else { return false }
        if report.tunnel == nil { return report.health.code != .unknown }
        switch report.health.code {
        case .gone, .down, .stale: return true
        case .ok, .noHandshake, .unknown: return false
        }
    }
}
