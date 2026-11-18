// Shell.swift — one place that starts a process, with a timeout.
//
// Every external command in Menfez goes through this type. The rules it
// enforces are the ones that mattered in the Python prototype and would
// silently rot if each call site rolled its own:
//
//   * a list of arguments, never a shell string, so a profile name or a CIDR
//     cannot inject anything;
//   * a hard timeout, so a wedged `wg-quick` cannot hang the caller;
//   * stdout and stderr captured together, because the tools disagree about
//     which stream carries their error text;
//   * a pinned PATH, because the helper runs from launchd where Homebrew's
//     bin directory is not on PATH — and, as root, a PATH and a tool lookup
//     with no user-writable directory in them (see `resolve`).
//
// It never throws: a failure is a non-zero exit and a message, which is what
// the callers want to show the user anyway.

import Foundation

/// Result of one command: exit status plus combined output.
public struct CommandResult: Sendable {
    public let status: Int32
    public let output: String
    public let timedOut: Bool

    public var ok: Bool { status == 0 && !timedOut }

    public init(status: Int32, output: String, timedOut: Bool = false) {
        self.status = status
        self.output = output
        self.timedOut = timedOut
    }

    /// Last non-empty lines, for an error message that fits in a status bar.
    public func tail(_ lines: Int = 2) -> String {
        let parts = output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.suffix(lines).joined(separator: " ")
    }
}

/// One way to start a process, so a caller can be measured instead of trusted.
///
/// WHY THIS EXISTS
/// The read path's whole claim is "the periodic refresh spawns no root
/// process". A claim like that has to be counted, not asserted, and the count
/// has to include processes started *inside* `ReportBuilder` — not just the
/// `sudo` call at the top. The only reliable place to count is the one
/// function every spawn goes through, so it is a protocol with a default
/// implementation rather than a special test build.
///
/// Only read-only code takes a runner. The mutating half (`up`, `down`,
/// `changeMode`, `switchTo`, DNS writes) keeps calling `Shell.run` directly on
/// purpose: those paths are covered by the safety review, and threading a new
/// parameter through them would change code that is supposed to be frozen.
public protocol CommandRunner: Sendable {
    func run(_ tool: String, _ args: [String], timeout: TimeInterval) -> CommandResult
}

/// The real one. A value type with no state, so a default argument is free.
public struct SystemRunner: CommandRunner {
    public init() {}
    public func run(_ tool: String,
                    _ args: [String],
                    timeout: TimeInterval) -> CommandResult {
        Shell.run(tool, args, timeout: timeout)
    }
}

public enum Shell {
    /// Where system tools (route, networksetup, ifconfig, curl, ...) come from.
    /// These live on the sealed system volume, so no user can replace them.
    public static let systemDirs = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    /// Tools that only exist outside the system volume. As root they run only
    /// from `Path.trustedBin`, the root-owned copies the installer made.
    public static let wireGuardTools: Set<String> = ["wg", "wg-quick", "wireguard-go", "bash"]

