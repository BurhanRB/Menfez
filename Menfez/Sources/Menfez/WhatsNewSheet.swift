// WhatsNewSheet.swift — the "What's new" panel opened from the header.
//
// An accordion, newest release first and open, in the language the toggle is set to. The
// text lives in `MenfezCore.Changelog` so a test can check it.

import SwiftUI
import MenfezCore

struct WhatsNewSheet: View {
    let lang: Lang
    /// Injectable so the DEBUG snapshot can show an older release too.
    let entries: [ChangelogEntry]
    let current: String
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The one open release; the newest when the sheet opens.
    @State private var open: String?

    init(lang: Lang, entries: [ChangelogEntry] = Changelog.entries,
         current: String = AppVersion.short(from: Bundle.main.infoDictionary),
         onClose: @escaping () -> Void) {
        self.lang = lang
        self.entries = entries
        self.current = current
        self.onClose = onClose
        _open = State(initialValue: entries.first?.version)
    }

    private var l: L { L(lang: lang) }

    /// "17 Kasım 2026" / "17 November 2026"; the raw value if it does not parse.
    private func date(_ iso: String) -> String {
        let parse = DateFormatter()
        parse.locale = Locale(identifier: "en_US_POSIX")
        parse.dateFormat = "yyyy-MM-dd"
        guard let d = parse.date(from: iso) else { return iso }
        let out = DateFormatter()
        out.locale = Locale(identifier: lang == .tr ? "tr_TR" : "en_GB")
        out.dateStyle = .long
        return out.string(from: d)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(l.t("whatsnew_hint"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.text)

            // Scrolls only when the open release is taller than the sheet allows.
            ViewThatFits(in: .vertical) {
                list
                ScrollView(.vertical) { list }
            }
            .frame(maxHeight: 440)
            .padding(.top, 12)

            HStack {
                Spacer()
                Button(l.t("close")) { onClose() }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .modifier(Chip())
                    .foregroundStyle(Palette.text)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.top, 16)
        }
        .padding(18)
        .frame(width: 380)
        .background(Palette.bg)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(entries, id: \.version) { e in
                let isOpen = open == e.version
                let isCurrent = e.version == current
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                            open = isOpen ? nil : e.version
                        }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .rotationEffect(.degrees(isOpen ? 90 : 0))
                                .foregroundStyle(Palette.secondary)
                            Text(l.t("whatsnew_version", ["v": e.version]))
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(isCurrent ? Palette.accent : Palette.text)
                            if isCurrent {
                                Text(l.t("whatsnew_current"))
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .foregroundStyle(Palette.accent)
                                    .overlay(Capsule().stroke(Palette.accent, lineWidth: 1))
                            }
                            Spacer(minLength: 8)
                            Text(date(e.date))
                                .font(.system(size: 10.5))
                                .foregroundStyle(Palette.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOpen ? .isSelected : [])

                    if isOpen {
                        ForEach(lang == .tr ? e.tr : e.en, id: \.self) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("•").foregroundStyle(Palette.secondary)
                                Text(item)
                                    .foregroundStyle(Palette.text)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.system(size: 11.5))
                        }
                    }
                }
                .padding(Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.card)
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            }
        }
    }
}
