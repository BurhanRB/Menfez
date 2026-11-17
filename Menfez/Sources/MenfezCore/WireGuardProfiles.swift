// WireGuardProfiles.swift — the user's WireGuard profiles, and the one
// generated config wg-quick is ever pointed at.
//
// WHY THERE ARE TWO KINDS OF FILE
// The user drops WireGuard `.conf` files into one directory and never
// expects them to change. wg-quick, however, has to be told `Table = off` (we
// own the routes), `AllowedIPs = 0.0.0.0/0, ::/0` (the peer must accept
// everything we send) and no `DNS =` line (wg-quick would otherwise hijack the
// resolver behind the app's back). So each selection is rewritten into
// `wgmanaged.conf`, and the original is left byte-for-byte alone. That also
// means switching back to a server is a rewrite, not a restore.
//
// THE KEY RULE
// A WireGuard config is a private key with some metadata around it, and this
// file is read by the app, by the helper, and in logs. So:
//   * `list()` scans only `[Interface] Address` and `[Peer] Endpoint`, and
//     stops at any other key. A PrivateKey line is never captured, never
//     trimmed into a variable, never stored in `Profile` (which has no field
//     for it) and never logged.
//   * the managed rewrite must preserve the key — a config without one cannot
//     bring an interface up — so it passes key lines through untouched, by
//     prefix, without ever naming their contents. Nothing in this file returns
//     or reports a key value.
//
// MANAGEMENT COPIES ARE HIDDEN
// Providers write one file per server, and older versions of this app wrote
// extra copies named `wgsplit`, `wgmanaged` or `*-split`. Showing those in the
// picker would offer the user a "server" that is really our own scaffolding, so
// they are skipped by stem.

import Foundation

public enum WireGuardProfiles {

    /// Stems that are management scaffolding rather than a server the user
    /// chose. Kept as a set so a new one is a one-line change.
    static let hiddenStems: Set<String> = ["wgsplit", "wgmanaged"]

    /// Suffix older builds used for a split-tunnel copy.
    static let hiddenSuffix = "-split"

    /// 0700: the directory holds private keys, so even the names are not for
    /// other local users.
    private static let directoryMode: mode_t = 0o700
    private static let configMode: mode_t = 0o600

    // MARK: - Import

    /// Why a chosen file could not be imported.
    ///
    /// A dedicated type rather than a bare String so the UI can switch on the
    /// case (offer "replace" for `.exists`, show a hint for `.notAConfig`) and
    /// so a caller cannot accidentally print a raw failure as success.
    public struct ImportError: Error, CustomStringConvertible, Equatable {
        public enum Kind: Equatable, Sendable {
            case missing
            case unreadable
            case notAConfig
            case badName
            case exists
            case ioFailure
        }
        public let kind: Kind
        public let message: String
        public var description: String { message }

        init(_ kind: Kind, _ message: String) {
            self.kind = kind
            self.message = message
        }
    }

