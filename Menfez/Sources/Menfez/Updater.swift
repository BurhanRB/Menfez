import AppKit
import Sparkle
import MenfezCore

/// Sparkle, wired for this app (docs/SIGNING.md §1c).
///
/// Started only inside a real, Sparkle-configured bundle: a `swift run` binary
/// or a snapshot render has no `SUPublicEDKey`, and Sparkle would show an
/// "updater failed to start" alert there.
@MainActor
final class Updater: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = Updater()

    @Published private(set) var canCheck = false
    @Published private(set) var automatic = false
    /// A running, configured updater. Settable for the debug snapshots only.
    @Published var available = false

    private var controller: SPUStandardUpdaterController?
    private var observations: [NSKeyValueObservation] = []

    private override init() {
        super.init()
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true,
                                                      updaterDelegate: self,
                                                      userDriverDelegate: nil)
        self.controller = controller
        available = true
        let updater = controller.updater
        canCheck = updater.canCheckForUpdates
        automatic = updater.automaticallyChecksForUpdates
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] u, _ in
                Task { @MainActor in self?.canCheck = u.canCheckForUpdates }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] u, _ in
                Task { @MainActor in self?.automatic = u.automaticallyChecksForUpdates }
            },
        ]
        #if MENFEZ_UPDATE_TEST
        // Test builds only: check, download and install with no clicks.
        if ProcessInfo.processInfo.environment["MENFEZ_TEST_FEED"] != nil {
            updater.automaticallyDownloadsUpdates = true
            updater.checkForUpdatesInBackground()
        }
        #endif
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    func setAutomatic(_ on: Bool) {
        controller?.updater.automaticallyChecksForUpdates = on
        automatic = on
    }

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        #if MENFEZ_UPDATE_TEST
        // Test builds only (never shipped): point at a local appcast.
        if let url = ProcessInfo.processInfo.environment["MENFEZ_TEST_FEED"] { return url }
        #endif
        return UpdateFeed.current
    }

    #if MENFEZ_UPDATE_TEST
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock: @escaping () -> Void) -> Bool {
        NSLog("MENFEZ_UPDATE_TEST: installing %@ now", item.displayVersionString)
        immediateInstallationBlock()
        return true
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        NSLog("MENFEZ_UPDATE_TEST: aborted: %@", String(describing: error))
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        NSLog("MENFEZ_UPDATE_TEST: found %@", item.displayVersionString)
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        NSLog("MENFEZ_UPDATE_TEST: no update")
    }
    #endif
}
