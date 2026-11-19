// AboutSheet.swift — the "i" panel.
//
// WHY A SEPARATE FILE
// Same reason as HelpSheet: the wording is the kind of thing that changes after
// a release, and the main view should not have to be reopened to change it.
//
// WHAT IT SHOWS
// Name, version, one line on what the app is for, the links and the licence,
// all in the language the toggle is set to. Nothing else: this panel is for
// someone checking which build they have or where to report a problem.
//
// WHY THE LINKS ARE OPTIONAL
// `URL(string:)` cannot be forced here: a later edit that adds a space or a
// Turkish character to a link would crash the app on launch rather than break
// one link. Both are built from ASCII-only literals, so today they cannot fail
// — that is a claim about these strings, not about the type, so the UI keeps a
// plain-text fallback for the day someone edits one of them.

import SwiftUI
import AppKit
import MenfezCore

struct AboutSheet: View {
    let lang: Lang
    let onClose: () -> Void

    private var l: L { L(lang: lang) }

    /// `CFBundleShortVersionString`, with "1.0" when the build has no plist
    /// (`swift run`) or an empty value. See `AppVersion`.
    private var version: String {
        AppVersion.short(from: Bundle.main.infoDictionary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(l.t("app"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.text)
                Spacer(minLength: 8)
                Text(l.t("about_version", ["v": version]))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Palette.secondary)
            }

            Text(l.t("tagline"))
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 7) {
                fact(l.t("about_author"), Text("BurhanRB"))
                fact("GitHub", link(Links.github, label: Links.githubLabel))
                fact(l.t("about_web"), link(Links.web, label: Links.webLabel))
                fact(l.t("about_support"), link(Links.support, label: Links.supportLabel))
            }
            .padding(Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card)
            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .padding(.top, 14)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(l.t("about_license"))
                    .foregroundStyle(Palette.secondary)
                // Sparkle's MIT text, copied into the bundle by build-app.sh.
                Button(l.t("about_licenses")) {
                    if let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.pressable)
                .foregroundStyle(Palette.accent)
            }
            .font(.system(size: 11))
            .padding(.top, 10)

            HStack {
                if Updater.shared.available {
                    Button(l.t("app_update_check")) { Updater.shared.checkForUpdates() }
                        .buttonStyle(.secondary(h: 12, v: 4))
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.text)
                        .disabled(!Updater.shared.canCheck)
                }
                Spacer()
                Button(l.t("close")) { onClose() }
                    .buttonStyle(.secondary(h: 12, v: 4))
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.text)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.top, 16)
        }
        .padding(18)
        .frame(width: 360)
        .background(Palette.bg)
    }

    /// One label/value line. The label column is fixed so the values start
    /// on the same x, which is the only typographic rule this panel needs.
    private func fact<Value: View>(_ label: String, _ value: Value) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Palette.secondary)
                .frame(width: 84, alignment: .leading)
            value
                .font(.system(size: 11))
            Spacer(minLength: 0)
        }
    }

    /// A clickable address, or plain text when the URL failed to parse.
    ///
    /// `Link` and `openURL` both hand the URL to LaunchServices, which opens the
    /// user's default browser. There is no in-app browser here on purpose: the
    /// pages are documentation, not part of the app.
    @ViewBuilder
    private func link(_ url: URL?, label: String) -> some View {
        if let url {
            Link(destination: url) {
                Text(label)
                    .foregroundStyle(Palette.accent)
                    .underline(false)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .help(url.absoluteString)
        } else {
            // A broken link should read as text, not as a dead button that
            // looks clickable and does nothing.
            Text(label).foregroundStyle(Palette.secondary)
        }
    }
}