    /// Copy a user-chosen `.conf` into the profile directory.
    ///
    /// Anyone can use this: Menfez ships no provider relationship, so the
    /// picker is whatever the user puts in the folder. The import is
    /// deliberately conservative:
    ///
    ///   * the destination name is derived from the source basename and then
    ///     sanitised, so a name containing "/" or ".." cannot escape the
    ///     directory (the caller's path is never used as-is);
    ///   * an existing file is only replaced when `overwrite` is true, because
    ///     silently clobbering a working profile is how a user loses their
    ///     only tunnel;
    ///   * the copy is written with mode 0600 from the first byte rather than
    ///     written then chmod'ed, so there is no window where the private key
    ///     is world-readable;
    ///   * the file is checked for the two sections it must have. A file that
    ///     is not a WireGuard config is rejected with a reason, not stored.
    /// - Parameter stem: write under this existing profile name instead of one
    ///   derived from the source file ("Replace config…"). Must already be a
    ///   safe stem; the caller passes a name from `list()`.
    public static func importConfig(from sourcePath: String,
                                    overwrite: Bool = false,
                                    directory: String = Path.profiles,
                                    as stem: String? = nil)
        -> Result<Profile, ImportError> {

        let fm = FileManager.default
        guard fm.fileExists(atPath: sourcePath) else {
            return .failure(ImportError(.missing, "no file at \(sourcePath)"))
        }
        guard let raw = try? String(contentsOfFile: sourcePath, encoding: .utf8) else {
            return .failure(ImportError(.unreadable, "could not read the file (is it a text .conf?)"))
        }

        let lower = raw.lowercased()
        guard lower.contains("[interface]") else {
            return .failure(ImportError(.notAConfig, "missing an [Interface] section"))
        }
        guard lower.contains("[peer]") else {
            return .failure(ImportError(.notAConfig, "missing a [Peer] section"))
        }
        guard lower.contains("privatekey") else {
            return .failure(ImportError(.notAConfig, "missing a PrivateKey line"))
        }

        let stem = stem ?? sanitisedStem(from: (sourcePath as NSString).lastPathComponent)
        guard !stem.isEmpty, validatedName(stem) == stem else {
            return .failure(ImportError(.badName, "the file name has no usable characters"))
        }
        Path.ensureDir(directory, mode: 0o700)
        let destination = (directory as NSString).appendingPathComponent(stem + ".conf")

        if fm.fileExists(atPath: destination), !overwrite {
            return .failure(ImportError(.exists, "a profile named \(stem) already exists"))
        }

        // O_CREAT with an explicit mode, then write through a file descriptor:
        // the key is never briefly readable by anyone else.
        let fd = open(destination, O_WRONLY | O_CREAT | O_TRUNC, configMode)
        guard fd >= 0 else {
            return .failure(ImportError(.ioFailure, "could not create \(destination)"))
        }
        let bytes = Array(raw.utf8)
        let written = bytes.withUnsafeBufferPointer {
            write(fd, $0.baseAddress, $0.count)
        }
        close(fd)
        guard written == bytes.count else {
            try? fm.removeItem(atPath: destination)
            return .failure(ImportError(.ioFailure, "could not write the profile"))
        }
        _ = chmod(destination, configMode)

        // Re-read through the normal parser so the caller gets exactly the
        // profile the picker would show, including any parse error.
        for profile in list(directory: directory) where profile.name == stem {
            return .success(profile)
        }
        return .failure(ImportError(.notAConfig, "the file was copied but could not be parsed"))
    }

