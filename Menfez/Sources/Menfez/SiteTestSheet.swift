// SiteTestSheet.swift — "Test a site": type a name, see which way it opens.
//
// The work is `SiteTest` in the core; this only collects the name, shows one
// row per way tried, and the sentence that says what to do. Status is always
// a word next to the colour, never colour alone.

import SwiftUI
import MenfezCore

struct SiteTestSheet: View {
    let lang: Lang
    /// Tunnel mode is on but only for Discord: say why the tunnel is not tried.
    var tunnelOnlyDiscord = false
    /// Runs the test off the main thread (`Model.runSiteTest`).
    var onRun: (String) async -> SiteTest.Report = { SiteTest.Report(host: $0, results: [:], summary: .notFound) }
    var onClose: () -> Void = {}

    @State var input = ""
    /// Not private, so a snapshot can render a finished test.
    @State var report: SiteTest.Report?
    @State private var running = false
    @State private var inputError: SiteTest.InputError?
    @FocusState private var focused: Bool

    private var l: L { L(lang: lang) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text(l.t("sitetest_title"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.text)
            Text(l.t("sitetest_intro"))
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Space.s) {
                TextField(l.t("sitetest_placeholder"), text: $input)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(run)
                    .disabled(running)
                    .accessibilityLabel(l.t("sitetest_title"))
                Button(action: run) {
                    HStack(spacing: 5) {
                        if running { ProgressView().controlSize(.mini) }
                        Text(l.t(running ? "sitetest_running" : "sitetest_run"))
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .background(Palette.accent)
                .foregroundStyle(Palette.accentText)
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .disabled(running)
            }

            if let inputError {
                Text(l.t("sitetest_err_" + inputError.rawValue))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let report, !running {
                results(report)
            }

            if tunnelOnlyDiscord {
                Text(l.t("sitetest_tunnel_discord_only"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(l.t("close")) { onClose() }
                    .buttonStyle(.pressable)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .modifier(Chip())
                    .foregroundStyle(Palette.text)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 420, alignment: .leading)
        .background(Palette.bg)
        .onAppear { focused = true }
    }

    private func results(_ r: SiteTest.Report) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(r.host)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Palette.secondary)
            ForEach(SiteTest.Path.allCases.filter { r.results[$0] != nil }, id: \.self) { path in
                let outcome = r.results[path]!
                HStack(spacing: 8) {
                    Text(l.t("sitetest_path_" + path.rawValue))
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.text)
                        .frame(width: 110, alignment: .leading)
                    Image(systemName: symbol(outcome))
                        .foregroundStyle(color(outcome))
                        .accessibilityHidden(true)
                    Text(l.t("sitetest_" + outcome.rawValue))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(color(outcome))
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
            Text(l.t("sitetest_sum_" + r.summary.rawValue))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    private func symbol(_ o: SiteTest.Outcome) -> String {
        switch o {
        case .opens: return "checkmark.circle.fill"
        case .fails: return "xmark.circle.fill"
        case .timedOut: return "clock.badge.exclamationmark"
        case .notFound: return "questionmark.circle"
        }
    }

    private func color(_ o: SiteTest.Outcome) -> Color {
        switch o {
        case .opens: return Palette.success
        case .fails, .timedOut: return Palette.danger
        case .notFound: return Palette.warning
        }
    }

    private func run() {
        guard !running else { return }
        switch SiteTest.host(from: input) {
        case .failure(let e):
            inputError = e
        case .success(let host):
            inputError = nil
            running = true
            Task {
                report = await onRun(host)
                running = false
            }
        }
    }
}
