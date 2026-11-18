// KeyStore.swift — WireGuard private keys in the login Keychain (1.0.7).
//
// WHAT CHANGES ON DISK
// A moved profile keeps every line except one: `PrivateKey = <key>` becomes
// `PrivateKey = menfez-keychain:<UUID>`. The UUID is the Keychain item's
// account, so it travels with the file through a rename and never depends on
// the file name. The user's original `.conf` (wherever they imported it from)
// is not Menfez's and is never touched; only the copy in `Path.profiles` is.
//
// WHICH KEYCHAIN
// The file-based login keychain, through SecItem without
// `kSecUseDataProtectionKeychain` or an access group. That needs no
// entitlement for a non-sandboxed Developer ID app (the data protection
// keychain would need `keychain-access-groups`, i.e. a provisioning profile).
// The item's access list trusts the app that created it, by its designated
// requirement, so a signed update reads it without a prompt; an ad-hoc build
// has a new identity every time and would be asked, which is why the offer to
// move keys only appears in a build signed with a Team ID (`signedWithTeam`).
//
// HOW THE KEY REACHES WIREGUARD
// The helper runs as root and does not read the user's keychain. The app
// reads the key and sends it to `menfez-route switch <name> --key-stdin` on
// standard input (never as an argument: `ps` shows those). The helper checks
// the format and writes it into the root-only managed config, as before.
//
// NOTHING HERE LOGS. A key value is held only in locals of the functions that
// move it; Swift gives no way to wipe them, which is the documented limit.

import Foundation
import Security

/// Where keys live. A protocol so the move/restore logic is tested with a
/// dictionary instead of the user's real Keychain.
public protocol KeyStore: Sendable {
    func read(_ id: String) -> String?
    /// Store `key` under `id`, replacing any old value. True only when a
    /// read-back returns the same key.
    func write(_ key: String, for id: String) -> Bool
    /// True when the item is gone afterwards (also when it never existed).
    @discardableResult
    func delete(_ id: String) -> Bool
}

/// The login keychain. `service` is injectable only for a live test, which
/// must use its own name and delete what it made.
public struct KeychainStore: KeyStore {
    public static let defaultService = "com.menfez.app.wireguard"
    public let service: String

    public init(service: String = KeychainStore.defaultService) {
        self.service = service
    }

    private func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id]
    }

    public func read(_ id: String) -> String? {
        var q = query(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ key: String, for id: String) -> Bool {
        delete(id)
        var q = query(id)
        q[kSecValueData as String] = Data(key.utf8)
        q[kSecAttrLabel as String] = "Menfez WireGuard key"
        // Never leaves this Mac through a backup or iCloud.
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { return false }
        return read(id) == key
    }

    @discardableResult
    public func delete(_ id: String) -> Bool {
        let status = SecItemDelete(query(id) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// True when this process is signed with a Team ID (Developer ID). The
    /// Keychain's access list follows the signature, so without one every
    /// rebuild would be a stranger to its own items.
    public static let signedWithTeam: Bool = {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return false }
        return dict[kSecCodeInfoTeamIdentifier as String] != nil
    }()
}

/// A store in memory, for tests and snapshots.
public final class MemoryKeyStore: KeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]
    /// Make the next writes fail, to test that a file is left alone.
    public var failWrites = false

    public init(_ items: [String: String] = [:]) { self.items = items }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }

    public func read(_ id: String) -> String? {
        lock.lock(); defer { lock.unlock() }; return items[id]
    }
    public func write(_ key: String, for id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !failWrites else { return false }
        items[id] = key
        return true
    }
    @discardableResult
    public func delete(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }; items[id] = nil; return true
    }
}

/// Moving a profile's key between its file and a `KeyStore`.
public enum ProfileKeys {

    /// Marks a `PrivateKey` value that lives in the Keychain.
    public static let prefix = "menfez-keychain:"

    /// What `switch` fails with when the key cannot be read. The app maps it
    /// to its own sentence; keep it stable.
    public static let readFailure = "Couldn't read Keychain, so the tunnel didn't start"

    /// What `switch` needs to send for a profile.
    public enum Lookup: Equatable, Sendable {
        /// The file holds its own key (or the profile is unknown): send nothing.
        case inFile
        /// The key from the Keychain, to go on standard input.
        case key(String)
        /// The file points at the Keychain and the item could not be read.
        case unreadable
    }

    // MARK: - Pure text work

