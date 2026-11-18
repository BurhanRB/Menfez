// OnboardingSheet.swift — the first-run guide: three short pages.
//
// 1. What DPI is and what Menfez does about it (no server, no account).
// 2. The tunnel, for people with their own server; Menfez ships none.
//    "Set up tunnel" shows only when it is the next step.
// 3. Ready: Open Discord (DPI on, then Discord), where the site test is, why notifications are asked.
// Every page can be skipped. Whether it shows at all is `Onboarding`.

import SwiftUI
import MenfezCore

struct OnboardingSheet: View {
    let lang: Lang
    /// The helper is not installed and this bundle can install it.
    var showTunnelSetup = false
    var installRunning = false
    var installMessage: String?
    var onInstall: () -> Void = {}
    var onStartDPI: () -> Void = {}
    var onDone: () -> Void = {}
    var onSkip: () -> Void = {}

    /// Not private, so a snapshot can render each page.
    @State var page = 0
    private let pages = 3

    private var l: L { L(lang: lang) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text(l.t("onb\(page + 1)_title"))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Palette.text)
                .accessibilityAddTraits(.isHeader)

            ForEach(1...3, id: \.self) { n in
                Text(l.t("onb\(page + 1)_\(n)"))
                    .font(.system(size: 12.5))
                    .foregroundStyle(n == 3 ? Palette.text : Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if page == 1, showTunnelSetup {
                HStack(spacing: 8) {
                    Button(action: onInstall) {
                        HStack(spacing: 5) {
                            if installRunning { ProgressView().controlSize(.mini) }
                            Text(l.t("tunnel_install"))
                        }
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                    .modifier(Chip())
                    .foregroundStyle(Palette.accent)
                    .disabled(installRunning)
                    if let installMessage {
                        Text(installMessage)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                if page < pages - 1 {
                    Button(l.t("onb_skip"), action: onSkip)
                        .buttonStyle(.pressable)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondary)
                        .keyboardShortcut(.cancelAction)
                }
                Spacer()
                Text("\(page + 1) / \(pages)")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondary)
                    .accessibilityLabel(l.t("onb_step", ["n": "\(page + 1)", "of": "\(pages)"]))
                if page > 0 {
                    chip(l.t("onb_back")) { page -= 1 }
                }
                if page < pages - 1 {
                    primary(l.t("onb_next")) { page += 1 }
                } else {
                    chip(l.t("onb_done"), action: onDone)
                        .keyboardShortcut(.cancelAction)
                    primary(l.t("dpi_enable_discord"), action: onStartDPI)
                }
            }
        }
        .padding(22)
        .frame(width: 440, height: 300, alignment: .topLeading)
        .background(Palette.bg)
    }

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.pressable)
            .font(.system(size: 12))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .modifier(Chip())
            .foregroundStyle(Palette.text)
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 14).padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .background(Palette.accent)
        .foregroundStyle(Palette.accentText)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .keyboardShortcut(.defaultAction)
    }
}
