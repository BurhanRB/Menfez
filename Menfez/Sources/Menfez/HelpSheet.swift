// HelpSheet.swift — the "?" panel.
//
// WHY A SEPARATE FILE
// The main view is already large and three agents edit it. Keeping the help
// text here means the wording can change without touching layout code.
//
// WHAT IT HAS TO ANSWER NOW
// Written for someone who has never heard of DPI: what each mode does in one
// sentence, which one to try first, where the .conf comes from (Menfez ships
// no server), and what to do when Discord does not open. The sudoers command
// for the optional tunnel stays, selectable and copyable, but folded away.
// All text lives in the TR/EN table in MenfezApp.swift.

import SwiftUI
import MenfezCore

struct HelpSheet: View {
    let lang: Lang

    /// The helper path this build would run. Passed in so the command shown is
    /// the command that actually applies to this bundle, not a placeholder.
    var helperPath: String = ""

    /// Dismisses the panel through the router that presented it.
    ///
    /// WHY THIS REPLACED `NSApp.keyWindow?.sheetParent?.endSheet(...)`
    /// That call ends the AppKit sheet without telling the SwiftUI state, so the
    /// state kept saying "presented" and the next redraw presented the panel
    /// again — the "it opens again every time" report. A callback keeps the one
    /// owner of presentation in charge; this view does not know how it was shown.
    /// Opens the .conf picker; the tunnel needs the user's own server.
    /// The "Set up tunnel" button: runs the bundled installer through macOS's
    /// password dialog. nil outside a bundle, where only the command is shown.
    var installRunning = false
    var installMessage: String?
    var onInstall: (() -> Void)?
    /// The helper is installed: the row says so and offers removal instead.
    /// Settings has the same button, but Help is where users look for it.
    var installed = false
    var onRemove: (() -> Void)?
    /// Why removal is not possible now (Tunnel mode is on), or nil.
    var removeBlockedReason: String?

    var onImport: () -> Void = {}

    /// Saves a masked diagnostic file (`LogExport`) for a bug report.
    var onExportLog: () -> Void = {}

    var onClose: () -> Void = {}

    @State private var copied = false
    /// Not private, so a snapshot can render it open.
    @State var showSetup = false

    private var l: L { L(lang: lang) }

    // One column, no scrolling: four short answers a non-technical user asks
    // for, then the optional tunnel command folded away so it does not crowd them.
    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text(l.t("help_title"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.text)

            section(l.t("help_modes"),
                    [l.t("help_direct"), l.t("help_dpi"), l.t("help_tunnel")])
            section(l.t("help_which_title"), [l.t("help_which")])
            section(l.t("help_conf_title"), [l.t("help_conf")],
                    button: (l.t("import_conf"), onImport))
            section(l.t("help_discord_title"), [l.t("help_discord"), l.t("help_discord_wait")])

            tunnelSetup

            VStack(alignment: .leading, spacing: 6) {
                Text(l.t("help_log"))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(l.t("export_log")) { onExportLog() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.accent)
                    Spacer()
                    Button(l.t("close")) { onClose() }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .modifier(Chip())
                        .foregroundStyle(Palette.text)
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(.top, 2)
        }
        .padding(18)
        .frame(width: 440, alignment: .leading)
        .background(Palette.bg)
    }

    /// A card: a bold heading, one line per sentence, and an optional button.
    private func section(_ title: String, _ lines: [String],
                         button: (String, () -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.text)
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let button {
                Button(button.0, action: button.1)
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .modifier(Chip())
                    .foregroundStyle(Palette.accent)
                    .padding(.top, 2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    /// The one-time setup, as a command a user can copy.
    ///
    /// Shown only when there is a path to name. A build with no helper beside it
    /// (a `swift run` during development) has nothing to instruct, and printing
    /// a command that names a binary that does not exist would be worse than
    /// silence.
    @ViewBuilder
    private var tunnelSetup: some View {
        if !helperPath.isEmpty, let command = TunnelSetup.command(helper: helperPath) {
            DisclosureGroup(isExpanded: $showSetup) {
            VStack(alignment: .leading, spacing: 5) {
                Text(l.t("help_setup"))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let action = installed ? onRemove : onInstall {
                    HStack(spacing: 7) {
                        if installed {
                            Label(l.t("tunnel_installed"), systemImage: "checkmark.circle.fill")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Palette.success)
                        }
                        Button(action: action) {
                            HStack(spacing: 5) {
                                if installRunning { ProgressView().controlSize(.mini) }
                                Text(l.t(installed ? "tunnel_remove" : "tunnel_install"))
                            }
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .modifier(Chip())
                        .foregroundStyle(Palette.accent)
                        .disabled(installRunning || (installed && removeBlockedReason != nil))
                        if let note = installed ? removeBlockedReason ?? installMessage : installMessage {
                            Text(note)
                                .font(.system(size: 10.5))
                                .foregroundStyle(Palette.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text(l.t("help_setup_terminal"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.secondary)
                        .padding(.top, 2)
                }

                // Selectable, monospaced, wrapped: the user has to be able to
                // read every character of a command that edits sudoers before
                // pasting it. `textSelection(.enabled)` is why this is a Text
                // and not a Button.
                Text(command)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(Palette.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.raised)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                HStack(spacing: 7) {
                    Button {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(command,
                                             forType: .string)
                        copied = true
                    } label: {
                        Text(copied
                             ? l.t("copied")
                             : l.t("help_copy_command"))
                            .font(.system(size: 10.5))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(Palette.raised)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .foregroundStyle(copied ? Palette.success : Palette.accent)

                    Text(TunnelSetup.sudoersPath)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Palette.secondary)
                    Spacer()
                }
            }
            .padding(.top, 6)
            } label: {
                // The whole row toggles, not only the chevron.
                Button { withAnimation { showSetup.toggle() } } label: {
                    Text(l.t("help_setup_title"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
