// FindSetting.swift — "Find a setting" (1.0.8, feature 8). The search is
// `StrategySearch`; the per-network memory is `DPITuning`. This runs it off
// the main actor and keeps the running engine's split in line with the
// network the Mac is on.

import SwiftUI
import MenfezCore

enum TuningState: Equatable {
    case trying(Int, Int)
    case done(StrategySearch.Outcome)
}

extension Model {

    /// Only after the user clicks (ROADMAP AS-19); never on its own.
    func findSetting() {
        if case .trying = tuning { return }
        let current = dpi.splitAt
        let network = networkID
        tuning = .trying(0, StrategySearch.candidates(current: current).count)
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { [weak self] in
                StrategySearch.run(
                    current: current,
                    direct: { DPIProbe.attempt(host: DPIProbe.defaultHost, proxyPort: nil, doh: Probes.curlSupportsDoH) },
                    attempt: { value in
                        // A throwaway engine on its own port: the running proxy
                        // and its connections are never touched.
                        var config = DPIEngine.Configuration()
                        config.firstRecordPayloadLimit = value
                        let engine = DPIEngine(configuration: config)
                        defer { engine.stop() }
                        guard let port = (try? engine.start())?.port else {
                            return DPIProbeOutcome.Attempt(exit: -1, error: "proxy did not start")
                        }
                        return DPIProbe.attempt(host: DPIProbe.defaultHost, proxyPort: port)
                    },
                    progress: { index, count in
                        Task { @MainActor in self?.tuning = .trying(index, count) }
                    })
            }.value
            tuning = .done(outcome)
            if case .found(let value) = outcome {
                DPITuning().save(value, for: network)
                applyDPISplit()
            }
        }
    }

    /// "Back to default" for this network.
    func forgetSetting() {
        if let id = networkID { DPITuning().forget(id) }
        tuning = nil
        applyDPISplit()
    }

    var networkHasSetting: Bool { DPITuning().value(for: networkID) != nil }

    /// Point the running engine at this network's length (or the default).
    func applyDPISplit() {
        dpiEngine?.setSplit(DPITuning().effective(for: networkID))
        refreshDPIStatus()
    }

    /// The search line under the probe verdict, or nil when there is nothing
    /// to say.
    var tuningLine: String? {
        switch tuning {
        case .none: return nil
        case .trying(let i, let n):
            return i == 0 ? l.t("tune_starting") : l.t("tune_trying", ["i": "\(i)", "n": "\(n)"])
        case .done(.found(let value)):
            return l.t(networkID == nil ? "tune_found_global" : "tune_found", ["n": "\(value)"])
        case .done(.notNeeded): return l.t("tune_not_needed")
        case .done(.dnsBlocked): return l.t("tune_dns")
        case .done(.noneWorked): return l.t("tune_none")
        }
    }
}
