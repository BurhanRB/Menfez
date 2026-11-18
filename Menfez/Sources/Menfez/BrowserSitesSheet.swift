// BrowserSitesSheet.swift — "Sites through Menfez in browsers" (1.0.8): the
// list the PAC (`PACFile`) sends to the DPI proxy. Separate from the tunnel's
// list (`SitesSheet`); same file format. The work is `Model.addBrowserSite` /
// `removeBrowserSite`; this only shows it.

import SwiftUI
import MenfezCore

struct BrowserSitesSheet: View {
    @ObservedObject var m: Model
    var onClose: () -> Void = {}

    @State private var input = ""
    @State private var problem: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text(m.l.t("browser_title"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.text)
            Text(m.l.t("browser_intro"))
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                TextField(m.l.t("sites_placeholder"), text: $input)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(add)
                    .accessibilityLabel(m.l.t("browser_title"))
                Button(action: add) {
                    Text(m.l.t("sites_add"))
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(Palette.accent)
                .foregroundStyle(Palette.accentText)
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let problem {
                Text(problem)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.danger)
            }

            list

            ForEach(notes, id: \.self) { key in
                Text(m.l.t(key))
                    .font(.system(size: 10.5))
                    .foregroundStyle(key == "browser_recovered" ? Palette.warning : Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if m.browserSites.contains(where: { if case .success = SiteTest.host(from: $0) { return true } else { return false } }) {
                    Button(m.l.t("browser_check_all")) { m.checkBrowserSites(m.browserSites) }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .modifier(Chip())
                        .foregroundStyle(Palette.accent)
                        .disabled(m.browserSites.allSatisfy { m.browserSiteChecks[$0].map { $0.outcome == nil } ?? false })
                }
                Spacer()
                Button(m.l.t("close")) { onClose() }
                    .buttonStyle(.plain)
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

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            if m.browserSites.isEmpty {
                Text(m.l.t("browser_empty"))
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
            }
            ForEach(Array(m.browserSites.enumerated()), id: \.element) { index, site in
                if index > 0 { Divider().opacity(0.5) }
                HStack(spacing: 8) {
                    Text(site)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    status(site)
                    Button { m.removeBrowserSite(site); problem = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.secondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(m.l.t("sites_remove") + " " + site)
                    .help(m.l.t("sites_remove"))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    /// Last DPI check of one site: running, the result with its age, or a
    /// Test button. Never started by opening the sheet.
    @ViewBuilder
    private func status(_ site: String) -> some View {
        if let check = m.browserSiteChecks[site] {
            if let raw = check.outcome {
                let outcome = SiteTest.Outcome(rawValue: raw) ?? .fails
                let key = outcome == .opens ? "sitetest_opens" : (outcome == .notFound ? "sitetest_notFound" : "sitetest_fails")
                HStack(spacing: 4) {
                    Image(systemName: outcome == .opens ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 11))
                    Text(m.l.t(key)).font(.system(size: 11.5, weight: .medium))
                    Text("· " + age(check.at))
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondary)
                }
                .foregroundStyle(outcome == .opens ? Palette.success : Palette.danger)
                .help(m.l.t("browser_check_again"))
                .onTapGesture { m.checkBrowserSites([site]) }
            } else {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text(m.l.t("sitetest_running") + "…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.secondary)
                }
            }
        } else if case .success = SiteTest.host(from: site) {
            Button(m.l.t("sitetest_run")) { m.checkBrowserSites([site]) }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Palette.accent)
        }
    }

    private func age(_ date: Date) -> String {
        let sec = max(0, Int(Date().timeIntervalSince(date)))
        return sec < 60 ? m.l.t("now") : m.humanAge(sec)
    }

    private var notes: [String] {
        var out: [String] = []
        if m.browserSitesRecovered { out.append("browser_recovered") }
        if !m.browserProxyWanted { out.append("browser_off_note") }
        out += ["browser_reload", "browser_firefox"]
        return out
    }

    private func add() {
        problem = m.addBrowserSite(input)
        if problem == nil { input = "" }
    }
}
