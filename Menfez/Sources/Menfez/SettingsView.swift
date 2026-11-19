// SettingsView.swift — the Settings window (⌘,), redesigned in 1.0.9.
//
// One tab per subject, drawn like the main window: a row of icon tabs, then
// cards of rows on the window background. The window is the content's size,
// so it grows and shrinks with the tab. Its title is "Ayarlar" / "Settings"
// in the app's language, not the system's.
//
// There is no DPI tab: every DPI control already sits in the main window's
// DPI card, and a second copy here would be a second place to look.

import SwiftUI
import AppKit
import MenfezCore

enum SettingsTab: String, CaseIterable {
    case general, tunnel, notifications, shortcut, updates

    /// The tab Settings opened on last time.
    static let lastKey = "settings.tab"
    static var last: SettingsTab {
        SettingsTab(rawValue: UserDefaults.standard.string(forKey: lastKey) ?? "") ?? .general
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .tunnel: return "lock.shield"
        case .notifications: return "bell"
        case .shortcut: return "command"
        case .updates: return "arrow.triangle.2.circlepath"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var m: Model
    @State var tab: SettingsTab = .last
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var updater = Updater.shared
    @AppStorage(Appearance.key) private var appearanceRaw = Appearance.system.rawValue
    @AppStorage(DiscordUpdateRoutes.defaultsKey) private var updatesViaTunnel = true
    @AppStorage(NotificationEvent.tunnelDropped.defaultsKey) private var notifyTunnel = true
    @AppStorage(NotificationEvent.serverRemoved.defaultsKey) private var notifyServer = true
    @AppStorage(NotificationEvent.dpiStopped.defaultsKey) private var notifyDPI = true
    @AppStorage(NotificationEvent.helperUpdate.defaultsKey) private var notifyHelper = true
    @AppStorage(NotificationEvent.networkSwitched.defaultsKey) private var notifyNetwork = true
    @AppStorage(NotificationEvent.tunnelReconnected.defaultsKey) private var notifyReconnect = true
    @AppStorage(Reconnect.autoKey) private var reconnectAuto = true
    @AppStorage(Reconnect.switchKey) private var reconnectSwitch = false
    @State var recording = false
    @State var needsModifier = false
    @State var monitor: Any?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let width: CGFloat = 470

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Rectangle().fill(Palette.separator).frame(height: 1)
            VStack(alignment: .leading, spacing: Space.l) {
                page
            }
            .padding(Space.l)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            // The app's own buttons, as in the main window. Buttons that set
            // their own style (tabs, shortcut examples) keep it.
            .buttonStyle(.secondary(h: Space.m, v: 5))
            .id(tab)
            .transition(.opacity)
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .animation(Animate.layout(reduceMotion), value: tab)
        .tint(Palette.accent)
        .background(Palette.bg)
        .background(WindowTitle(title: m.l.t("settings_title")))
        .onAppear { m.readLaunchAtLogin() }
        .onDisappear { stopRecording() }
    }

    // MARK: - Tabs

    private var tabBar: some View {
        HStack(spacing: Space.xs) {
            ForEach(Array(SettingsTab.allCases.enumerated()), id: \.element) { index, item in
                let selected = item == tab
                Button {
                    tab = item
                    UserDefaults.standard.set(item.rawValue, forKey: SettingsTab.lastKey)
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 16, weight: .regular))
                            .frame(height: 20)
                        Text(m.l.t("set_tab_" + item.rawValue))
                            .font(.system(size: 11, weight: selected ? .semibold : .regular))
                            .lineLimit(1)
                    }
                    .foregroundStyle(selected ? Palette.accent : Palette.secondary)
                    .frame(width: 84, height: 50)
                    .background(selected ? Palette.raised : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                .help("⌘\(index + 1)")
                .accessibilityLabel(m.l.t("set_tab_" + item.rawValue))
                .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(.vertical, Space.s)
        .frame(maxWidth: .infinity)
        .background(Palette.card)
    }

    @ViewBuilder private var page: some View {
        switch tab {
        case .general: general
        case .tunnel: tunnel
        case .notifications: notifications
        case .shortcut: shortcut
        case .updates: updates
        }
    }

    // MARK: - General

    @ViewBuilder private var general: some View {
        SettingsSection(note: m.launchAtLoginHint) {
            SwitchRow(title: m.l.t("launch_at_login"), isOn: Binding(
                get: { m.launchAtLogin },
                set: { m.setLaunchAtLogin($0) }))
                .disabled(!m.canLaunchAtLogin)
        }
        SettingsSection(title: m.l.t("set_look")) {
            PickerRow(title: m.l.t("set_language")) {
                Picker(m.l.t("set_language"), selection: Binding(
                    get: { m.lang }, set: { m.setLang($0) })) {
                    Text(Lang.tr.label).tag(Lang.tr)
                    Text(Lang.en.label).tag(Lang.en)
                }
            }
            RowDivider()
            PickerRow(title: m.l.t("appearance")) {
                Picker(m.l.t("appearance"), selection: Binding(
                    get: { Appearance(rawValue: appearanceRaw) ?? .system },
                    set: {
                        appearanceRaw = $0.rawValue
                        NSApp.appearance = $0.nsAppearance
                    })) {
                    ForEach(Appearance.allCases, id: \.self) {
                        Text(m.l.t("app_" + $0.rawValue)).tag($0)
                    }
                }
            }
        }
        SettingsSection(title: m.l.t("net_title"), note: m.l.t("set_networks_note")) {
            HStack {
                Text(m.l.t(m.networksAuto ? "net_auto_on" : "net_auto_off"))
                Spacer()
                Button(m.l.t("net_open")) {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: MenuBarContent.mainWindowID)
                    m.networkRequests += 1
                }
            }
            .padding(.vertical, Space.s)
        }
    }

