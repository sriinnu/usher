import CryptoKit

extension SymmetricKey {
    /// One key per test run, never the keychain: tests must not create or read
    /// Usher's real journal key.
    static let test = SymmetricKey(size: .bits256)
}