    /// PATH for child processes.
    ///
    /// As a user, Homebrew comes first: launchd's environment lacks it and
    /// `wg` lives there. As root, no Homebrew directory appears at all:
    /// /opt/homebrew is owned by the user, and wg-quick (a bash script) finds
    /// `wg` and `wireguard-go` through PATH, so any user-writable entry here
    /// would be a root shell for that user.
    public static func path(root: Bool) -> String {
        root ? ([Path.trustedBin] + systemDirs).joined(separator: ":")
             : "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    }

    public static var path: String { path(root: geteuid() == 0) }

    /// Run a command and wait for it, killing it after `timeout`.
    /// `stdin` (1.0.7) is written to the child and then closed; only
    /// `switch --key-stdin` uses it. Without it the child reads /dev/null.
    public static func run(_ tool: String,
                           _ args: [String] = [],
                           timeout: TimeInterval = 30,
                           stdin: Data? = nil) -> CommandResult {
        let process = Process()
        let root = geteuid() == 0
        let resolved = resolve(tool, root: root)
        if root, resolved.hasPrefix(Path.trustedHelperDir + "/"),
           let why = trustViolation(resolved) {
            return CommandResult(status: 126, output: untrustedMessage(why))
        }
        process.executableURL = URL(fileURLWithPath: resolved)
        process.arguments = args

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path(root: root)
        if root {
            // wg-quick runs whatever this names as the userspace tunnel, and
            // bash sources BASH_ENV/ENV: none may come from the caller.
            for key in ["WG_QUICK_USERSPACE_IMPLEMENTATION", "BASH_ENV", "ENV"] {
                env.removeValue(forKey: key)
            }
        }
        // Keep the tools from asking anything interactively.
        env["NONINTERACTIVE"] = "1"
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let input = stdin.map { _ in Pipe() }
        process.standardInput = input ?? FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return CommandResult(status: 127, output: "\(tool): \(error.localizedDescription)")
        }
        if let input, let stdin {
            // A key line is far below the pipe buffer, so this never blocks.
            try? input.fileHandleForWriting.write(contentsOf: stdin)
            try? input.fileHandleForWriting.close()
        }

        // Read on a background thread so a chatty tool cannot fill the pipe and
        // deadlock while we are waiting for it to exit. The buffer is locked:
        // the caller only reads it once the reader says it is done.
        let buffer = OutputBuffer()
        let reader = DispatchQueue(label: "menfez.shell.read")
        reader.async {
            buffer.finish(pipe.fileHandleForReading.readDataToEndOfFile())
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(20_000)
        }

        if process.isRunning {
            killTree(process)
            process.waitUntilExit()
            return CommandResult(status: 124,
                                 output: buffer.text(waiting: drainWait),
                                 timedOut: true)
        }

        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus,
                             output: buffer.text(waiting: drainWait))
    }

    /// How long to wait for the pipe to reach EOF after the child exited. A
    /// grandchild that inherited the pipe can hold it open past that.
    static let drainWait: TimeInterval = 2

    /// Returned instead of output when the pipe did not drain in time.
    public static let outputUnavailable = "(output unavailable: the pipe was still open)"

    /// Terminate the child and everything it started.
    ///
    /// Foundation's Process on Darwin starts the child as the leader of its
    /// own process group (pgid == pid), so signalling the group also reaches
    /// grandchildren that would otherwise keep the pipe open. That is not
    /// documented, so it is checked first; without it only the child is
    /// signalled and `outputUnavailable` covers the still-open pipe.
    static func killTree(_ process: Process) {
        let pid = process.processIdentifier
        let target = getpgid(pid) == pid ? -pid : pid
        kill(target, SIGTERM)
        usleep(150_000)
        kill(target, SIGKILL)
    }

    /// Output collected on the reader queue, handed over under a lock.
    final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private let done = DispatchSemaphore(value: 0)
        private var data: Data?

        func finish(_ data: Data) {
            lock.lock(); self.data = data; lock.unlock()
            done.signal()
        }

        /// The output, or `outputUnavailable` when the reader is not done in time.
        func text(waiting seconds: TimeInterval) -> String {
            _ = done.wait(timeout: .now() + seconds)
            lock.lock(); defer { lock.unlock() }
            guard let data else { return Shell.outputUnavailable }
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// Absolute path for a tool.
    ///
    /// As a user: Homebrew first, then the system, so `wg` is found from a
    /// launchd context. As root: system tools only from `systemDirs`, and the
    /// WireGuard toolchain only from `Path.trustedBin` — never a Homebrew path,
    /// because /opt/homebrew is writable by the user and a planted
    /// /opt/homebrew/bin/route would otherwise run as root.
    public static func resolve(_ tool: String,
                               root: Bool = geteuid() == 0,
                               isExecutable: (String) -> Bool = {
                                   FileManager.default.isExecutableFile(atPath: $0)
                               }) -> String {
        if tool.hasPrefix("/") { return tool }
        if root && wireGuardTools.contains(tool) {
            // Returned even when missing, so the trust check names the path
            // the installer should have created.
            return Path.trustedBin + "/" + tool
        }
        let dirs = root ? systemDirs
                        : ["/opt/homebrew/bin", "/usr/local/bin"] + systemDirs
        for dir in dirs where isExecutable(dir + "/" + tool) {
            return dir + "/" + tool
        }
        // A bare name would be resolved against the working directory, which
        // under sudo is the caller's; root gets a path that simply fails.
        return root ? systemDirs[0] + "/" + tool : tool
    }

    /// Owner and mode of one path, as `lstat` reports them.
    public struct FileInfo: Equatable, Sendable {
        public let uid: uid_t
        public let mode: mode_t
        public init(uid: uid_t, mode: mode_t) { self.uid = uid; self.mode = mode }
    }

    public static func lstatInfo(_ path: String) -> FileInfo? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return FileInfo(uid: st.st_uid, mode: st.st_mode)
    }

    /// Why root must not execute `path`, or nil when it may.
    ///
    /// The file and every directory above it must exist, be owned by root, not
    /// be writable by group or other, and not be a symbolic link. Any one of
    /// those failing lets a non-root user swap what root runs. Pure apart from
    /// `info`, which a test replaces.
    public static func trustViolation(_ path: String,
                                      info: (String) -> FileInfo? = lstatInfo) -> String? {
        guard path.hasPrefix("/") else { return "\(path) is not an absolute path" }
        var current = path
        while true {
            guard let i = info(current) else { return "\(current) does not exist" }
            if i.mode & S_IFMT == S_IFLNK { return "\(current) is a symbolic link" }
            if i.uid != 0 { return "\(current) is not owned by root" }
            if i.mode & 0o022 != 0 { return "\(current) is writable by group or others" }
            if current == "/" { return nil }
            current = (current as NSString).deletingLastPathComponent
        }
    }

    /// The refusal, in both languages: it can reach the UI as an error line.
    public static func untrustedMessage(_ reason: String) -> String {
        "Refusing to run as root: \(reason). Re-run the tunnel setup "
            + "(./install.sh --tunnel, or the command in Help). / "
            + "Root olarak çalıştırılmadı: \(reason). Tünel kurulumunu yeniden "
            + "çalıştır (./install.sh --tunnel ya da Yardım'daki komut)."
    }

    /// True when the tool exists somewhere we can execute it.
    public static func exists(_ tool: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: resolve(tool))
    }
}