    // MARK: - Tunnel

    @ViewBuilder private var tunnel: some View {
        if m.capabilities.tunnelAvailable {
            SettingsSection(title: m.l.t("scope_label"),
                            note: m.l.t("scope_" + m.scopeChoice.rawValue + "_hint")) {
                ScopePicker(m: m)
                    .padding(.vertical, Space.s)
            }
            if !m.profiles.isEmpty {
                SettingsSection(note: m.l.t("updates_tunnel_note")) {
                    SwitchRow(title: m.l.t("updates_tunnel"), isOn: $updatesViaTunnel)
                        .onChange(of: updatesViaTunnel) { _ in m.updatesSettingChanged() }
                }
                SettingsSection(title: m.l.t("set_reconnect"), note: m.l.t("rc_note")) {
                    SwitchRow(title: m.l.t("rc_auto"), isOn: $reconnectAuto)
                    RowDivider()
                    SwitchRow(title: m.l.t("rc_switch"), isOn: $reconnectSwitch)
                        .disabled(!reconnectAuto || m.profiles.count < 2)
                }
            }
        }
        // The one-time setup, both ways, through macOS's password dialog.
        if m.canRunTunnelInstaller {
            let available = m.capabilities.tunnelAvailable
            let note = available && m.runMode == .tunnel
                ? m.l.t("tunnel_remove_leave_first") : m.tunnelInstallMessage
            // The copy button follows the failure message (the section's note),
            // with the section's own spacing and note inset.
            VStack(alignment: .leading, spacing: Space.xs + 2) {
                SettingsSection(title: m.l.t("set_setup"), note: note ?? m.l.t(available ? "set_remove_note" : "set_install_note")) {
                    HStack {
                        Text(m.l.t(available ? "set_installed" : "set_not_installed"))
                        Spacer()
                        // Blocked while the tunnel runs: a lock and the reason,
                        // so it reads "not now" rather than "careful".
                        let blocked = available && m.runMode == .tunnel
                        Button {
                            m.runTunnelInstaller(available ? .remove : .install)
                        } label: {
                            HStack(spacing: 5) {
                                if blocked { Image(systemName: "lock.fill").font(.system(size: 10)) }
                                Text(m.l.t(available ? "tunnel_remove" : "tunnel_install"))
                            }
                        }
                        .help(blocked ? m.l.t("tunnel_remove_leave_first") : "")
                        .buttonStyle(MenfezButtonStyle(kind: available ? .danger : .primary, h: Space.m, v: 5))
                        .disabled(m.tunnelInstall.isRunning || (available && m.runMode == .tunnel))
                    }
                    .padding(.vertical, Space.s)
                }
                if let command = m.tunnelInstallCommand {
                    CopyCommandButton(command: command, l: m.l)
                        .padding(.horizontal, Space.xs)
                }
            }
        } else if !m.capabilities.tunnelAvailable {
            SettingsSection {
                Text(m.l.t("set_tunnel_none"))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, Space.s)
            }
        }
    }

    // MARK: - Notifications

    @ViewBuilder private var notifications: some View {
        SettingsSection(note: m.l.t("notify_note")) {
            SwitchRow(title: m.l.t("notify_tunnelDropped_setting"), isOn: $notifyTunnel)
            RowDivider()
            SwitchRow(title: m.l.t("notify_tunnelReconnected_setting"), isOn: $notifyReconnect)
            RowDivider()
            SwitchRow(title: m.l.t("notify_serverRemoved_setting"), isOn: $notifyServer)
            RowDivider()
            SwitchRow(title: m.l.t("notify_dpiStopped_setting"), isOn: $notifyDPI)
            RowDivider()
            SwitchRow(title: m.l.t("notify_networkSwitched_setting"), isOn: $notifyNetwork)
            RowDivider()
            SwitchRow(title: m.l.t("notify_helperUpdate_setting"), isOn: $notifyHelper)
        }
    }

    // MARK: - Updates

    @ViewBuilder private var updates: some View {
        SettingsSection(note: updater.available ? nil : m.l.t("set_updates_unavailable")) {
            if updater.available {
                SwitchRow(title: m.l.t("app_update_auto"), isOn: Binding(
                    get: { updater.automatic },
                    set: { updater.setAutomatic($0) }))
                RowDivider()
            }
            HStack {
                Text(m.l.t("about_version", ["v": AppVersion.short(from: Bundle.main.infoDictionary)]))
                    .foregroundStyle(Palette.secondary)
                Spacer()
                Button(m.l.t("app_update_check")) { updater.checkForUpdates() }
                    .disabled(!updater.available)
            }
            .padding(.vertical, Space.s)
        }
    }
}

