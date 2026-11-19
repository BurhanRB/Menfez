import AppKit
import Sparkle
import MenfezCore

/// Sparkle, wired for this app (docs/SIGNING.md §1c).
///
/// Started only inside a real, Sparkle-configured bundle: a `swift run` binary
/// or a snapshot render has no `SUPublicEDKey`, and Sparkle would show an
/// "updater failed to start" alert there.
///
/// 1.0.11: one check at launch, a silent download (`SUAutomaticallyUpdate` in
/// Info.plist, gated by Sparkle on automatic checks), and a row in the main
/// window that installs the downloaded update with one click.
@MainActor
final class Updater: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = Updater()

    @Published private(set) var canCheck = false
    @Published private(set) var automatic = false
    /// A running, configured updater. Settable for the debug snapshots only.
    @Published var available = false
    /// The version Sparkle found, nil when there is none. Settable for the
    /// debug snapshots only.
    @Published var availableVersion: String?
    /// Downloaded and waiting for the quit. Settable for the snapshots only.
    @Published var readyToInstall = false
    @Published private(set) var installing = false

    /// Sparkle's "install and relaunch now" handler, once the update is downloaded.
    private var installNow: (() -> Void)?

    var banner: UpdateBanner {
        UpdateBanner(version: availableVersion, readyToInstall: readyToInstall, installing: installing)
    }

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
        // Test builds only: a fresh test bundle downloads with no clicks.
        if ProcessInfo.processInfo.environment["MENFEZ_TEST_FEED"] != nil {
            updater.automaticallyDownloadsUpdates = true
        }
        #endif
        // A check at every launch, only with automatic checks on. Sparkle's
        // docs ask for this call right after starting the updater so it cannot
        // clash with the scheduled check. It returns at once.
        if updater.automaticallyChecksForUpdates {
            updater.checkForUpdatesInBackground()
        }
    }

    /// When the last check started, so the debug log can say where a slow
    /// check spent its time (owner report, 1.0.8).
    nonisolated(unsafe) private static var checkStarted: Date?

    func checkForUpdates() {
        Self.checkStarted = Date()
        Model.trace("update check: started")
        controller?.checkForUpdates(nil)
    }

    /// The row's button: install and relaunch now if the download is ready,
    /// otherwise Sparkle's own window.
    func update() {
        switch banner {
        case .installNow:
            guard let installNow else { return checkForUpdates() }
            installing = true
            Model.trace("update: installing \(availableVersion ?? "?") now")
            installNow()
        case .openUpdater:
            checkForUpdates()
        case .hidden:
            break
        }
    }

    private nonisolated static func traceElapsed(_ what: String) {
        let ms = checkStarted.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
        Task { @MainActor in Model.trace("update check: \(what) after \(ms) ms") }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        Self.traceElapsed("appcast loaded")
    }

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

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        #if MENFEZ_UPDATE_TEST
        NSLog("MENFEZ_UPDATE_TEST: found %@", version)
        #endif
        Self.traceElapsed("found \(version)")
        Task { @MainActor in self.availableVersion = version }
    }

    /// Returning true keeps the update waiting for our row's button. Sparkle
    /// still installs it when the app quits.
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        nonisolated(unsafe) let block = immediateInstallationBlock
        Task { @MainActor in
            self.availableVersion = version
            self.installNow = block
            self.readyToInstall = true
            #if MENFEZ_UPDATE_TEST
            // Test builds only: press the row's button with no clicks.
            NSLog("MENFEZ_UPDATE_TEST: installing %@ now", version)
            self.update()
            #endif
        }
        return true
    }

    /// "Skip This Version" in Sparkle's window: the row goes too.
    nonisolated func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice,
                             forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        guard choice == .skip else { return }
        Task { @MainActor in
            self.availableVersion = nil
            self.readyToInstall = false
            self.installNow = nil
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        #if MENFEZ_UPDATE_TEST
        NSLog("MENFEZ_UPDATE_TEST: no update")
        #endif
        Self.traceElapsed("no update")
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        #if MENFEZ_UPDATE_TEST
        NSLog("MENFEZ_UPDATE_TEST: aborted: %@", String(describing: error))
        #endif
        Self.traceElapsed("aborted (\(error.localizedDescription))")
    }
}
