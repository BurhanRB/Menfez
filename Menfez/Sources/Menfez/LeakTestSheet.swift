// LeakTestSheet.swift — "Leak test": is the tunnel really carrying everything?
//
// The work is `LeakTest` in the core; this shows one row per check with a
// word next to the colour, and the WebRTC note. Nothing is saved.

import SwiftUI
import MenfezCore

struct LeakTestSheet: View {
    let lang: Lang
    /// Runs the checks off the main thread (`Model.runLeakTest`).
    var onRun: () async -> [LeakTest.Line] = { [] }
    var onClose: () -> Void = {}

    /// Not private, so a snapshot can render a finished test.
    @State var lines: [LeakTest.Line]?
    @State private var running = false

    private var l: L { L(lang: lang) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text(l.t("leak_title"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.text)
            Text(l.t("leak_intro"))
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if running {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(l.t("leak_running"))
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondary)
                }
            } else if let lines {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(lines, id: \.row) { line in row(line) }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.card)
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            }

            Text(l.t("leak_webrtc"))
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button(l.t("leak_again")) { run() }
                    .buttonStyle(.pressable)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .modifier(Chip())
                    .foregroundStyle(Palette.accent)
                    .disabled(running)
                Spacer()
                Button(l.t("close")) { onClose() }
                    .buttonStyle(.pressable)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .modifier(Chip())
                    .foregroundStyle(Palette.text)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 420, alignment: .leading)
        .background(Palette.bg)
        .onAppear { if lines == nil { run() } }
    }

    private func row(_ line: LeakTest.Line) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(l.t("leak_row_" + line.row.rawValue))
                .font(.system(size: 12))
                .foregroundStyle(Palette.text)
                .frame(width: 104, alignment: .leading)
            Image(systemName: symbol(line.level))
                .foregroundStyle(color(line.level))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(l.t("leak_" + line.key))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(color(line.level))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = line.detail {
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Palette.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func symbol(_ level: LeakTest.Level) -> String {
        switch level {
        case .ok: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .bad: return "xmark.circle.fill"
        }
    }

    private func color(_ level: LeakTest.Level) -> Color {
        switch level {
        case .ok: return Palette.success
        case .warn: return Palette.warning
        case .bad: return Palette.danger
        }
    }

    private func run() {
        guard !running else { return }
        running = true
        Task {
            lines = await onRun()
            running = false
        }
    }
}