    /// A filename stem that is safe to use as a path component.
    ///
    /// Only letters, digits, dash, underscore and space survive; everything
    /// else becomes a dash. This is the check that stops "../../evil" from
    /// writing outside the profile directory.
    static func sanitisedStem(from filename: String) -> String {
        var stem = filename
        if stem.lowercased().hasSuffix(".conf") {
            stem = String(stem.dropLast(5))
        }
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "-_ "))
        let cleaned = stem.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let text = String(cleaned).trimmingCharacters(in: .whitespaces)
        return String(text.prefix(64))
    }

    // MARK: - Rename / delete

    /// A typed profile name, trimmed, or nil when it cannot be a file stem.
    ///
    /// Stricter than `sanitisedStem`: a typed name is refused rather than
    /// rewritten, so the user never ends up with a name they did not type.
    /// Only letters, digits, dash, underscore and space; no separators, no
    /// leading dot, at most 64 characters, and not one of our hidden stems
    /// (the listing would hide the profile).
    public static func validatedName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespaces)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        guard !name.isEmpty, name.count <= 64,
              Validate.isSafeStem(name),
              name.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              !hiddenStems.contains(name), !name.hasSuffix(hiddenSuffix)
        else { return nil }
        return name
    }

    /// Rename a profile's file inside `directory`. Never overwrites.
    public static func rename(_ name: String, to newName: String,
                              directory: String = Path.profiles)
        -> Result<Profile, ImportError> {
        guard Validate.isSafeStem(name) else {
            return .failure(ImportError(.badName, "not a profile name"))
        }
        guard let target = validatedName(newName) else {
            return .failure(ImportError(.badName, "use letters, digits, spaces, - or _ (at most 64)"))
        }
        let fm = FileManager.default
        let from = (directory as NSString).appendingPathComponent(name + ".conf")
        let to = (directory as NSString).appendingPathComponent(target + ".conf")
        guard fm.fileExists(atPath: from) else {
            return .failure(ImportError(.missing, "no profile named \(name)"))
        }
        if target == name {
            return list(directory: directory, liveHost: nil)
                .first(where: { $0.name == name }).map { .success($0) }
                ?? .failure(ImportError(.notAConfig, "the profile could not be parsed"))
        }
        // A case-only rename on a case-insensitive volume is the same file;
        // anything else that exists is someone else's profile.
        if fm.fileExists(atPath: to), name.lowercased() != target.lowercased() {
            return .failure(ImportError(.exists, "a profile named \(target) already exists"))
        }
        do {
            try fm.moveItem(atPath: from, toPath: to)
        } catch {
            return .failure(ImportError(.ioFailure, "could not rename the profile"))
        }
        return list(directory: directory, liveHost: nil)
            .first(where: { $0.name == target }).map { .success($0) }
            ?? .failure(ImportError(.notAConfig, "renamed, but the profile could not be parsed"))
    }

    /// Move one profile file from `directory` to the Trash, so a wrong click
    /// can be undone from Finder. Only a `<name>.conf` directly inside it is
    /// ever touched; the original file the user imported from stays where it
    /// was. If the volume has no Trash, the file is removed instead.
    @discardableResult
    /// `trash` is a parameter so tests do not fill the user's real Trash.
    public static func delete(_ name: String, directory: String = Path.profiles,
                              trash: (URL) throws -> Void = {
                                  try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
                              }) -> Bool {
        guard Validate.isSafeStem(name) else { return false }
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name + ".conf")
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        // Neither call follows a symlink: the link goes, not what it points at.
        if (try? trash(url)) != nil { return true }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }

    // MARK: - Listing

    /// Every usable profile, sorted by name.
    ///
    /// Sorted so the picker does not jitter: `glob` order is filesystem order
    /// and changes when a file is rewritten.
    public static func list(directory: String = Path.profiles) -> [Profile] {
        list(directory: directory, liveHost: nil, resolveLiveHost: true)
    }

    /// The same listing, with the privileged read moved out of it.
    ///
    /// WHY THE LIVE HOST IS A PARAMETER
    /// `active` used to be computed here from `RouteManager.endpoint(iface:)`,
    /// i.e. `wg show <iface> endpoints`, which is "Permission denied" without
    /// root. That made the whole profile picker one privileged call even though
    /// everything else it does is a directory read. The app now passes in an
    /// endpoint it already fetched (or nil when it does not know one), so the
    /// picker can be rendered without a root process. `resolveLiveHost` is what
    /// the CLI uses: it runs as root, so asking is free there and keeps the
    /// helper's own `profiles` output exactly as before.
    ///
    /// - Parameters:
    ///   - liveHost: endpoint host of the live tunnel, or nil when unknown.
    ///     Nil is not "no endpoint": no profile is marked active, which the
    ///     picker draws as "none highlighted" rather than a wrong highlight.
    ///   - resolveLiveHost: when true, `liveHost` is ignored and the endpoint
    ///     is probed here. Only safe for a caller that is already root.
    public static func list(directory: String = Path.profiles,
                            liveHost: String?,
                            resolveLiveHost: Bool = false,
                            using runner: CommandRunner = SystemRunner()) -> [Profile] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        let candidates = names
            .filter { $0.hasSuffix(".conf") }
            .map { ($0 as NSString).deletingPathExtension }
            .filter { stem in
                !hiddenStems.contains(stem) && !stem.hasSuffix(hiddenSuffix)
            }
            .sorted()

        let resolvedHost: String?
        if resolveLiveHost {
            resolvedHost = RouteManager.interfaceList(using: runner)?
                .first
                .flatMap { RouteManager.endpoint(iface: $0, using: runner) }
        } else {
            resolvedHost = liveHost
        }

        var profiles: [Profile] = []
        for stem in candidates {
            let file = (directory as NSString).appendingPathComponent(stem + ".conf")
            guard let text = readText(at: file) else { continue }

            let parsed = scan(text)
            let endpoint = parsed.endpoint
            let host = endpoint.flatMap(hostPart)

            // A profile with no endpoint cannot be switched to: `switchTo`
            // refuses to route without one. Marking it here is what lets the
            // picker say so instead of offering a row that fails on click. The
            // message never repeats any part of the file.
            var problem: String?
            if parsed.address == nil {
                problem = "no [Interface] Address line"
            } else if endpoint == nil {
                problem = "no [Peer] Endpoint line"
            }

            // A profile is "active" when the live endpoint host appears inside
            // its endpoint string. String containment rather than equality
            // because wg reports a resolved host:port while the source file
            // sometimes carry a hostname.
            let active = resolvedHost.map { live in
                guard let endpoint else { return false }
                return endpoint.contains(live)
            } ?? false

            profiles.append(Profile(name: stem,
                                    file: file,
                                    endpoint: endpoint,
                                    host: host,
                                    country: countryCode(stem),
                                    display: ProfileNaming.displayName(
                                        stem: stem, configText: text),
                                    active: active,
                                    error: problem))
        }
        return profiles
    }

    /// The scanner result. Only fields the picker may show.
    struct ParsedProfile {
        var address: String?
        var endpoint: String?
    }

    /// Read `[Interface] Address` and `[Peer] Endpoint`, nothing else.
    ///
    /// Hand-rolled rather than pattern-matching the whole file: it guarantees
    /// that a `PrivateKey =` line is never even looked at, so there is no code
    /// path that could log it.
    ///
    /// The value slice is taken *inside* the two branches that want it. An
    /// earlier version built `value` for every line before the switch dropped
    /// it, so a `PrivateKey` line's bytes were briefly bound to a local even
    /// though nothing kept them. Not a leak, but not the claim the file makes
    /// either; this is the version where the claim is true by construction.
    static func scan(_ text: String) -> ParsedProfile {
        var parsed = ParsedProfile()
        var section = ""

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = line.lowercased()
                continue
            }

            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<equals]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()

            // The switch lists exactly the two keys we are allowed to keep.
            // Everything else — including key material — matches neither branch
            // and its value is never sliced out of the line at all.
            switch (section, key) {
            case ("[interface]", "address"):
                guard parsed.address == nil else { continue }
                parsed.address = value(of: line, after: equals)
            case ("[peer]", "endpoint"):
                guard parsed.endpoint == nil else { continue }
                parsed.endpoint = value(of: line, after: equals)
            default:
                continue
            }
        }
        return parsed
    }

    /// Everything after the equals sign, trimmed.
    private static func value(of line: String,
                              after equals: String.Index) -> String {
        line[line.index(after: equals)...]
            .trimmingCharacters(in: .whitespaces)
    }

    /// "VPN-RO1-RO-229" -> "RO".
    ///
    /// Common provider filenames look like "<prefix>-<CC><number>", so the country follows the
    /// city group. Python's `^[A-Z]{3}-([A-Z]{2})\d` is anchored at the start,
    /// which is why the second group and not the third is the one that carries
    /// it: the trailing "RO" is the city's own code, not the country's.
    /// A stem that does not match yields nil, which the UI draws as no flag
    /// rather than a wrong one.
    static func countryCode(_ stem: String) -> String? {
        let parts = stem.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count >= 2,
              parts[0].count == 3,
              parts[0].allSatisfy({ $0.isUppercase && $0.isASCII && $0.isLetter })
        else { return nil }

        let candidate = Array(parts[1])
        // Two uppercase letters followed by at least one digit. The digit is
        // what distinguishes "RO1" from a bare city abbreviation.
        guard candidate.count >= 3,
              candidate[0].isUppercase, candidate[0].isLetter,
              candidate[1].isUppercase, candidate[1].isLetter,
              candidate[2].isNumber else { return nil }
        return String(candidate[0...1])
    }

    /// Host half of "198.51.100.7:51820" or "[2001:db8::7]:51820".
    static func hostPart(_ endpoint: String) -> String? {
        guard let colon = endpoint.lastIndex(of: ":") else {
            return endpoint.isEmpty ? nil : endpoint
        }
        let host = String(endpoint[endpoint.startIndex..<colon])
        let trimmed = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Managed config

    /// Rewrite a user profile into the form the manager expects.
    ///
    /// Differences from the user's file:
    ///   * `Table = off`          we own the routes
    ///   * `AllowedIPs 0.0.0.0/0` the peer must accept everything we send
    ///   * no `DNS` line          wg-quick would hijack the system resolver
    ///   * allowlisted keys only  wg-quick runs as root and executes the
    ///                            Pre/Post Up/Down hooks as shell commands;
    ///                            the source is user-writable, so copying an
    ///                            unknown key through hands any local process
    ///                            passwordless root
    ///
    /// The key line is copied through unchanged and is never decoded: the
    /// generated file is the only place a working key can live, so dropping it
    /// would produce a config that cannot come up.
    @discardableResult
    public static func writeManagedConfig(from source: String,
                                          to destination: String = Path.managedConfig)
        -> Bool {
        guard let raw = readText(at: source) else { return false }

        var output: [String] = []
        var section = ""

        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Key material: append and move on. No trim, no split, no copy into
            // a named value — the only thing that happens to this line is that
            // it is written back out.
            if isKeyMaterial(trimmed) {
                output.append(line)
                continue
            }

            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                section = trimmed.lowercased()
                // An unknown section has no allowed keys; wg-quick rejects it
                // anyway, so it is dropped together with its contents.
                guard allowedKeys[section] != nil else { continue }
                output.append(line)
                if section == "[interface]" {
                    output.append("Table = off")
                }
                continue
            }

            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                output.append(line)
                continue
            }

            guard let key = keyName(trimmed) else { continue }
            if section == "[peer]", key == "allowedips" {
                output.append("AllowedIPs = 0.0.0.0/0, ::/0")
                continue
            }
            // Everything else is dropped: DNS, Table, the Pre/Post hooks,
            // SaveConfig, FwMark, and any line before the first section.
            guard allowedKeys[section]?.contains(key) == true else { continue }
            output.append(line)
        }

        // wg-quick insists on a trailing newline, and the Python always wrote
        // one, including to an empty result.
        let text = output.joined(separator: "\n") + "\n"
        return writeSecret(text, to: destination)
    }

    /// True for a `PrivateKey = …` or `PresharedKey = …` line, decided from the
    /// key prefix alone so the value is never examined.
    ///
    /// A prefix test alone would also match `PrivateKeyCount`, so the prefix is
    /// followed by optional whitespace and then `=`. A tab between the key and
    /// the equals sign is a legal wg-quick form and used to slip past this
    /// test, which meant the rewrite did not recognise the key line and the
    /// `DNS` strip did not recognise `DNS\t=`.
    private static func isKeyMaterial(_ trimmed: String) -> Bool {
        let lowered = trimmed.trimmingCharacters(in: .whitespaces).lowercased()
        for key in ["privatekey", "presharedkey"] {
            guard lowered.hasPrefix(key) else { continue }
            let rest = lowered.dropFirst(key.count)
            let afterSpaces = rest.drop(while: { $0 == " " || $0 == "\t" })
            if afterSpaces.first == "=" { return true }
        }
        return false
    }

    /// Keys copied through per section, besides key material (`isKeyMaterial`)
    /// and `AllowedIPs` (rewritten). `Table` is always our own line.
    static let allowedKeys: [String: Set<String>] = [
        "[interface]": ["address", "listenport", "mtu"],
        "[peer]": ["publickey", "endpoint", "persistentkeepalive"],
    ]

    /// The lowercased key of a `key = value` line, parsed the way wg-quick
    /// does: comment stripped first, then the text before the first `=`,
    /// trimmed of spaces and tabs. `nil` for a line without `=`.
    ///
    /// Matching wg-quick's parse is the point: if this saw `Address` where
    /// wg-quick sees `PostUp`, the allowlist would be bypassed. Trimming also
    /// makes `DNS\t=`, ` postup = ` and `PostUp=` the same key as `DNS =` and
    /// `PostUp =`; accepting only one spacing used to let a tab form through.
    static func keyName(_ line: String) -> String? {
        let uncommented = line.split(separator: "#", maxSplits: 1,
                                     omittingEmptySubsequences: false)[0]
        guard let equals = uncommented.firstIndex(of: "=") else { return nil }
        return uncommented[..<equals]
            .trimmingCharacters(in: .whitespaces).lowercased()
    }

    // MARK: - Switching

    /// Bring the tunnel up with a different profile, keeping the current mode.
    ///
    /// Order matters: the old tunnel is taken down completely before the new one
    /// starts, because two WireGuard interfaces carrying the same AllowedIPs
    /// would fight over the route table. If the new one cannot be brought up
    /// healthy, everything is removed and the state says "off" — a tunnel that
    /// looks configured but carries nothing is the failure mode this exists to
    /// prevent.
    public static func switchTo(name: String, dnsRoutes: [String] = []) -> ActionResult {
        // The picker only ever produces a stem from `list()`, but this entry
        // point takes a string from the CLI. A name containing "/" or ".." is
        // refused before it is compared with a listing: `list()` would never
        // match it, but refusing explicitly means no future refactor can turn
        // it into a path.
        guard Validate.isSafeStem(name) else {
            return .failure("'\(name)' is not a valid profile name")
        }
        guard let target = list().first(where: { $0.name == name }) else {
            // As root with no SUDO_USER there is no profile directory at all.
            if Path.realHome == Path.noHome {
                return .failure("no profile named \(name): cannot tell whose profiles to read (run through sudo, not as root directly)")
            }
            return .failure("no profile named \(name)")
        }

        var state = RouteStateStore.load()
        // A switch keeps the mode the user chose; a switch made while nothing
        // was routed defaults to the documented mode rather than to "off",
        // because the user asked for a working tunnel, not for nothing.
        var mode = Mode(rawValue: state.mode) ?? .discord
        if mode == .off { mode = .discord }

        // Remember what this run inherited. Anything in here that the switch
        // does not re-create must be removed: a host route via a gateway
        // survives its interface disappearing, so an old pin left behind is
        // both unrecorded and permanent.
        let previousHosts = state.hosts
        let previousRoutes = state.routes

        /// Record a failed switch without forgetting the pins that outlive the
        /// interface.
        ///
        /// `wg-quick down` removes the utun's own routes, but a host route via a
        /// gateway stays in the table. Writing a blank "off" here was C3 over
        /// again: the old pin would still be installed with nothing recording
        /// it, so `down` could never remove it. The mode is honest ("off") and
        /// the surviving pins stay claimed.
        func recordTunnelDown() {
            RouteStateStore.save(RouteState(mode: Mode.off.rawValue,
                                            iface: nil,
                                            hosts: previousHosts,
                                            generation: state.generation))
        }

        func failAfterTunnelDown(_ message: String) -> ActionResult {
            recordTunnelDown()
            return .failure(message)
        }

        // Failure here is expected when nothing was up; wg-quick says so on
        // stderr with "is not a WireGuard interface". The Python swallowed it
        // too, and there is nothing to clean up in that case.
        _ = stopManagedTunnel()

        guard writeManagedConfig(from: target.file) else {
            // The tunnel is already down, so the state must stop claiming a
            // live mode; otherwise the report says "all" over a dead tunnel.
            return failAfterTunnelDown("cannot write the managed config (the profile must be a regular file you own, not a symlink); the old tunnel is now down")
        }

        let started = Shell.run("wg-quick", ["up", Path.managedConfig],
                                timeout: RouteManager.wireGuardTimeout)
        guard started.ok else {
            // wg-quick echoes the offending config line and the managed config
            // holds the private key, so its output never leaves this frame.
            recordTunnelDown()
            return .redacted("the new profile",
                             summary: managedConfigSummary())
        }

        guard let iface = RouteManager.interfaces().first else {
            return failAfterTunnelDown("tunnel did not come up")
        }

        guard let gateway = RouteManager.physicalGateway() else {
            return failAfterTunnelDown("cannot determine the physical gateway; refusing to route")
        }
        let endpoint = RouteManager.endpoint(iface: iface)

        // Same contract as `up`, and enforced the same way: a discarded result
        // here is how the outage returns through the server picker. Without a
        // live pin, adding 0.0.0.0/1 + 128.0.0.0/1 routes the tunnel's own
        // encrypted packets into the tunnel and kills the transport.
        guard let endpoint else {
            return failAfterTunnelDown("the new server reports no endpoint; refusing to route")
        }

        // Y5: the pin, the prefixes and the transport check go through the same
        // path as `up`: a pending intent is written before the first route, a
        // failed add is not ignored, and everything added is rolled back and
        // recorded. The new server is a different machine on a different path,
        // so proving the transport still moves is the only way to know the
        // profile is usable.
        var manager = RouteManager()
        manager.dnsRoutes = dnsRoutes
        // Updates mode keeps its host /32s: they came from the root-owned
        // state file, which only ever records validated prefixes.
        if mode == .updates {
            manager.hostRoutes = previousRoutes.filter { $0.hasSuffix("/32") && !dnsRoutes.contains($0) }
        }
        let applied = manager.apply(mode: mode, iface: iface, gateway: gateway,
                                           endpoint: endpoint, revertAfter: nil)
        guard applied.ok else {
            let down = stopManagedTunnel()
            // The rollback recorded what survived. Prefixes on the utun go with
            // the interface; host pins via the gateway do not and stay claimed.
            var left = RouteStateStore.load()
            left.mode = Mode.off.rawValue
            left.iface = nil
            left.pending = false
            if down { left.routes = [] }
            RouteStateStore.save(left)
            return .failure("new server: \(applied.error ?? "routes could not be applied")")
        }
        let live = applied.routes
        state = RouteStateStore.load()

        // Pins this run did not create are removed before the state forgets
        // them. They were installed for the previous server and survive the
        // interface going down, so leaving them would make them unrecorded and
        // permanent, and the next `up` would read them as "already present".
        var staleHosts: [String] = []
        for host in previousHosts where host != endpoint {
            if !RouteManager.deleteHostRoute(host) {
                // It survived a delete attempt; keep claiming it so `sanity`
                // can try again rather than leaking it forever.
                staleHosts.append(host)
            }
        }
        // Same for prefixes the new mode does not want. A delete of something
        // already gone is harmless; forgetting one that is still installed is
        // the black hole.
        var staleNets: [String] = []
        for cidr in previousRoutes where !live.contains(cidr) {
            if !RouteManager.deleteRoute(cidr) { staleNets.append(cidr) }
        }

        state.mode = mode.rawValue
        state.iface = iface
        state.routes = live + staleNets
        state.hosts = [endpoint] + staleHosts
        state.gateway = gateway
        state.profile = target.name
        state.pending = false
        RouteStateStore.save(state) // `apply` already bumped the generation

        var notes: [String] = []
        if !staleHosts.isEmpty || !staleNets.isEmpty {
            notes.append("\(staleHosts.count + staleNets.count) leftover route(s) from the previous server could not be removed; they stay recorded")
        }
        return ActionResult(ok: true, error: nil, mode: mode.rawValue,
                            iface: iface, profile: target.name,
                            endpoint: endpoint, routes: live, notes: notes)
    }

    /// Stop the tunnel wg-quick started from a `wgmanaged.conf`.
    ///
    /// With the managed config present this is `wg-quick down <config>`. It is
    /// missing after a reboot (/var/run is cleared, and so is the tunnel) and
    /// for a tunnel 1.0.x started from the old path under Application Support.
    /// wg-quick cannot go down without a config, and pointing root's wg-quick
    /// at the old user-writable file would run its PreDown/PostDown as root.
    /// wg-quick's own darwin teardown is removing the UAPI socket (wireguard-go
    /// exits) and the name file, so that is done directly, for our interface
    /// only. Returns true when a tunnel was told to stop.
    @discardableResult
    static func stopManagedTunnel(config: String = Path.managedConfig,
                                  runDir: String = "/var/run/wireguard") -> Bool {
        if FileManager.default.fileExists(atPath: config) {
            return Shell.run("wg-quick", ["down", config],
                             timeout: RouteManager.wireGuardTimeout).ok
        }
        let nameFile = (runDir as NSString).appendingPathComponent("wgmanaged.name")
        guard let raw = try? String(contentsOfFile: nameFile, encoding: .utf8) else {
            return false
        }
        let real = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only a plain utunN may become a path component.
        guard real.hasPrefix("utun"), real.count > 4,
              real.dropFirst(4).allSatisfy({ $0.isASCII && $0.isNumber })
        else { return false }
        let socket = (runDir as NSString).appendingPathComponent("\(real).sock")
        let stopped = (try? FileManager.default.removeItem(atPath: socket)) != nil
        try? FileManager.default.removeItem(atPath: nameFile)
        return stopped
    }

    // MARK: - File helpers

    /// Read a config file.
    ///
    /// Line endings are normalised because a config exported on Windows
    /// ends in CRLF, and a trailing `\r` would end up inside the last value of
    /// every section.
    ///
    /// Root reads these from the user-writable profile directory, so the open
    /// refuses a symlink (O_NOFOLLOW), anything but a regular file (a FIFO
    /// would hang root; O_NONBLOCK keeps the open itself from blocking), and,
    /// under sudo, a file owned by anyone but the invoking user or root.
    /// Otherwise a link to a root-only file would be parsed with root's rights.
    static func readText(at path: String) -> String? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              isTrustedOwner(info.st_uid) else { return nil }
        guard let data = try? handle.readToEnd() ?? Data() else { return nil }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return text.replacingOccurrences(of: "\r\n", with: "\n")
    }

    /// Under sudo, a file root reads on the user's behalf must belong to the
    /// invoking user or to root. Without sudo there is no one to impersonate.
    static func isTrustedOwner(_ owner: uid_t,
                               euid: uid_t = geteuid(),
                               sudoUID: String? = ProcessInfo.processInfo.environment["SUDO_UID"])
        -> Bool {
        guard euid == 0, let sudoUID, let invoker = uid_t(sudoUID) else { return true }
        return owner == invoker || owner == 0
    }

    /// A sanitised description of the managed config, for a failure message.
    ///
    /// Line numbers and key *names* only. This is what lets a user report "the
    /// generated config was rejected" with something actionable, without the
    /// private key travelling with the report.
    ///
    /// Reading the real path here is deliberate and safe: `configSummary`
    /// cannot emit a value, so the worst case on a machine where the file is
    /// unreadable (or absent) is an empty summary. `path` is injectable only so
    /// a test can point it at a config whose key it planted.
    static func managedConfigSummary(path: String = Path.managedConfig) -> [String] {
        guard let text = readText(at: path) else { return [] }
        return Redact.configSummary(text)
    }

    /// Write a config that contains key material.
    ///
    /// 0600 and created if missing. Written directly rather than through a
    /// temporary file: wg-quick reads the path we give it, and a rename inside
    /// the same directory is atomic enough that there is no window where a
    /// reader sees a partial file. The mode is set on the descriptor before any
    /// bytes land so the key is never world-readable, even briefly.
    private static func writeSecret(_ text: String, to path: String) -> Bool {
        let directory = (path as NSString).deletingLastPathComponent
        guard Path.ensureDir(directory, mode: directoryMode) else { return false }

        guard let data = text.data(using: .utf8) else { return false }
        // O_NOFOLLOW: root must never write through a planted symlink.
        let descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW,
                              configMode)
        guard descriptor >= 0 else { return false }

        // An existing file keeps its old permissions through O_CREAT alone, so
        // they are set explicitly. A managed config that once shipped 0644
        // would otherwise stay readable.
        _ = fchmod(descriptor, configMode)

        let written = data.withUnsafeBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            return write(descriptor, base, buffer.count)
        }
        close(descriptor)
        return written == data.count
    }
}

