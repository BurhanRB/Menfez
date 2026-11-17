// Paths.swift — every filesystem location the app touches, in one place.
//
// The privileged helper runs as root while the UI runs as the user, so a path
// that is computed differently in the two processes is a bug waiting to
// happen. Anything that needs a home directory resolves it through
// `Path.realHome`, which asks the password database rather than trusting
// $HOME: under sudo, $HOME is root's unless sudo -H was used.

import Foundation

public enum Path {
    /// The invoking user's home, even when running as root.
    ///
    /// `SUDO_USER` is set by sudo and looked up in the passwd database. Never
    /// uses $HOME directly when euid == 0, because sudo usually leaves it as
    /// root's.
    ///
    /// As root without a `SUDO_USER` there is no user to resolve. Falling back
    /// to /var/root made root read and write a profile tree nobody uses, so the
    /// answer is `noHome`, which can never be created: `/` is the read-only
    /// system volume. Every lookup under it fails instead of quietly
    /// succeeding in the wrong place.
    public static var realHome: String {
        realHome(euid: geteuid(), sudoUser: ProcessInfo.processInfo.environment["SUDO_USER"])
    }

    /// passwd's own "no home directory" value.
    public static let noHome = "/nonexistent"

    static func realHome(euid: uid_t, sudoUser: String?) -> String {
        if euid != 0 {
            return NSHomeDirectory()
        }
        if let user = sudoUser, !user.isEmpty, user != "root",
           let pw = getpwnam(user) {
            return String(cString: pw.pointee.pw_dir)
        }
        return noHome
    }

    /// ~/Library/Application Support/Menfez
    public static var support: String {
        (realHome as NSString).appendingPathComponent(
            "Library/Application Support/Menfez")
    }

    /// Where the user's WireGuard `.conf` files live (mode 0700).
    public static var profiles: String {
        (support as NSString).appendingPathComponent("wireguard")
    }

    /// The single generated config wg-quick is pointed at. Rewritten on every
    /// server switch so the user's own files are never modified.
    ///
    /// Root writes it, so it lives in a root-owned 0700 directory: in the
    /// user-writable profile directory a planted symlink named
    /// `wgmanaged.conf` redirected root's write to any file on the system.
    public static var managedConfig: String {
        (stateDir as NSString).appendingPathComponent("wireguard/wgmanaged.conf")
    }

    /// Program filter list, shared with the DPI engine.
    public static var programFilters: String {
        (support as NSString).appendingPathComponent("ProgramFilters")
    }

    /// UI preferences (language, last chosen server).
    public static var uiPrefs: String {
        (support as NSString).appendingPathComponent("ui.json")
    }

    /// Where the privileged helper and its WireGuard toolchain live once
    /// installed: root:wheel 0755 all the way down, so the user the sudoers rule
    /// is granted to cannot replace anything root will execute.
    public static let trustedHelperDir = "/Library/PrivilegedHelperTools/menfez"
    public static let trustedHelper = trustedHelperDir + "/menfez-route"
    /// Root-owned copies of wg, wg-quick, wireguard-go and bash (>= 4).
    public static let trustedBin = trustedHelperDir + "/bin"

    /// Runtime state, root-owned: which routes this app added.
    public static let stateDir = "/var/run/menfez"
    public static var routeState: String {
        (stateDir as NSString).appendingPathComponent("route-state.json")
    }
    /// Root-owned (0700) and persistent. The DNS record cannot live in
    /// /var/run: networksetup's change survives a reboot, so the original it
    /// replaced must survive one too, or `auto` after a restart restores DHCP
    /// instead of the user's static resolvers.
    public static let systemSupport = "/Library/Application Support/Menfez"
    public static var dnsState: String {
        (systemSupport as NSString).appendingPathComponent("dns-state.json")
    }
    /// Where releases up to 1.0.1 kept it; read once as a migration source.
    public static var legacyDNSState: String {
        (stateDir as NSString).appendingPathComponent("dns-state.json")
    }

    /// Create a directory with the given mode, and repair the mode of an
    /// existing one.
    ///
    /// Returning `true` for an existing directory without touching its mode is
    /// how the profile directory could be 0755 while the app believed it had
    /// created it as 0700: the 0600 key files were then listed by every local
    /// user. The mode is therefore applied on both paths, and a directory that
    /// is a symlink is refused outright — a link named `wireguard` pointing
    /// somewhere else would otherwise make `chmod` and the subsequent writes
    /// land outside the app's own tree.
    @discardableResult
    public static func ensureDir(_ path: String, mode: mode_t = 0o700) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            var info = stat()
            guard lstat(path, &info) == 0 else { return false }
            guard (info.st_mode & S_IFMT) == S_IFDIR else { return false }
            return applyMode(path, mode: mode)
        }
        do {
            try fm.createDirectory(atPath: path,
                                   withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: NSNumber(value: mode)])
        } catch {
            return false
        }
        // `createDirectory` with intermediate directories applies the
        // attributes to the leaf on this platform, but that is not something to
        // rely on: the mode is what makes the directory safe, so it is set
        // explicitly and its failure is reported.
        return applyMode(path, mode: mode)
    }

    /// Set `mode` on `path`, tolerating an already-correct value.
    private static func applyMode(_ path: String, mode: mode_t) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        if (info.st_mode & 0o777) == mode { return true }
        return chmod(path, mode) == 0
    }
}
