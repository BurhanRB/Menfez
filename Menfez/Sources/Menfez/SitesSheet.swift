// SitesSheet.swift — "Sites through the tunnel": the list behind the
// Discord + sites scope. The work is `SiteRoutes` in the core and
// `Model.addSite` / `removeSite` / `checkSiteRoutes`; this only shows it.

import SwiftUI
import MenfezCore

struct SitesSheet: View {
    @ObservedObject var m: Model
    var onClose: () -> Void = {}

    @State private var input = ""
    @State private var problem: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text(m.l.t("sites_title"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.text)
            Text(m.l.t("sites_intro"))
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                TextField(m.l.t("sites_placeholder"), text: $input)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(add)
                    .accessibilityLabel(m.l.t("sites_title"))
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
                    .foregroundStyle(key == "sites_dns_outside" || key == "sites_recovered"
                                     ? Palette.warning : Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text(updatedLine)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.secondary)
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
        .onAppear {
            focused = true
            m.checkDNSRoutes()
            if !m.sites.isEmpty { Task { await m.resolveSites() } }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            if m.sites.isEmpty {
                Text(m.l.t("sites_empty"))
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary)
                    .padding(10)
            }
            ForEach(Array(m.sites.enumerated()), id: \.element) { index, site in
                if index > 0 { Divider().opacity(0.5) }
                row(site)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    private func row(_ site: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(site)
                .font(.system(size: 12))
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            status(site)
            Button { m.removeSite(site); problem = nil } label: {
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

    /// A word next to the colour: the count, or the failure in red.
    @ViewBuilder
    private func status(_ site: String) -> some View {
        if let count = m.siteCounts[site] {
            Text(count > 0 ? m.l.t("sites_count", ["what": String(count)]) : m.l.t("sites_unresolved"))
                .font(.system(size: 11))
                .foregroundStyle(count > 0 ? Palette.secondary : Palette.danger)
                .fixedSize()
        } else if m.sitesLookupRunning {
            Text(m.l.t("sites_checking"))
                .font(.system(size: 11))
                .foregroundStyle(Palette.secondary)
                .fixedSize()
        }
    }

    private var notes: [String] {
        var out: [String] = []
        if m.sitesRecovered { out.append("sites_recovered") }
        if m.scopeChoice != .sites { out.append("sites_not_active") }
        if m.dnsStaysOutside { out.append("sites_dns_outside") }
        return out
    }

    private var updatedLine: String {
        guard let at = m.sitesResolvedAt else { return "" }
        let minutes = Int(Date().timeIntervalSince(at) / 60)
        return minutes < 1 ? m.l.t("sites_ago_now") : m.l.t("sites_ago_min", ["what": String(minutes)])
    }

    private func add() {
        problem = m.addSite(input)
        if problem == nil { input = "" }
    }
}
