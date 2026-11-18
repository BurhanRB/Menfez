// MenuLanguage.swift — the system parts of the menu bar follow the in-app
// language right away (1.0.9).
//
// macOS localises the app menu, Edit and Window from AppleLanguages at launch.
// Menfez keeps that value equal to its own language (`Model.syncMenuLanguage`),
// so after a relaunch everything matches. Until then, this retitles the
// standard items it knows, matched by action, not by title. It only runs when
// the in-app language differs from the one the menus were built in, so a
// normal launch keeps macOS's own wording. SwiftUI may rebuild a menu, so the
// titles are applied again each time the menu bar opens.

import AppKit
import MenfezCore

@MainActor
enum MenuLanguage {
    /// The language the menus were built in at launch.
    static let launchLang: Lang = Bundle.main.preferredLocalizations.first?.hasPrefix("tr") == true ? .tr : .en
    static var current: Lang?
    private static var observer: NSObjectProtocol?

    static func follow(_ lang: Lang) {
        current = lang
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
                MainActor.assumeIsolated {
                    if let menu = note.object as? NSMenu, menu === NSApp.mainMenu { apply() }
                }
            }
        }
        apply()
        #if DEBUG
        // Scratch runs: print the menu bar after it is built, to check titles.
        if ProcessInfo.processInfo.environment["MENFEZ_DEBUG_MENU"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                apply()
                for top in NSApp.mainMenu?.items ?? [] {
                    print("[\(top.title)]", (top.submenu?.items ?? []).map(\.title).filter { !$0.isEmpty })
                }
                exit(0)
            }
        }
        #endif
    }

    static func apply() {
        guard let lang = current, lang != launchLang, let main = NSApp.mainMenu else { return }
        let l = L(lang: lang)
        for top in main.items {
            guard let menu = top.submenu else { continue }
            if let key = topKey(menu) {
                top.title = l.t(key)
                menu.title = l.t(key)
            }
            for item in menu.items {
                if let key = itemKey(item) { item.title = l.t(key) }
            }
        }
    }

    private static func topKey(_ menu: NSMenu) -> String? {
        if menu === NSApp.windowsMenu { return "sysmenu_window" }
        if menu === NSApp.helpMenu { return "sysmenu_help" }
        let actions = Set(menu.items.compactMap { $0.action.map(NSStringFromSelector) })
        if actions.contains("copy:") { return "sysmenu_edit" }
        if actions.contains("toggleFullScreen:") || actions.contains("toggleToolbarShown:") { return "sysmenu_view" }
        if actions.contains("performClose:") { return "sysmenu_file" }
        // SwiftUI leaves an empty View menu; only its title tells it apart.
        if ["View", "Görüntü", "Görünüm"].contains(menu.title) { return "sysmenu_view" }
        return nil
    }

    private static func itemKey(_ item: NSMenuItem) -> String? {
        if item.submenu != nil, item.submenu === NSApp.servicesMenu { return "sysmenu_services" }
        guard let action = item.action else { return nil }
        switch NSStringFromSelector(action) {
        case "orderFrontStandardAboutPanel:": return "sysmenu_about"
        // SwiftUI's Settings item; the selector was renamed in macOS 13.
        case "showSettingsWindow:", "showPreferencesWindow:": return "sysmenu_settings"
        case "startDictation:": return "sysmenu_dictation"
        case "orderFrontCharacterPalette:": return "sysmenu_emoji"
        case "hide:": return "sysmenu_hide"
        case "hideOtherApplications:": return "sysmenu_hide_others"
        case "unhideAllApplications:": return "sysmenu_show_all"
        case "terminate:": return "sysmenu_quit"
        case "undo:": return "sysmenu_undo"
        case "redo:": return "sysmenu_redo"
        case "cut:": return "sysmenu_cut"
        case "copy:": return "sysmenu_copy"
        case "paste:": return "sysmenu_paste"
        case "pasteAsPlainText:", "pasteAndMatchStyle:": return "sysmenu_paste_plain"
        case "delete:": return "sysmenu_delete"
        case "selectAll:": return "sysmenu_select_all"
        case "performClose:": return "sysmenu_close"
        case "performMiniaturize:": return "sysmenu_minimize"
        case "performZoom:": return "sysmenu_zoom"
        case "arrangeInFront:": return "sysmenu_front"
        case "showHelp:": return "sysmenu_app_help"
        default: return nil
        }
    }
}
