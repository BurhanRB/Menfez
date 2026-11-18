// MenuBar.swift — the menu-bar extra, the Settings window, and the
// SMAppService adapter behind "Launch at login".
//
// The menu calls the same `Model` methods the window's buttons call
// (`setMode`, `switchServer`, `chooseAndImportConfig`); nothing here decides
// how a switch happens. The mode list and icons come from `MenuBarModes`.

import SwiftUI
import AppKit
import ServiceManagement
import MenfezCore

/// The mode, shown by figure: a template image has no colour to spend.
struct MenuBarIcon: View {
    let mode: RunMode

    var body: some View {
        if let cg = LogoMark.template(MenuBarModes.icon(mode)) {
            Image(nsImage: {
                let image = NSImage(cgImage: cg, size: NSSize(width: 22, height: 22))
                image.isTemplate = true
                return image
            }())
            .accessibilityLabel("Menfez · \(mode.rawValue)")
        } else {
            Image(systemName: "line.3.horizontal")
        }
    }
}

struct MenuBarContent: View {
    static let mainWindowID = "main"

    @ObservedObject var m: Model
    @Environment(\.openWindow) private var openWindow

    private var statusLine: String {
        m.status.isEmpty ? m.l.t(MenuBarModes.labelKey(m.runMode)) : m.status
    }

    var body: some View {
        Text(statusLine)

        Divider()

        ForEach(MenuBarModes.order, id: \.self) { mode in
            Toggle(m.l.t(MenuBarModes.labelKey(mode)), isOn: Binding(
                get: { m.runMode == mode },
                set: { on in if on { m.setMode(MenuBarModes.path(mode)) } }))
                .disabled(m.busy || (mode == .tunnel && !m.capabilities.tunnelAvailable))
            // Under Tunnel: what it carries.
            if mode == .tunnel && m.capabilities.tunnelAvailable {
                ForEach([Mode.discord, Mode.all], id: \.self) { scope in
                    Toggle("    " + m.l.t("m_" + scope.rawValue), isOn: Binding(
                        get: { m.tunnelScope == scope },
                        set: { on in if on { m.setTunnelScope(scope) } }))
                        .disabled(m.busy)
                }
            }
        }
        if !m.capabilities.tunnelAvailable && m.canRunTunnelInstaller {
            Button(m.l.t("tunnel_install")) { m.runTunnelInstaller(.install) }
                .disabled(m.tunnelInstall.isRunning)
        }

        Divider()

        // Servers only matter once the optional tunnel is set up.
        if m.capabilities.tunnelAvailable {
        Text(m.l.t("servers"))
        if m.profiles.isEmpty {
            // A hint, not an action: short, dimmed, set off from the button.
            // The full sentence lives in the servers sheet and Help.
            Text(m.l.t("byo_conf_short"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.top, 2)
                .disabled(true)
            Divider()
            Button(m.l.t("import_conf")) {
                NSApp.activate(ignoringOtherApps: true)
                m.chooseAndImportConfig()
            }
        } else {
            ForEach(m.profiles) { p in
                Toggle(p.display ?? Countries.name(p.country, lang: m.lang), isOn: Binding(
                    get: { p.active },
                    set: { on in if on { m.switchServer(p.name) } }))
                    .disabled(m.busy)
            }
        }

        Divider()
        }

        Toggle(m.l.t("launch_at_login"), isOn: Binding(
            get: { m.launchAtLogin },
            set: { m.setLaunchAtLogin($0) }))
            .disabled(!m.canLaunchAtLogin)
        if let hint = m.launchAtLoginHint {
            Text(hint).disabled(true)
        }

        Button(m.l.t("menu_open")) {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: Self.mainWindowID)
        }
        // "Remove tunnel" lives in Settings; a menu-bar app has no app menu
        // to find Cmd-, in. macOS 14 ignores `showSettingsWindow:`.
        if #available(macOS 14, *) {
            SettingsLink { Text(m.l.t("menu_settings")) }
                .keyboardShortcut(",")
        } else {
            Button(m.l.t("menu_settings")) {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            .keyboardShortcut(",")
        }

        Divider()

        Button(m.l.t("menu_quit")) { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// Cmd-, : the one setting that is about the app rather than the network.
struct SettingsView: View {
    @ObservedObject var m: Model
    @AppStorage(DiscordUpdateRoutes.defaultsKey) private var updatesViaTunnel = true

    var body: some View {
        Form {
            Toggle(m.l.t("launch_at_login"), isOn: Binding(
                get: { m.launchAtLogin },
                set: { m.setLaunchAtLogin($0) }))
                .disabled(!m.canLaunchAtLogin)
            if let hint = m.launchAtLoginHint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if m.capabilities.tunnelAvailable {
                Picker(m.l.t("scope_label"), selection: Binding(
                    get: { m.tunnelScope },
                    set: { m.setTunnelScope($0) })) {
                    Text(m.l.t("m_discord")).tag(Mode.discord)
                    Text(m.l.t("m_all")).tag(Mode.all)
                }
                .pickerStyle(.radioGroup)
                .disabled(m.busy)
                Text(m.l.t("scope_" + m.tunnelScope.rawValue + "_hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Only meaningful with a usable tunnel and a profile to bring up.
            if m.capabilities.tunnelAvailable && !m.profiles.isEmpty {
                Toggle(m.l.t("updates_tunnel"), isOn: $updatesViaTunnel)
                    .onChange(of: updatesViaTunnel) { _ in m.updatesSettingChanged() }
                Text(m.l.t("updates_tunnel_note"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // The one-time setup, both ways, through macOS's password dialog.
            if m.canRunTunnelInstaller {
                let available = m.capabilities.tunnelAvailable
                Button(m.l.t(available ? "tunnel_remove" : "tunnel_install")) {
                    m.runTunnelInstaller(available ? .remove : .install)
                }
                .disabled(m.tunnelInstall.isRunning || (available && m.runMode == .tunnel))
                if let note = available && m.runMode == .tunnel
                    ? m.l.t("tunnel_remove_leave_first") : m.tunnelInstallMessage {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(Space.l)
        .frame(width: 320)
        .tint(Palette.accent)
        .background(Palette.bg)
        .onAppear { m.readLaunchAtLogin() }
    }
}

/// `SMAppService.mainApp`, behind the core's protocol.
struct SystemLoginService: LoginService {
    var status: LoginServiceStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        default: return .notRegistered
        }
    }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}
