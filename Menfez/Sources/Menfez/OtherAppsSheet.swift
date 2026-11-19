// OtherAppsSheet.swift — "Other apps" in DPI mode (1.0.8, feature 7).
// The list and its rules are `AppLauncher`; this shows them and runs the one
// action the user clicks. Menfez never edits another app's settings: for
// `.manual` apps it only shows (and copies) the address.

import SwiftUI
import AppKit
import MenfezCore

extension Model {

    func appInstalled(_ app: AppLauncher.App) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) != nil
    }

    func appRunning(_ app: AppLauncher.App) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty
    }

    /// "Open with Menfez". A running app is quit first (the flag is read only
    /// at launch); the sheet asks before calling this with `relaunch: true`.
    func openWithMenfez(_ app: AppLauncher.App, relaunch: Bool) {
        guard let args = AppLauncher.arguments(for: app, port: dpi.running ? dpi.port : nil) else {
            status = l.t("apps_need_dpi")
            statusColor = Palette.warning
            return
        }
        Task {
            if relaunch {
                for running in NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID) {
                    running.terminate()
                    for _ in 0..<50 where !running.isTerminated {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                    // Not forced: an app that will not quit may be asking to
                    // save something. The user quits it and tries again.
                    if !running.isTerminated {
                        status = l.t("apps_still_running", ["what": app.name])
                        statusColor = Palette.warning
                        return
                    }
                }
            }
            let result = await Task.detached(priority: .userInitiated) {
                SystemRunner().run("open", args, timeout: 15)
            }.value
            if result.ok {
                status = l.t("apps_opened", ["what": app.name])
                statusColor = Palette.success
            } else {
                status = l.t("launch_openFailed", ["what": result.tail(1)])
                statusColor = Palette.danger
            }
        }
    }

    /// After leaving DPI mode: name the apps still pointed at the closed proxy.
    func noteFlaggedApps(port: Int?) {
        Task {
            let ps = await Task.detached(priority: .utility) {
                SystemRunner().run("ps", ["-axo", "pid=,args="], timeout: 5).output
            }.value
            let names = AppLauncher.flaggedPIDs(psOutput: ps, port: port).compactMap {
                NSRunningApplication(processIdentifier: $0)?.localizedName
            }
            guard !names.isEmpty else { return }
            status += " · " + l.t("apps_restart_note", ["what": names.joined(separator: ", ")])
            statusColor = Palette.warning
        }
    }
}

struct OtherAppsSheet: View {
    @ObservedObject var m: Model
    var onClose: () -> Void = {}

    @State private var confirm: AppLauncher.App?
    @State private var copied = false

    private var port: Int? { m.dpi.running ? m.dpi.port : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text(m.l.t("apps_title"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.text)
            Text(m.l.t("apps_intro"))
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(AppLauncher.catalog.enumerated()), id: \.element.id) { index, app in
                    if index > 0 { Divider().opacity(0.5) }
                    row(app)
                }
            }
            .background(Palette.card)
            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))

            if let port {
                HStack(spacing: Space.s) {
                    Text(m.l.t("apps_address", ["what": AppLauncher.address(port: port)]))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.text)
                        .textSelection(.enabled)
                    Spacer(minLength: 4)
                    chip(m.l.t(copied ? "apps_copied" : "apps_copy")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(AppLauncher.address(port: port), forType: .string)
                        copied = true
                    }
                }
            }
            ForEach(["apps_note_manual", "apps_note_udp", "apps_note_leave"], id: \.self) { key in
                Text(m.l.t(key))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(m.l.t("close")) { onClose() }
                    .buttonStyle(.secondary(h: 12, v: 4))
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.text)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 420, alignment: .leading)
        .background(Palette.bg)
        .alert(m.l.t("apps_relaunch_title", ["what": confirm?.name ?? ""]),
               isPresented: Binding(get: { confirm != nil },
                                    set: { if !$0 { DispatchQueue.main.async { confirm = nil } } })) {
            Button(m.l.t("apps_relaunch_yes")) {
                if let app = confirm { m.openWithMenfez(app, relaunch: true) }
            }
            Button(m.l.t("discord_restart_no"), role: .cancel) {}
        } message: {
            Text(m.l.t("apps_relaunch_body", ["what": confirm?.name ?? ""]))
        }
    }

    @ViewBuilder
    private func row(_ app: AppLauncher.App) -> some View {
        let installed = m.appInstalled(app)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.text)
                Text(m.l.t(installed ? "apps_route_" + app.route.rawValue : "apps_not_installed"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            if installed && app.route == .flag {
                chip(m.l.t("apps_open")) {
                    if m.appRunning(app) { confirm = app } else { m.openWithMenfez(app, relaunch: false) }
                }
                .disabled(port == nil)
                .accessibilityLabel(m.l.t("apps_open") + ": " + app.name)
            }
        }
        .opacity(installed ? 1 : 0.55)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, Space.s + 2)
                .padding(.vertical, Space.xs + 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.secondary)
        .foregroundStyle(Palette.accent)
        .fixedSize()
    }
}
