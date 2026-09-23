import Foundation
import CryptoKit
import Security

/// Usher's logs — the journal and the rename log — are encrypted at rest.
///
/// They name every file Usher has ever looked at, where it went and why:
/// "openai-recovery-keys-….txt", a Google client ID inside a filename,
/// "contents mention Polizze Nummer". FileVault covers the disk while the Mac
/// is off; it does nothing about any other process running as you, or a
/// backup, reading a plain-text file in Application Support.
///
/// Each line is sealed on its own with AES-GCM (`u1:` + base64 of nonce,
/// ciphertext and tag), so appending stays an append and one damaged line
/// costs one line. The key is 256 random bits in the login keychain and
/// nowhere else. If it cannot be read, nothing is written in the clear:
/// callers fail closed.
enum LogCipher {

    static let service = "Usher journal key"
    static let account = "journal"
    static let prefix = "u1:"

    // MARK: - Key

    /// The key, created on first use. Nil when one exists but this build may
    /// not read it (a denied keychain prompt) — and then it is never replaced,
    /// because a new key would orphan every line sealed with the old one.
    static func key() -> SymmetricKey? {
        if let cached { return cached }
        let found = loadOrCreate()
        cached = found
        return found
    }

    /// Read once per process: every read of a keychain item can prompt.
    nonisolated(unsafe) private static var cached: SymmetricKey?

    private static func loadOrCreate() -> SymmetricKey? {
        if let data = readKey() { return SymmetricKey(data: data) }
        guard !keyExists() else { return nil }
        let fresh = SymmetricKey(size: .bits256)
        let data = fresh.withUnsafeBytes { Data($0) }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: service,
            kSecAttrDescription as String: "Encrypts Usher's journal and rename log",
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: data
        ]
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else { return nil }
        return fresh
    }

    private static func keyExists() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true
        ]
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }

    private static func readKey() -> Data? {
        // Headless commands must not block on a keychain dialog nobody sees.
        if !KeyStore.allowInteractiveKeychain { SecKeychainSetUserInteractionAllowed(false) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, data.count == 32 else { return nil }
        return data
    }

    // MARK: - Lines

    static func seal(_ plaintext: Data, key: SymmetricKey) throws -> String {
        guard let combined = try AES.GCM.seal(plaintext, using: key).combined else {
            throw CocoaError(.coderInvalidValue)
        }
        return prefix + combined.base64EncodedString()
    }

    /// A sealed line decrypted. Nil for one that does not open with this key —
    /// and nil for a plain line, unless this is the one-time migration.
    ///
    /// Plain lines used to be accepted on every read, so any process running
    /// as the user could append `{"outcome":"dryRun","routeProbability":0.99,…}`
    /// and have the next policy change move that file wherever the line said.
    static func open(_ line: Substring, key: SymmetricKey, allowPlain: Bool = false) -> Data? {
        guard line.hasPrefix(prefix) else { return allowPlain ? Data(line.utf8) : nil }
        guard let combined = Data(base64Encoded: String(line.dropFirst(prefix.count))),
              let box = try? AES.GCM.SealedBox(combined: combined) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }

    static func append(_ plaintext: Data, to file: URL, key: SymmetricKey) {
        guard let line = try? seal(plaintext, key: key) else { return }
        var data = Data((line + "\n").utf8)
        if FileManager.default.fileExists(atPath: file.path) {
            // Never the atomic-write fallback on an existing file: if opening
            // for append failed, that would replace the whole journal with
            // one line.
            guard let handle = try? FileHandle(forUpdating: file) else { return }
            defer { try? handle.close() }
            // A crash mid-write leaves a line without its newline, and the next
            // append would be glued to it — two unreadable lines instead of one.
            if let end = try? handle.seekToEnd(), end > 0 {
                try? handle.seek(toOffset: end - 1)
                if handle.readData(ofLength: 1) != Data([0x0A]) { data.insert(0x0A, at: 0) }
                _ = try? handle.seekToEnd()
            }
            try? handle.write(contentsOf: data)
        } else {
            // Created owner-only from the first byte, not chmod-ed afterwards.
            FileManager.default.createFile(atPath: file.path, contents: data,
                                           attributes: [.posixPermissions: 0o600])
        }
    }

    /// Every line of a log, decrypted. Lines that do not open are skipped.
    static func readLines(_ file: URL, key: SymmetricKey) -> [Data] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { open($0, key: key) }
    }

    // MARK: - Migration

    /// Every log in Usher's folder, sealed. The rename log and a plain-text
    /// journal backup made before a scrub are logs too.
    static func migrateAll(key: SymmetricKey) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Paths.support, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "ndjson" { migrate(file, key: key) }
    }

    /// Rewrites a log that still has plain-text lines with every line sealed,
    /// then replaces the original in one atomic step. The new file is read
    /// back and must decrypt line for line before the old one is touched —
    /// the journal is the only record of what can be undone.
    @discardableResult
    static func migrate(_ file: URL, key: SymmetricKey) -> Bool {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return true }
        let lines = text.split(separator: "\n")
        guard lines.contains(where: { !$0.hasPrefix(prefix) }) else { return true }
        // A journal from before encryption is plain throughout. Plain lines in
        // a file that already has sealed ones were added since — by a crash,
        // or by something else running as you. They are not sealed into the
        // record; reads ignore them.
        guard !lines.contains(where: { $0.hasPrefix(prefix) }) else { return false }
        // A sealed line that will not open under this key means another key
        // wrote it. Rewriting would drop it silently; refuse instead.
        let opened = text.split(separator: "\n").map { open($0, key: key, allowPlain: true) }
        guard !opened.contains(where: { $0 == nil }) else { return false }
        let plain = opened.compactMap { $0 }
        let sealed = plain.compactMap { try? seal($0, key: key) }
        guard sealed.count == plain.count else { return false }

        let staging = file.deletingLastPathComponent()
            .appendingPathComponent(".\(file.lastPathComponent).sealing")
        do {
            try? FileManager.default.removeItem(at: staging)
            guard FileManager.default.createFile(atPath: staging.path,
                                                 contents: Data((sealed.joined(separator: "\n") + "\n").utf8),
                                                 attributes: [.posixPermissions: 0o600]) else { return false }
            let check = readLines(staging, key: key)
            guard check == plain else { try? FileManager.default.removeItem(at: staging); return false }
            _ = try FileManager.default.replaceItemAt(file, withItemAt: staging)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return true
        } catch {
            try? FileManager.default.removeItem(at: staging)
            return false
        }
    }
}
