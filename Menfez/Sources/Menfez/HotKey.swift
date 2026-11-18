// HotKey.swift — one global shortcut through Carbon's RegisterEventHotKey.
//
// Chosen over `NSEvent.addGlobalMonitorForEvents` because that one needs
// Accessibility permission and sees every key press; this one asks for
// nothing and is told only about its own combination. If Carbon hot keys are
// ever removed, the shortcut row hides (`register` fails) and the menu and
// window still switch modes.

import Carbon
import MenfezCore

@MainActor
final class HotKey {
    static let shared = HotKey()

    /// Runs on the main thread when the combination is pressed.
    var action: () -> Void = {}

    private var ref: EventHotKeyRef?
    private var handlerInstalled = false

    /// Replace the registered combination; nil only unregisters. False when
    /// macOS refused it (usually: another app already owns it).
    @discardableResult
    func register(_ combo: HotKeyCombo?) -> Bool {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        guard let combo else { return true }
        installHandler()
        let id = EventHotKeyID(signature: OSType(0x4D4E_465A), id: 1) // "MNFZ"
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id,
                                         GetApplicationEventTarget(), 0, &newRef)
        guard status == noErr else { return false }
        ref = newRef
        return true
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        // A C callback: no captures, so it reaches the action through `shared`.
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKey.shared.action() } }
            return noErr
        }, 1, &spec, nil, nil)
        handlerInstalled = status == noErr
    }
}
