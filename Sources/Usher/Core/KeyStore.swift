import Foundation
import Security

/// Resolves the TypeSafe API key. Never log the return value of `apiKey()`.
///
/// Lookup order — environment first, deliberately (see README): a keychain
/// grant is bound to the exact binary, so an unsigned rebuild asks again.
///   1. environment `JEV_API_KEY`
///   2. environment `TYPESAFE_API_KEY` (alias set via `launchctl setenv`)
///   3. login keychain, generic password with service `JEV_API_KEY`
///
/// An environment key set with `launchctl setenv` is visible to every GUI
/// process in the session, and "Remove" in Settings cannot clear it.
enum KeyStore {

    enum Source: String {
        case keychain = "Keychain (JEV_API_KEY)"
        case envJev = "Environment (JEV_API_KEY)"
        case envTypesafe = "Environment (TYPESAFE_API_KEY)"
        case missing = "Not found"

        /// What a person should see, as opposed to the developer string above.
        var displayName: String {
            switch self {
            case .keychain:    return "Stored in your keychain"
            case .envJev:      return "From the JEV_API_KEY environment variable"
            case .envTypesafe: return "From the TYPESAFE_API_KEY environment variable"
            case .missing:     return "No key found anywhere"
            }
        }
    }

    static let keychainService = "JEV_API_KEY"

    /// The keychain ACL is tied to the exact binary, so every rebuild makes macOS
    /// want to show an "allow access" dialog — which blocks a terminal process
    /// forever, since there is nobody to click it. The GUI app can prompt (once,
    /// then Always Allow); headless runs must never wait on one.
    nonisolated(unsafe) static var allowInteractiveKeychain = true

    static func apiKey() -> String? {
        resolved()?.0
    }

    /// Which source answered, for the settings window. Carries no secret material.
    static func source() -> Source {
        resolved()?.1 ?? .missing
    }

    /// Environment first, keychain second.
    ///
    /// A keychain ACL is bound to the exact binary. This app is ad-hoc signed, so
    /// every rebuild produces a new identity and macOS re-asks for permission —
    /// clicking "Always Allow" only holds until the next build. Reading the
    /// environment costs nothing and never prompts, so the keychain is only
    /// consulted when the environment has nothing, which is the case where the
    /// prompt is actually worth paying.
    ///
    /// A stable code-signing identity would make the keychain prompt once and stay
    /// quiet; until then this ordering is what keeps it usable.
    private static func resolved() -> (String, Source)? {
        let env = ProcessInfo.processInfo.environment
        if let k = env["JEV_API_KEY"], !k.isEmpty {
            return (k, .envJev)
        }
        if let k = env["TYPESAFE_API_KEY"], !k.isEmpty {
            return (k, .envTypesafe)
        }
        if let k = fromKeychain(service: keychainService), !k.isEmpty {
            return (k, .keychain)
        }
        return nil
    }

    // MARK: - Writing

    /// Stores the key, replacing any existing one. Writing never prompts: the app
    /// doing the write is added to the item's ACL as its creator.
    @discardableResult
    static func saveToKeychain(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: NSUserName()
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func removeFromKeychain() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// What the keychain holds, without ever reading the value or prompting.
    /// Distinguishes "nothing stored" from "stored but this build cannot read it",
    /// which is the difference between a setup problem and a signing problem.
    enum KeychainState {
        case absent
        case readable
        case presentButUnreadable
    }

    static func keychainState() -> KeychainState {
        let attributesOnly: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(attributesOnly as CFDictionary, &item) == errSecSuccess else {
            return .absent
        }
        // Reading attributes never prompts; reading the value might. Probe it
        // with interaction disabled so a locked ACL reports rather than blocks.
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(true) }
        return fromKeychain(service: keychainService) != nil ? .readable : .presentButUnreadable
    }

    private static func fromKeychain(service: String) -> String? {
        if !allowInteractiveKeychain {
            // Turns a blocking dialog into an immediate errSecInteractionNotAllowed,
            // so the environment fallback gets a chance.
            SecKeychainSetUserInteractionAllowed(false)
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
