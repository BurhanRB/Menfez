// Lock.swift — one writer at a time.
//
// Every mutating command is a read-modify-write of the route state file with a
// multi-second settle inside it. Without exclusion, this interleaving corrupts
// the state permanently:
//
//   A: up --mode discord   adds the pin + 162.159.128.0/18, starts its settle
//   B: up --mode all       adds 0.0.0.0/1 + 128.0.0.0/1, saves {all, [...]}
//   A: wakes, saves {discord, [162.159.128.0/18]}
//
// The /1 routes are installed and unrecorded, so `down` cannot see them and the
// machine stays black-holed. The UI's own `busy` flag only serialises one app
// process; the CLI, a stale --revert-after timer, and a second app instance are
// all outside its reach.
//
// flock is used rather than a PID file because the kernel releases it when the
// process dies, including on SIGKILL, so a crash cannot leave a stale lock.

import Foundation

/// An exclusive advisory lock held for the lifetime of the value.
public final class FileLock {
    /// `-1` until a descriptor is acquired.
    ///
    /// This was `let`, which made the failable initialiser illegal: Swift traps
    /// when a class init assigns a `let` stored property and then returns nil
    /// ("return from initializer without initializing all stored properties" is
    /// a compile error for `var`, and a runtime trap for the partially
    /// initialised `let`). That trap is the SIGTRAP every mutating command was
    /// dying on. `-1` is the "not open" sentinel so the failure paths can return
    /// nil safely.
    private var fd: Int32 = -1
    private let path: String
    public private(set) var acquired: Bool

    /// Try to take the lock without blocking.
    ///
    /// Returns nil when another process holds it; the caller reports "another
    /// menfez-route is running" rather than waiting, because every mutating
    /// command is short and waiting behind a wedged one is worse than failing.
    public init?(path: String) {
        self.path = path
        Path.ensureDir((path as NSString).deletingLastPathComponent, mode: 0o755)
        let handle = open(path, O_CREAT | O_RDWR, 0o644)
        guard handle >= 0 else { return nil }

        // Probe the lock on the local descriptor BEFORE publishing it to the
        // instance. flock has to run on the real descriptor, so this is the
        // earliest point at which "do we hold it" is knowable.
        let held = flock(handle, LOCK_EX | LOCK_NB) == 0
        guard held else {
            close(handle)
            return nil
        }

        fd = handle
        acquired = true
    }

    /// The process holding the lock, for the error message — only if it is
    /// still alive.
    ///
    /// The file contents are advisory. `flock` is released by the kernel when a
    /// process dies, but the pid written into the file stays there, so reading
    /// it blindly names a dead process and makes a free lock look busy. The
    /// `kill(pid, 0)` check distinguishes the two.
    public static func holder(at path: String) -> String {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return ""
        }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Format written by `stamp`: "pid <n> <command>".
        let parts = line.split(separator: " ")
        if parts.count >= 2, parts[0] == "pid", let pid = pid_t(parts[1]) {
            if kill(pid, 0) != 0 { return "" }   // ESRCH: process is gone
        }
        return line
    }

    /// Record who holds the lock so the next caller can name the holder.
    public func stamp(_ text: String) {
        guard acquired, fd >= 0 else { return }
        ftruncate(fd, 0)
        _ = lseek(fd, 0, SEEK_SET)
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
    }

    public func release() {
        guard acquired, fd >= 0 else { return }
        flock(fd, LOCK_UN)
        acquired = false
        close(fd)
        fd = -1
    }

    deinit { release() }
}

/// Why a lock could not be taken. A dedicated type rather than a bare String
/// so the CLI cannot accidentally print it as a success payload.
public struct LockBusy: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

public enum Locking {
    /// Path of the single lock that guards all routing mutations.
    public static var routeLockPath: String {
        (Path.stateDir as NSString).appendingPathComponent("route.lock")
    }

    /// Take the routing lock or explain who holds it.
    ///
    /// `path` is injectable so a test can exercise the acquire/release cycle in
    /// a directory it owns. Production never passes it.
    public static func acquireRouteLock(path: String = routeLockPath)
        -> Result<FileLock, LockBusy> {
        guard let lock = FileLock(path: path) else {
            let holder = FileLock.holder(at: path)
            let who = holder.isEmpty ? "" : " (held by \(holder))"
            return .failure(LockBusy(
                message: "another menfez-route command is running\(who); try again in a moment"))
        }
        let me = "pid \(getpid()) \(CommandLine.arguments.dropFirst().first ?? "")"
        lock.stamp(me.trimmingCharacters(in: .whitespaces))
        return .success(lock)
    }
}
