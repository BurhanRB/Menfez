// DebugLog.swift — opt-in diagnostic files under ~/Library/Logs/Menfez.
//
// The lines carry the egress IP and country, so they are written only when the
// user turns them on (`defaults write com.menfez.app debugLogging -bool true`),
// into a 0700 directory as 0600 files, opened with O_NOFOLLOW so a planted
// symlink cannot redirect the write, and capped by a one-step rotation.

import Foundation

public enum DebugLog {
    /// UserDefaults switch; off unless the user sets it, in every build.
    public static let defaultsKey = "debugLogging"
    /// Past this size the file is renamed to `<name>.1` (replacing the old one).
    public static let maxBytes = 1_000_000

    public static var directory: String {
        (Path.realHome as NSString).appendingPathComponent("Library/Logs/Menfez")
    }

    private static let queue = DispatchQueue(label: "menfez.debuglog")

    /// Append one line when logging is on. The write happens off the caller's
    /// thread, in order.
    public static func log(_ line: String, to name: String) {
        guard UserDefaults.standard.bool(forKey: defaultsKey) else { return }
        let stamped = "\(Date().timeIntervalSince1970) \(line)\n"
        queue.async { append(stamped, to: name, in: directory) }
    }

    /// Synchronous write; `log` is the entry point, this is the testable part.
    @discardableResult
    static func append(_ text: String, to name: String, in dir: String,
                       maxBytes: Int = maxBytes) -> Bool {
        guard Path.ensureDir(dir, mode: 0o700) else { return false }
        let path = (dir as NSString).appendingPathComponent(name)
        var info = stat()
        if lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
           info.st_size > maxBytes {
            // rename() replaces a link named `.1` instead of following it.
            rename(path, path + ".1")
        }
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        // A file left by an older build may be wider than 0600.
        fchmod(fd, 0o600)
        let bytes = Array(text.utf8)
        return write(fd, bytes, bytes.count) == bytes.count
    }
}
