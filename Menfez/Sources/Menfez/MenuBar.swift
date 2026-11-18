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
    @ObservedObject var updater = Updater.shared
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
                ForEach(TunnelScope.Choice.allCases, id: \.self) { scope in
                    Toggle("    " + m.l.t("m_" + scope.rawValue), isOn: Binding(
                        get: { m.scopeChoice == scope },
                        set: { on in if on { m.setTunnelScope(scope) } }))
                        .disabled(m.busy || (scope == .sites && !m.sitesAvailable))
                }
            }
        }
        if let combo = m.hotKey {
            Text(m.l.t("hotkey_menu", ["what": combo.display])).disabled(true)
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
                    get: { m.isChosen(p) },
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

        if updater.available {
            Button(m.l.t("app_update_check")) { updater.checkForUpdates() }
                .disabled(!updater.canCheck)
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