    /// Index and value of the one `[Interface] PrivateKey` line, or nil when
    /// there is not exactly one. The value is the text after `=`, comment
    /// stripped and trimmed. Only the move/restore code calls this; `scan`
    /// (the picker's parser) still never looks at a key line.
    static func keyLine(in lines: [String]) -> (index: Int, value: String)? {
        var section = ""
        var found: (Int, String)?
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                section = trimmed.lowercased()
                continue
            }
            guard WireGuardProfiles.keyName(trimmed) == "privatekey" else { continue }
            guard section == "[interface]", found == nil else { return nil }
            let uncommented = trimmed.split(separator: "#", maxSplits: 1,
                                            omittingEmptySubsequences: false)[0]
            guard let eq = uncommented.firstIndex(of: "=") else { return nil }
            found = (i, uncommented[uncommented.index(after: eq)...]
                .trimmingCharacters(in: .whitespaces))
        }
        return found
    }

    static func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// The Keychain id a profile points at, or nil when its key is in the file.
    public static func keychainID(in text: String) -> String? {
        guard let line = keyLine(in: lines(text)), line.value.hasPrefix(prefix) else { return nil }
        let id = String(line.value.dropFirst(prefix.count))
        return UUID(uuidString: id) != nil ? id : nil
    }

    /// `text` with its one PrivateKey line set to `value`; nil when the file
    /// has no single key line.
    static func replacingKey(in text: String, with value: String) -> String? {
        var all = lines(text)
        guard let line = keyLine(in: all) else { return nil }
        all[line.index] = "PrivateKey = \(value)"
        return all.joined(separator: "\n")
    }

    // MARK: - Moving

    /// Move one profile's key into `store`. The file changes only after the
    /// store has the key and a read-back matched; any failure leaves the file
    /// byte-for-byte as it was. True when the key is in the store afterwards
    /// (also when it already was).
    @discardableResult
    public static func moveToStore(file: String, store: KeyStore,
                                   newID: () -> String = { UUID().uuidString }) -> Bool {
        guard let text = WireGuardProfiles.readText(at: file) else { return false }
        if keychainID(in: text) != nil { return true }
        guard let line = keyLine(in: lines(text)), Validate.isWireGuardKey(line.value) else { return false }
        let id = newID()
        guard store.write(line.value, for: id), store.read(id) == line.value,
              let moved = replacingKey(in: text, with: prefix + id),
              replaceFile(file, with: moved) else {
            store.delete(id)
            return false
        }
        return true
    }

    /// Put a moved key back into its file, then delete the item. True when
    /// the file holds its key afterwards.
    @discardableResult
    public static func moveToFile(file: String, store: KeyStore) -> Bool {
        guard let text = WireGuardProfiles.readText(at: file) else { return false }
        guard let id = keychainID(in: text) else { return true }
        guard let key = store.read(id), Validate.isWireGuardKey(key),
              let restored = replacingKey(in: text, with: key),
              replaceFile(file, with: restored) else { return false }
        store.delete(id)
        return true
    }

    /// What `switch` should send for `file`.
    public static func lookup(file: String, store: KeyStore) -> Lookup {
        guard let text = WireGuardProfiles.readText(at: file),
              let id = keychainID(in: text) else { return .inFile }
        guard let key = store.read(id), Validate.isWireGuardKey(key) else { return .unreadable }
        return .key(key)
    }

    /// Profiles in `directory` by where their key is: (in a file, in the store).
    public static func census(directory: String = Path.profiles) -> (plain: [String], moved: [String]) {
        var plain: [String] = [], moved: [String] = []
        for p in WireGuardProfiles.list(directory: directory, liveHost: nil) {
            guard let text = WireGuardProfiles.readText(at: p.file) else { continue }
            if keychainID(in: text) != nil { moved.append(p.file) }
            else if keyLine(in: lines(text)).map({ Validate.isWireGuardKey($0.value) }) == true {
                plain.append(p.file)
            }
        }
        return (plain, moved)
    }

    /// Atomic replace: a 0600 temp file next to it, then rename. A crash
    /// leaves either the old file or the new one, never half of each.
    static func replaceFile(_ path: String, with text: String) -> Bool {
        let tmp = path + ".menfez-tmp"
        unlink(tmp)
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return false }
        let data = Array(text.utf8)
        let written = data.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        let synced = fsync(fd) == 0
        close(fd)
        guard written == data.count, synced, rename(tmp, path) == 0 else {
            unlink(tmp)
            return false
        }
        return true
    }
}

/// The helper's side of `--key-stdin`: one line, one key, nothing else.
public enum KeyInput {
    /// Longest input read; a key line is 45 bytes.
    public static let limit = 128

    /// The key in `data`, or nil. Accepts the key with or without one
    /// trailing newline; anything longer, shorter or extra is refused.
    public static func parse(_ data: Data) -> String? {
        guard data.count <= limit, var text = String(data: data, encoding: .utf8) else { return nil }
        if text.hasSuffix("\n") { text.removeLast() }
        return Validate.isWireGuardKey(text) ? text : nil
    }
}