// MARK: - Shortcut

extension SettingsView {
    /// Ready-made shortcuts, one click each. None of them is a common app
    /// shortcut: ⌘⇧D was left out because Finder and browsers use it.
    static let examples: [HotKeyCombo] = [
        HotKeyCombo(keyCode: 46, modifiers: HotKeyCombo.control | HotKeyCombo.option, key: "m"),
        HotKeyCombo(keyCode: 2, modifiers: HotKeyCombo.control | HotKeyCombo.option, key: "d"),
        HotKeyCombo(keyCode: 46, modifiers: HotKeyCombo.control | HotKeyCombo.option | HotKeyCombo.cmd, key: "m"),
    ].compactMap { $0 }

    @ViewBuilder var shortcut: some View {
        SettingsSection(note: m.l.t("hotkey_note")) {
            HStack(spacing: Space.s) {
                Text(recording ? m.l.t("hotkey_recording") : (m.hotKey?.display ?? m.l.t("hotkey_none")))
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(recording ? Palette.accent : Palette.text)
                    .accessibilityLabel(m.l.t("hotkey_title") + ": "
                                        + (m.hotKey?.display ?? m.l.t("hotkey_none")))
                Spacer()
                if recording {
                    Button(m.l.t("cancel_esc")) { stopRecording() }
                } else {
                    Button(m.l.t("hotkey_record")) { startRecording() }
                }
                if m.hotKey != nil && !recording {
                    Button(m.l.t("hotkey_clear")) { m.setHotKey(nil) }
                }
            }
            .padding(.vertical, Space.s)
            if let hint = shortcutHint {
                Label(hint, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, Space.s)
            }
        }
        SettingsSection(title: m.l.t("hotkey_examples"), note: m.l.t("hotkey_examples_note")) {
            HStack(spacing: Space.s) {
                ForEach(Self.examples, id: \.display) { combo in
                    let current = combo == m.hotKey
                    Button { pick(combo) } label: {
                        Text(combo.display)
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(current ? Palette.accentText : Palette.text)
                            .padding(.horizontal, Space.m)
                            .padding(.vertical, 6)
                            .background(current ? Palette.accent : Palette.raised)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    }
                    .buttonStyle(.pressable)
                    .accessibilityLabel(m.l.t("hotkey_use", ["what": combo.display]))
                    .accessibilityAddTraits(current ? [.isSelected, .isButton] : .isButton)
                }
                Spacer()
            }
            .padding(.vertical, Space.s)
        }
    }

    private var shortcutHint: String? {
        if needsModifier { return m.l.t("hotkey_needs_modifier") }
        return m.hotKeyRefused ? m.l.t("hotkey_taken") : nil
    }

    private func pick(_ combo: HotKeyCombo) {
        stopRecording()
        needsModifier = false
        m.setHotKey(combo)
    }

    /// Record a global shortcut. A local key monitor sees only keys pressed in
    /// this window while recording, so it needs no permission either.
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
}

// MARK: - Pieces

/// A titled card of rows with an optional note under it.
struct SettingsSection<Content: View>: View {
    var title: String?
    var note: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs + 2) {
            if let title {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.secondary)
                    .padding(.leading, Space.xs)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, Space.m)
                .padding(.vertical, Space.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(Card())
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.xs)
            }
        }
    }
}

/// Label on the left, switch on the right. The switch keeps the label for
/// VoiceOver.
struct SwitchRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: Space.m) {
            Text(title).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.m)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.vertical, Space.s)
    }
}

/// Label on the left, a menu picker on the right.
struct PickerRow<P: View>: View {
    let title: String
    @ViewBuilder let picker: P

    var body: some View {
        HStack(spacing: Space.m) {
            Text(title)
            Spacer(minLength: Space.m)
            picker
                .labelsHidden()
                .fixedSize()
        }
        .padding(.vertical, Space.s)
    }
}

struct RowDivider: View {
    var body: some View {
        Rectangle().fill(Palette.separator).frame(height: 1)
    }
}

/// Sets the hosting window's title, so the Settings window reads "Ayarlar"
/// in Turkish even while macOS itself runs in another language.
struct WindowTitle: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = view.window, window.title != title { window.title = title }
        }
    }
}
