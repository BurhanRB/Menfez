// Notifier.swift — posts the few notifications `NotificationPolicy` allows.
//
// Text is generic on purpose: it shows on the lock screen, so no server name
// (a file name the user chose), address or network name goes in it.

import AppKit
import UserNotifications
import MenfezCore

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private var policy = NotificationPolicy()
    /// Opens the main window; set by the window itself so a click can bring it
    /// back after it was closed.
    var openMain: (() -> Void)?

    /// `UNUserNotificationCenter` traps outside an app bundle (`swift run`,
    /// snapshots), so nothing here runs there.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func start() {
        center?.delegate = self
    }

    /// Asks once; later calls are no-ops in macOS itself. Called when the
    /// guide ends, or at the first event for users who never saw the guide.
    func requestPermission() {
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ event: NotificationEvent, lang: Lang) {
        guard let center,
              policy.shouldSend(event, appActive: NSApp.isActive, enabled: event.isEnabled()) else { return }
        let l = L(lang: lang)
        let content = UNMutableNotificationContent()
        content.title = l.t("notify_" + event.rawValue + "_title")
        content.body = l.t("notify_" + event.rawValue + "_body")
        let request = UNNotificationRequest(identifier: event.rawValue, content: content, trigger: nil)
        center.getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { center.add(request) }
                }
            } else {
                // Denied is fine: `add` does nothing and nothing else depends on it.
                center.add(request)
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            if let open = self.openMain { open() }
            completionHandler()
        }
    }
}
