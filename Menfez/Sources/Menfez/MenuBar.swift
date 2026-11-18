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

/// Cmd-, : the one setting that is about the app rather than the network.
struct SettingsView: View {
    @ObservedObject var m: Model
    @ObservedObject var updater = Updater.shared
    @AppStorage(DiscordUpdateRoutes.defaultsKey) private var updatesViaTunnel = true
    @AppStorage(NotificationEvent.tunnelDropped.defaultsKey) private var notifyTunnel = true
    @AppStorage(NotificationEvent.serverRemoved.defaultsKey) private var notifyServer = true
    @AppStorage(NotificationEvent.dpiStopped.defaultsKey) private var notifyDPI = true
    @AppStorage(NotificationEvent.helperUpdate.defaultsKey) private var notifyHelper = true
    @State var recording = false
    @State var needsModifier = false
    @State var monitor: Any?

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
            if updater.available {
                Toggle(isOn: Binding(
                    get: { updater.automatic },
                    set: { updater.setAutomatic($0) })) {
                    Text(m.l.t("app_update_auto")).fixedSize(horizontal: false, vertical: true)
                }
            }
            if m.capabilities.tunnelAvailable {
                Picker(m.l.t("scope_label"), selection: Binding(
                    get: { m.scopeChoice },
                    set: { m.setTunnelScope($0) })) {
                    ForEach(TunnelScope.Choice.allCases, id: \.self) { scope in
                        Text(m.l.t("m_" + scope.rawValue)).tag(scope)
                    }
                }
                .pickerStyle(.radioGroup)
                .disabled(m.busy)
                Text(m.l.t("scope_" + m.scopeChoice.rawValue + "_hint"))
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
            notifications
            shortcut
        }
        .padding(Space.l)
        .frame(width: 320)
        .tint(Palette.accent)
        .background(Palette.bg)
        .onAppear { m.readLaunchAtLogin() }
    }
}

extension SettingsView {
    /// Record a global shortcut. A local key monitor sees only keys pressed in
    /// this window while recording, so it needs no permission either.
    @ViewBuilder var shortcut: some View {
        Text(m.l.t("hotkey_title"))
            .font(.headline)
            .padding(.top, Space.s)
        HStack(spacing: Space.s) {
            Text(m.hotKey?.display ?? m.l.t("hotkey_none"))
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .accessibilityLabel(m.l.t("hotkey_title") + ": " + (m.hotKey?.display ?? m.l.t("hotkey_none")))
            Spacer()
            Button(m.l.t(recording ? "hotkey_recording" : "hotkey_record")) { startRecording() }
                .disabled(recording)
            if m.hotKey != nil {
                Button(m.l.t("hotkey_clear")) { m.setHotKey(nil) }
            }
        }
        if let hint = shortcutHint {
            Text(hint)
                .font(.caption)
                .foregroundStyle(Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
        Text(m.l.t("hotkey_note"))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var shortcutHint: String? {
        if needsModifier { return m.l.t("hotkey_needs_modifier") }
        return m.hotKeyRefused ? m.l.t("hotkey_taken") : nil
    }

    private func startRecording() {
        recording = true
        needsModifier = false
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stopRecording(); return nil } // Esc
            let mods = HotKeyCombo.carbonModifiers(cocoa: event.modifierFlags.rawValue)
            guard let combo = HotKeyCombo(keyCode: UInt32(event.keyCode), modifiers: mods,
                                          key: event.charactersIgnoringModifiers ?? "") else {
                needsModifier = true
                return nil
            }
            m.setHotKey(combo)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }

    /// One switch per event; all on by default (see `NotificationEvent`).
    @ViewBuilder var notifications: some View {
        Text(m.l.t("notify_title"))
            .font(.headline)
            .padding(.top, Space.s)
        Toggle(m.l.t("notify_tunnelDropped_setting"), isOn: $notifyTunnel)
        Toggle(m.l.t("notify_serverRemoved_setting"), isOn: $notifyServer)
        Toggle(m.l.t("notify_dpiStopped_setting"), isOn: $notifyDPI)
        Toggle(m.l.t("notify_helperUpdate_setting"), isOn: $notifyHelper)
        Text(m.l.t("notify_note"))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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
