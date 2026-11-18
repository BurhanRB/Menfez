// NetworksSheet.swift — "Networks": remembered networks and the mode each
// one wants (feature 5). The work is `NetworkIdentity` / `NetworkRules` in the
// core and `Model.checkNetwork` / `rememberNetwork` / ...; this only shows it.

import SwiftUI
import MenfezCore

struct NetworksSheet: View {
    @ObservedObject var m: Model
    /// Off only for the snapshot renderer, which sets the network itself.
    var readsNetwork = true
    var onClose: () -> Void = {}

    @State private var renaming: String?
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text(m.l.t("net_title"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.text)

            Toggle(isOn: Binding(get: { m.networksAuto }, set: { m.setNetworksAuto($0) })) {
                Text(m.l.t("net_auto"))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.switch)
            .accessibilityLabel(m.l.t("net_auto"))

            Text(m.l.t("net_intro"))
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)

            current
            list

            ForEach(notes, id: \.self) { key in
                Text(m.l.t(key))
                    .font(.system(size: 10.5))
                    .foregroundStyle(key == "net_recovered" ? Palette.warning : Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
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
        .onAppear { if readsNetwork { m.checkNetwork() } }
    }

    /// "This network: Home", or why it has no name, and the remember button.
    private var current: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: m.networkID == nil ? "questionmark.circle" : "wifi")
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondary)
                .accessibilityHidden(true)
            Text(currentLine)
                .font(.system(size: 12))
                .foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            if m.networkID != nil && m.currentNetwork == nil
                && m.networks.count < NetworkList.maxNetworks {
                Button(action: m.rememberNetwork) {
                    Text(m.l.t("net_remember"))
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(Palette.accent)
                .foregroundStyle(Palette.accentText)
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .fixedSize()
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var currentLine: String {
        if let known = m.currentNetwork { return m.l.t("net_current", ["name": known.name]) }
        if m.networkID != nil { return m.l.t("net_unknown") }
        return m.l.t(m.networkRead ? "net_cannot" : "net_reading")
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            if m.networks.isEmpty {
                Text(m.l.t("net_empty"))
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary)
                    .padding(10)
            }
            ForEach(Array(m.networks.enumerated()), id: \.element.id) { index, network in
                if index > 0 { Divider().opacity(0.5) }
                row(network)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    private func row(_ network: KnownNetwork) -> some View {
        HStack(alignment: .center, spacing: 8) {
            if renaming == network.id {
                TextField(m.l.t("net_name_label"), text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit { finishRename(network.id) }
                    .accessibilityLabel(m.l.t("net_name_label"))
                Button(m.l.t("net_rename_done")) { finishRename(network.id) }
                    .font(.system(size: 11.5))
            } else {
                Text(network.name)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if network.id == m.networkID {
                    Text(m.l.t("net_now"))
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Palette.accent.opacity(0.14))
                        .foregroundStyle(Palette.accent)
                        .clipShape(Capsule())
                        .fixedSize()
                }
                Spacer(minLength: 6)
                Picker("", selection: Binding(get: { network.mode },
                                              set: { m.setNetworkMode(network.id, $0) })) {
                    ForEach(NetworkMode.allCases, id: \.self) { mode in
                        Text(modeLabel(mode)).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(m.busy)
                .accessibilityLabel(m.l.t("net_mode_label", ["name": network.name]))
                Button {
                    draft = network.name
                    renaming = network.id
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(m.l.t("net_rename") + " " + network.name)
                .help(m.l.t("net_rename"))
                Button { m.forgetNetwork(network.id) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(m.l.t("net_forget") + " " + network.name)
                .help(m.l.t("net_forget"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func modeLabel(_ mode: NetworkMode) -> String {
        m.l.t(mode == .leave ? "net_mode_leave" : "mode_" + mode.rawValue)
    }

    private func finishRename(_ id: String) {
        m.renameNetwork(id, draft)
        renaming = nil
    }

    private var notes: [String] {
        var out = ["net_how"]
        if m.networksRecovered { out.append("net_recovered") }
        return out
    }
}
