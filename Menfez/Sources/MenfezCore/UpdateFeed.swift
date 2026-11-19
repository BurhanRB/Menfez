// UpdateFeed.swift — which Sparkle appcast this build reads.
//
// Two dmgs per release (arm64, intel thinned), so two appcasts: an update must
// never hand an Intel Mac the arm64 image or the other way round. The choice
// follows the architecture this binary was compiled for, not the machine: the
// Intel build running under Rosetta on Apple silicon stays on the Intel feed,
// which is the image that user installed.
//
// Hosting (docs/SIGNING.md §1c): plain files on the public repo's
// main branch. GitHub's releases/latest/download URL skips pre-releases, and
// every Menfez release so far is a pre-release.

public enum UpdateFeed {
    public static let base = "https://raw.githubusercontent.com/BurhanRB/Menfez/main/"

    public static func url(arm64: Bool) -> String {
        base + "appcast-" + (arm64 ? "arm64" : "intel") + ".xml"
    }

    /// The feed for the slice that is running.
    public static var current: String {
        #if arch(arm64)
        return url(arm64: true)
        #else
        return url(arm64: false)
        #endif
    }
}

/// The main window's "new version ready" row (1.0.11): hidden, or what its
/// button does. A downloaded update installs and relaunches at once. One that
/// is found but not downloaded yet opens Sparkle's own window instead.
public enum UpdateBanner: Equatable, Sendable {
    case hidden
    case installNow
    case openUpdater

    public init(version: String?, readyToInstall: Bool, installing: Bool) {
        if version == nil || installing { self = .hidden }
        else { self = readyToInstall ? .installNow : .openUpdater }
    }
}
