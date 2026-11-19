// Theme.swift — the app's semantic colour tokens and spacing scale.
//
// Every colour resolves twice: a neutral graphite set for dark, and a cool
// ice-white ("buz beyazı") set for light. The warm off-white read as beige, so
// light is now a clean near-white with a faint cool tint: the background is
// #F2F4F5 (not paper white, so it does not glare) and cards sit one step
// lighter. Views name the role ("secondary", "danger"), never a hex value, so
// the appearance setting can flip the whole window without a view knowing.
//
// Contrast (WCAG, against bg / card / raised):
//   dark  text 15.2 / 14.1   secondary 7.1 / 6.6   accent text on accent 6.7
//   light text 14.4 / 15.3 / 13.1   secondary 6.8 / 7.2 / 6.2
//         accent 6.7 / 7.1 / 6.1    success 6.3 / 6.7 / 5.7
//         warning 6.3 / 6.7 / 5.7   danger 6.1 / 6.5 / 5.6
//         accent text on accent 7.1, CTA subtitle (85% opacity) 5.6

import SwiftUI
import AppKit

enum Palette {
    static let bg         = dynamic(dark: 0x111315, light: 0xF2F4F5)
    static let card       = dynamic(dark: 0x181B1E, light: 0xFAFBFB)
    static let raised     = dynamic(dark: 0x202428, light: 0xE6EAEC)
    static let separator  = dynamic(dark: 0x2A2F34, light: 0xD8DDE0)
    static let text       = dynamic(dark: 0xE6E8EA, light: 0x1E2326)
    static let secondary  = dynamic(dark: 0x9AA1A8, light: 0x4E565C)
    static let accent     = dynamic(dark: 0x4FB394, light: 0x17614F)
    static let accentText = dynamic(dark: 0x0D1F19, light: 0xFAFBFB)
    static let success    = dynamic(dark: 0x5CC08F, light: 0x21663F)
    static let warning    = dynamic(dark: 0xE0B04F, light: 0x7A520B)
    static let danger     = dynamic(dark: 0xE2716B, light: 0x9E3A33)
    /// The selected segment's pill: accent at 15 % on card (dark), 22 % (light),
    /// so the choice is plain in light too. Accent text on it: 5.0 light.
    static let selection  = dynamic(dark: 0x20322F, light: 0xC8D9D5)

    /// One colour per appearance, picked by AppKit when it draws.
    private static func dynamic(dark: UInt32, light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

/// Spacing scale. Everything in the window is a multiple of these.
enum Space {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
}

/// Corner radii: cards and large controls, then small buttons and chips.
enum Radius {
    static let card: CGFloat = 12
    static let control: CGFloat = 8
}

/// One way to move. Every layout change (mode switch, rows coming and going,
/// the selection pill) uses `layout`, hover and press use `feedback`.
/// Under Reduce Motion layout changes are instant, and feedback stays a
/// short fade, which is not motion.
enum Animate {
    static let spring = Animation.spring(response: 0.3, dampingFraction: 0.86)
    static let feedback = Animation.easeOut(duration: 0.12)

    static func layout(_ reduceMotion: Bool) -> Animation? { reduceMotion ? nil : spring }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

/// The window's appearance: follow macOS, or force dark or light.
///
/// Stored in UserDefaults under `appearance` as the raw value. `system` is
/// the default and maps to nil, which hands the decision back to macOS.
enum Appearance: String, CaseIterable {
    case system, dark, light

    static let key = "appearance"

    var scheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark:   return .dark
        case .light:  return .light
        }
    }

    /// For `NSApp.appearance`, so the title bar and sheets match the content.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .dark:   return NSAppearance(named: .darkAqua)
        case .light:  return NSAppearance(named: .aqua)
        }
    }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .dark:   return "moon"
        case .light:  return "sun.max"
        }
    }

    /// The header button cycles system, dark, light.
    var next: Appearance {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// Window geometry: one fixed-width column, height from the content.
enum PageLayout {
    /// The whole window's width; the column inside is this minus 2 x 24 pt.
    static let windowWidth: CGFloat = 528
}
